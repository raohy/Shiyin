import Foundation

/// 实时 Qwen 的分段策略。暂定结果始终重听当前整句；停顿后才定稿，连续发言
/// 最多 24 秒一段。上一段完整音频和原始文字另由识别任务保留作左侧上下文。
struct QwenLiveBuffer {
    static let sampleRate = 16_000
    static let frameSize = 1_600
    static let maxSamples = 24 * sampleRate
    static let updateSamples = 4 * sampleRate
    private(set) var samples: [Float] = []
    private(set) var startSample = 0
    private var previewedSamples = 0
    private let reviewing: Bool

    /// 复核重听更长的完整音频，不产生暂定文字；停止时仍冲刷短尾句。
    init(reviewing: Bool = false) { self.reviewing = reviewing }

    struct Request {
        var samples: [Float]
        var startSample: Int
        var isFinal: Bool
        var start: Double { Double(startSample) / Double(QwenLiveBuffer.sampleRate) }
        var end: Double { Double(startSample + samples.count) / Double(QwenLiveBuffer.sampleRate) }
    }

    mutating func append(_ newSamples: [Float]) { samples.append(contentsOf: newSamples) }

    mutating func next(finishing: Bool) -> Request? {
        guard !samples.isEmpty else { return nil }
        let maximum = reviewing ? 30 * Self.sampleRate : Self.maxSamples
        let count = min(samples.count, maximum)
        // −60 dBFS 的保守静音门槛，只剔除近乎无声的输入；不是人声分类器。
        var energies: [Float] = []
        for start in stride(from: 0, to: count, by: Self.frameSize) {
            let end = min(start + Self.frameSize, count)
            var energy: Float = 0
            for i in start..<end { energy += samples[i] * samples[i] }
            energies.append(energy / Float(end - start))
        }
        guard let firstVoice = energies.firstIndex(where: { $0 > 0.000001 }) else {
            // 保留 300 ms 前滚，下一句的开头不会紧贴噪声门槛切掉。
            let removed = finishing ? count : max(0, count - Self.sampleRate * 3 / 10)
            discard(removed)
            return removed > 0 ? next(finishing: finishing) : nil
        }
        var lastVoice = firstVoice
        var boundary: Int?
        for i in firstVoice..<energies.count {
            if energies[i] > 0.000001 { lastVoice = i }
            // 一般等至少 6 秒上下文和 1.2 秒停顿；短句等 3 秒停顿，避免迟迟不定稿。
            if i - lastVoice >= 12 && (reviewing ? i >= 179 : (i >= 59 || i - lastVoice >= 30)) {
                boundary = min((i + 1) * Self.frameSize, count)
                break
            }
        }
        if boundary == nil, count == maximum {
            // 连续发言在末尾 4 秒最安静的 100 ms 处换窗，下一窗仍带整段左侧上下文。
            let cut = ((energies.count - 40)..<energies.count).min { energies[$0] < energies[$1] } ?? energies.count - 1
            boundary = (cut + 1) * Self.frameSize
        }
        if let boundary { return Request(samples: Array(samples.prefix(boundary)), startSample: startSample, isFinal: true) }
        if finishing { return Request(samples: Array(samples.prefix(count)), startSample: startSample, isFinal: true) }
        guard !reviewing else { return nil }
        guard count >= 6 * Self.sampleRate, count - previewedSamples >= Self.updateSamples else { return nil }
        previewedSamples = count
        return Request(samples: Array(samples.prefix(count)), startSample: startSample, isFinal: false)
    }

    mutating func commit(_ request: Request) {
        precondition(request.isFinal && request.startSample == startSample)
        discard(request.samples.count)
    }

    private mutating func discard(_ count: Int) {
        samples.removeFirst(count)
        startSample += count
        previewedSamples = 0
    }
}

/// 音频线程只入队、唤醒。推理落后时合并暂定更新，不丢音频；超过两分钟积压明确报错。
final class QwenLiveFeed: @unchecked Sendable {
    let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var pending: [Float] = []
    private var closed = false
    private var overflow = false

    init() {
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.events = events
        self.continuation = continuation
    }

    func feed(_ samples: [Float]) {
        lock.withLock {
            guard !closed else { return }
            if pending.count + samples.count > 120 * QwenLiveBuffer.sampleRate {
                overflow = true
                closed = true
                continuation.finish()
            } else {
                pending.append(contentsOf: samples)
                continuation.yield(())
            }
        }
    }

    func take() throws -> [Float] {
        try lock.withLock {
            if overflow { throw QwenLiveError.backlog }
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
    }

    func finish() {
        lock.withLock {
            closed = true
            continuation.finish()
        }
    }
}

enum QwenLiveError: LocalizedError {
    case missingModel, unsupportedLanguage, backlog, unstable

    var errorDescription: String? {
        switch self {
        case .missingModel: return String(localized: "请先在「录音与转录」下载 Qwen3-ASR 模型和音频编码器")
        case .unsupportedLanguage: return String(localized: "Qwen3-ASR 实时模式暂不支持这个会议语言，请改用 macOS 系统识别")
        case .backlog: return String(localized: "Qwen3-ASR 识别速度跟不上录音，积压已超过两分钟；请改用 macOS 系统识别")
        case .unstable: return String(localized: "Qwen3-ASR 连续两次识别结果异常，请使用会后正式转录复核")
        }
    }
}
