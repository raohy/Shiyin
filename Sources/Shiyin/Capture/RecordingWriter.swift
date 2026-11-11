import AVFoundation
import Foundation

/// 把各音源的 16 kHz 音频对齐后写成 WAV（design §5.2），同时把混音后的单声道交给实时转录。
/// 两个音源时：左声道麦克风、右声道系统声音。暂停时丢掉收到的音频，所以文件里没有暂停的那一段。
final class RecordingWriter: @unchecked Sendable {
    let channels: Int
    let url: URL
    var onMix: (([Float]) -> Void)?

    private let file: AVAudioFile
    private let lock = NSLock()
    private var pending: [[Float]]
    private var levels: [Float]
    private var silentSeconds: [Double]
    private var paused = false
    private var acceptedFrames: [Int] // 各声道累计收到的音框（不含暂停）
    private var lastReceived: [Double]  // 各声道最后一次收到音频的时间（systemUptime），看门狗用（design §20.2）
    private var timer: DispatchSourceTimer?
    private var writtenFrames = 0          // 只在 queue 上读写
    private let queue = DispatchQueue(label: "com.weiwei.shiyin.writer", qos: .userInitiated)
    private var failed = false            // 写档失败过，用 lock 保护
    /// 收音提醒（design §26.1）：各声道每 100 毫秒以上一格的音量（dBFS），留最近 300 格（30 秒）
    private var frameEnergy: [Float]
    private var frameSamples: [Int]
    private var recent: [[Float]]

    init(url: URL, channels: Int) throws {
        self.url = url
        self.channels = channels
        pending = Array(repeating: [], count: channels)
        levels = Array(repeating: 0, count: channels)
        silentSeconds = Array(repeating: 0, count: channels)
        acceptedFrames = Array(repeating: 0, count: channels)
        frameEnergy = Array(repeating: 0, count: channels)
        frameSamples = Array(repeating: 0, count: channels)
        recent = Array(repeating: [], count: channels)
        lastReceived = Array(repeating: ProcessInfo.processInfo.systemUptime, count: channels)
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: CaptureFormat.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func start() {
        lock.withLock { lastReceived = Array(repeating: ProcessInfo.processInfo.systemUptime, count: channels) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.drain(final: false) }
        timer.resume()
        self.timer = timer
    }

    /// 音频线程调用
    func append(channel: Int, _ samples: [Float]) {
        guard channel < channels, !samples.isEmpty else { return }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            lastReceived[channel] = now
            levels[channel] = rms
            silentSeconds[channel] = rms == 0 ? silentSeconds[channel] + Double(samples.count) / CaptureFormat.sampleRate : 0
            guard !paused else { return }
            pending[channel].append(contentsOf: samples)
            acceptedFrames[channel] += samples.count
            frameEnergy[channel] += sum
            frameSamples[channel] += samples.count
            if frameSamples[channel] >= Int(CaptureFormat.sampleRate / 10) {
                let rms = (frameEnergy[channel] / Float(frameSamples[channel])).squareRoot()
                recent[channel].append(20 * log10(max(rms, 1e-6)))
                if recent[channel].count > 300 { recent[channel].removeFirst(recent[channel].count - 300) }
                frameEnergy[channel] = 0
                frameSamples[channel] = 0
            }
        }
    }

    func setPaused(_ value: Bool) {
        lock.withLock {
            paused = value
            if value { for i in 0..<channels { pending[i].removeAll() } }
        }
    }

    /// 目前录到的秒数（不含暂停），给计时、笔记和重点标记的时间点用
    var recordedSeconds: Double {
        lock.withLock { Double(acceptedFrames.max() ?? 0) / CaptureFormat.sampleRate }
    }

    /// 0～1 的音量（RMS 换成 dB 再规范化）
    func level(_ channel: Int) -> Float {
        let rms = lock.withLock { channel < channels ? levels[channel] : 0 }
        guard rms > 0 else { return 0 }
        return max(0, min(1, (20 * log10(rms) + 60) / 60))
    }

    /// 写档失败了（例如磁盘满了）：Recorder 看到就停止录音（design §20.3）
    var writeFailed: Bool { lock.withLock { failed } }

    func silence(_ channel: Int) -> Double { lock.withLock { channel < channels ? silentSeconds[channel] : 0 } }

    /// 最近 30 秒（不含暂停）每 100 毫秒的音量，dBFS（design §26.1）
    func recentLevels(_ channel: Int) -> [Float] { lock.withLock { channel < channels ? recent[channel] : [] } }

    /// 暂停后重新开始：之前的音量不算（暂停前后可能换了地方）
    func resetRecentLevels() { lock.withLock { for i in 0..<channels { recent[i].removeAll(); frameEnergy[i] = 0; frameSamples[i] = 0 } } }

    /// 这个声道多久没有送音频来（秒）。暂停时音源照样送资料，所以暂停不影响
    func secondsSinceSamples(_ channel: Int) -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock { channel < channels ? now - lastReceived[channel] : 0 }
    }

    /// 停止并关档，回传写进文件的秒数（写档失败时是失败前写进去的部分，看 `writeFailed`）。
    /// 注意：AVAudioFile 关档后 length 会变成 0，所以秒数要用自己累计的音框数算
    func finish() -> Double {
        timer?.cancel()
        timer = nil
        let frames = queue.sync { () -> Int in
            drain(final: true)
            return writtenFrames
        }
        file.close()
        return Double(frames) / CaptureFormat.sampleRate
    }

    private func drain(final: Bool) {
        let frames: [[Float]] = lock.withLock {
            if channels == 1 {
                defer { pending[0].removeAll(keepingCapacity: true) }
                return [pending[0]]
            }
            // 两个音源：取两边都有的长度；一边落后超过 0.5 秒（或收尾时），补静音让时间对齐
            var count = pending.map(\.count).min() ?? 0
            let longest = pending.map(\.count).max() ?? 0
            if final || longest - count > Int(CaptureFormat.sampleRate / 2) {
                for i in 0..<channels where pending[i].count < longest {
                    pending[i].append(contentsOf: [Float](repeating: 0, count: longest - pending[i].count))
                }
                count = longest
            }
            let taken = pending.map { Array($0.prefix(count)) }
            for i in 0..<channels { pending[i].removeFirst(count) }
            return taken
        }
        let count = frames[0].count
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        for (channel, samples) in frames.enumerated() {
            samples.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: count) }
        }
        do {
            try file.write(from: buffer)
            writtenFrames += count
        } catch {
            if !writeFailed { log.error("recording write failed: \(error.localizedDescription, privacy: .public)") }
            lock.withLock { failed = true }
        }
        // 实时转录用的单声道混音
        if channels == 1 {
            onMix?(frames[0])
        } else {
            var mix = [Float](repeating: 0, count: count)
            for i in 0..<count { mix[i] = (frames[0][i] + frames[1][i]) * 0.5 }
            onMix?(mix)
        }
    }
}
