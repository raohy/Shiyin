import Foundation
import Observation

/// 录一段自己的声音（design §56.2、R80）：用录音同一支麦克风收 16 kHz 单声道，最多 40 秒；
/// 有声音的部分到 10 秒才能存。录音只在内存里，算完声纹就丢（R80.5）
@MainActor
@Observable
final class VoiceEnrollment {
    enum Phase: Equatable {
        case idle, recording, computing
        case failed(String)
    }

    static let maxSeconds = 40.0
    static let minVoicedSeconds = 10.0
    /// 高于这个音量（dBFS）的 100 毫秒算有声音
    static let voicedLevel: Float = -50

    private(set) var phase: Phase = .idle
    private(set) var seconds = 0.0
    private(set) var voicedSeconds = 0.0
    /// 麦克风完全没有声音超过 3 秒（同收音提醒 R24.3）
    private(set) var micSilent = false
    /// 音量（0～1）：音量条自己定时读，不让 SwiftUI 观察（design §25）
    @ObservationIgnored private(set) var level: Float = 0

    @ObservationIgnored private var source: MicrophoneSource?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let buffer = SampleBuffer()
    @ObservationIgnored private var processed = 0
    @ObservationIgnored private var zeroSeconds = 0.0

    var canFinish: Bool { phase == .recording && voicedSeconds >= Self.minVoicedSeconds }

    func start() {
        stopCapture()
        buffer.reset()
        (processed, seconds, voicedSeconds, zeroSeconds, level, micSilent) = (0, 0, 0, 0, 0, false)
        let source = MicrophoneSource(deviceUID: AppSettings.inputDeviceUID)
        let buffer = buffer
        source.onSamples = { buffer.append($0) }
        do {
            try source.start()
        } catch {
            phase = .failed(String(localized: "没办法开始录音：\(error.localizedDescription)"))
            return
        }
        self.source = source
        phase = .recording
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// 每 100 毫秒处理新进来的音频：算音量、有声音的秒数；到 40 秒自动停（R80.3）
    private func tick() {
        let frame = Int(CaptureFormat.sampleRate / 10)
        let samples = buffer.snapshot()
        while processed + frame <= samples.count {
            let slice = samples[processed..<processed + frame]
            let rms = sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(frame))
            let db = rms > 0 ? 20 * log10(rms) : -120
            if db > Self.voicedLevel { voicedSeconds += 0.1 }
            zeroSeconds = rms == 0 ? zeroSeconds + 0.1 : 0
            level = max(0, min(1, (db + 60) / 60))
            processed += frame
        }
        seconds = Double(samples.count) / CaptureFormat.sampleRate
        let silent = zeroSeconds >= 3
        if silent != micSilent { micSilent = silent }
        if seconds >= Self.maxSeconds { stopCapture() }
    }

    func cancel() {
        stopCapture()
        buffer.reset()
        phase = .idle
    }

    /// 按「完成」：停止收音，算声纹、存成「我」。回传是否存好了
    func finish(name: String, model: AppModel) async -> Bool {
        stopCapture()
        guard voicedSeconds >= Self.minVoicedSeconds else {
            phase = .failed(String(localized: "再多念一点：有声音的部分要 10 秒以上。"))
            return false
        }
        phase = .computing
        let samples = buffer.snapshot()
        buffer.reset()
        do {
            try await model.enrollVoice(name: name, samples: samples)
            phase = .idle
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    private func stopCapture() {
        timer?.invalidate()
        timer = nil
        source?.stop()
        source = nil
        if phase == .recording { phase = .idle }
    }

    /// 从录好的音频算声纹（DEBUG 的 enrollvoice 也走这里）：说话秒数最多的那一位，要 ≥ 8 秒（同比对的下限）。
    /// 用另外一个识别器，不跟转录线共用（转录线可能正在识别说话者，design §56.2）
    nonisolated static func voiceprint(_ samples: [Float]) async throws -> [Float] {
        let output = try await Diarizer.diarize(samples: samples, config: Diarizer.config()) { _ in }
        guard let best = output.speechSeconds.max(by: { $0.value < $1.value }),
              best.value >= AppDatabase.voiceprintMinimumSeconds, let embedding = output.voiceprints[best.key] else {
            throw EnrollmentError.tooShort
        }
        return embedding
    }

    /// 要念的文字（R80.1）：跟着界面语言
    static var passage: String {
        String(localized: "拾音会在这台 Mac 上把会议录下来，转成逐字稿，再整理成会议记录。我现在念这一段，是要让拾音记住我的声音。之后开会的时候，拾音听到这个声音，就会在逐字稿上标出我的名字。声音特征只存在这台电脑里，不会上传。下午三点，我们要讨论下一季的计划，请大家先看一下上周的数字。")
    }
}

enum EnrollmentError: LocalizedError {
    case tooShort

    var errorDescription: String? {
        String(localized: "没听清楚你的声音：请在安静的地方再录一次，照着画面上的文字念完。")
    }
}

/// 音频线程送进来的样本（上锁）
final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ chunk: [Float]) { lock.withLock { samples += chunk } }
    func snapshot() -> [Float] { lock.withLock { samples } }
    func reset() { lock.withLock { samples = [] } }
}
