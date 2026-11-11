import Compression
import Foundation
import whisper

struct TranscribedSegment {
    var start: Double
    var end: Double
    var text: String
    var lowConfidence: Bool
}

enum WhisperError: LocalizedError {
    case modelMissing
    case loadFailed
    case failed(Int32)
    case cancelled
    case empty

    var errorDescription: String? {
        switch self {
        case .modelMissing: return String(localized: "还没有下载转录模型，请到设置 → 录音与转录下载")
        case .loadFailed: return String(localized: "转录模型加载失败，模型档可能已损坏，请到设置重新下载")
        case .failed(let code): return String(localized: "转录失败（whisper 错误代码 \(code)）")
        case .cancelled: return String(localized: "已取消")
        case .empty: return String(localized: "录音里没有识别到任何语音")
        }
    }
}

/// whisper.cpp 的包装（design §6.2）。在调用端的背景 Task 执行，blocking。
enum WhisperEngine {

    // Whisper 在静音段常见的幻觉字符串，出现在短句时直接丢掉（沿用第二版）
    static let hallucinationPhrases = [
        "字幕由Amara.org社区提供", "字幕由Amara.org社区提供", "字幕由Amara.org社区提供",  // l10n-skip
        "请不吝点赞", "请不吝点赞", "请不吝点赞", "订阅转发打赏", "订阅转发打赏",  // l10n-skip
        "明镜与点点栏目", "明镜与点点栏目", "优优独播剧场", "优优独播剧场",  // l10n-skip
        "Subtitles by the Amara.org community",
        "ご視聴ありがとうございました", "ご視聴いただきありがとうございました", "チャンネル登録",  // l10n-skip
    ]

    /// 基本提示词＋词汇表（R4.1）：依会议语言（design §16.4、§18.2、§41.3），写在语言档的 whisperPrompt（中文、日文 150 字、英文 400 个字符以内）
    static func prompt(glossary: [String], language: MeetingLanguage = .zh, style: String? = nil) -> String {
        let p = language.profile.whisperPrompt
        let limit = p.limit
        // 评估用的另一种写法（design §17.1）：Whisper 的提示词是「前面已经讲过的话」，写成像逐字稿的一句话，
        // 词汇放在句子里，顺便带出简体和标点的风格
        if style == "natural", let empty = p.natural, let list = p.naturalList {
            func natural(_ terms: [String]) -> String {
                terms.isEmpty ? empty : list.replacingOccurrences(of: "%@", with: terms.joined(separator: p.separator))
            }
            var picked: [String] = []
            for term in glossary {
                if natural(picked + [term]).count > limit { break }
                picked.append(term)
            }
            return natural(picked)
        }
        let base = p.base
        func build(_ terms: [String]) -> String {
            terms.isEmpty ? base : base + p.glossary.replacingOccurrences(of: "%@", with: terms.joined(separator: p.separator))
        }
        var picked: [String] = []
        for term in glossary {
            if build(picked + [term]).count > limit { break }
            picked.append(term)
        }
        return build(picked)
    }

    /// 传给 C callback 的状态：进度与取消
    final class Control: @unchecked Sendable {
        let onProgress: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var cancelled = false
        init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    private static let silenceLogs: Void = {
        whisper_log_set({ _, _, _ in }, nil)
    }()

    /// 长录音分段（design §21.16、D34）：每段约 chunkSeconds 秒，分段点击在预定位置前后 10 秒内最安静的 0.5 秒。
    /// 最后一段不会短于 2 分钟（剩下的并进前一段）；chunkSeconds ≤ 0 不分段
    static func chunks(_ samples: [Float], seconds chunkSeconds: Double) -> [Range<Int>] {
        let rate = Int(AudioDecoder.sampleRate)
        let chunk = Int(chunkSeconds * Double(rate))
        guard chunk > 0 else { return [0..<samples.count] }
        var result: [Range<Int>] = []
        var start = 0
        while samples.count - start > chunk + 120 * rate {
            let cut = samples.withUnsafeBufferPointer { quietestCut($0, start: start, target: start + chunk) }
            result.append(start..<cut)
            start = cut
        }
        result.append(start..<samples.count)
        return result
    }

    /// target 前后 10 秒内最安静的 0.5 秒的中间：每 0.05 秒一个窗，能量（平方和）最小的
    private static func quietestCut(_ samples: UnsafeBufferPointer<Float>, start: Int, target: Int) -> Int {
        let rate = Int(AudioDecoder.sampleRate)
        let search = 10 * rate, window = rate / 2, hop = rate / 20
        let from = max(start + window, target - search), to = min(samples.count - window, target + search)
        var squares = [Double](repeating: 0, count: to - from + 1)
        for i in from..<to { squares[i - from + 1] = squares[i - from] + Double(samples[i] * samples[i]) }
        var best = target, bestEnergy = Double.infinity
        var position = from
        while position + window <= to {
            let energy = squares[position + window - from] - squares[position - from]
            if energy < bestEnergy { bestEnergy = energy; best = position + window / 2 }
            position += hop
        }
        return best
    }

    /// 传给 progress callback 的状态：这一段在整体的哪个位置
    private final class ChunkProgress {
        let control: Control
        let base: Double, span: Double
        init(control: Control, base: Double, span: Double) { (self.control, self.base, self.span) = (control, base, span) }
    }

    /// 一次转录：模型只加载一次，一段一段送进去；每段用基本提示词加上前一段最后的文字
    final class Session {
        private let ctx: OpaquePointer
        private let prompt: String, language: String
        let control: Control
        private let tuning: TranscriptionOptions.DecoderTuning?
        private(set) var segments: [TranscribedSegment] = []

        init(modelPath: String, prompt: String, language: String, control: Control, tuning: TranscriptionOptions.DecoderTuning? = nil) throws {
            self.tuning = tuning
            _ = silenceLogs
            guard FileManager.default.fileExists(atPath: modelPath) else { throw WhisperError.modelMissing }
            var contextParams = whisper_context_default_params()
            contextParams.use_gpu = true
            contextParams.flash_attn = true
            guard let ctx = whisper_init_from_file_with_params(modelPath, contextParams) else { throw WhisperError.loadFailed }
            WhisperContexts.opened()
            (self.ctx, self.prompt, self.language, self.control) = (ctx, prompt, language, control)
        }

        deinit {
            whisper_free(ctx)
            WhisperContexts.closed()
        }

        /// 识别一段：offset 是这一段在整段录音的第几个采样；进度换算到 progressBase…progressBase+progressSpan
        func feed(_ samples: UnsafeBufferPointer<Float>, offset: Int, progressBase: Double, progressSpan: Double) throws {
            guard !samples.isEmpty else { return }
            // 前一段最后的文字接在提示词后面，跟 whisper 自己连续转录时一样（whisper 只取最后 224 个 token）
            let chunkPrompt = segments.isEmpty ? prompt : prompt + (language == "en" ? " " : "") + WhisperEngine.tail(of: segments, language: language)
            let progress = ChunkProgress(control: control, base: progressBase, span: progressSpan)
            var part = try WhisperEngine.run(ctx, samples: samples, offset: offset, prompt: chunkPrompt, language: language, progress: progress, tuning: tuning)
            if offset > 0, let last = segments.last {
                // 接缝：开头几秒跟前一段最后一句重复的（提示词被念出来）去掉
                let seam = Double(offset) / AudioDecoder.sampleRate
                while let first = part.first, first.start < seam + 3, TranscriptionPipeline.similar(first.text, last.text) { part.removeFirst() }
            }
            segments += part
        }
    }

    /// 识别已经解码的整段录音（分声道时用）。chunks 是分段的范围（`chunks(_:seconds:)`）
    static func transcribe(samples: [Float], chunks: [Range<Int>]? = nil, modelPath: String, prompt: String, language: String = "zh",
                           control: Control, tuning: TranscriptionOptions.DecoderTuning? = nil) throws -> [TranscribedSegment] {
        let session = try Session(modelPath: modelPath, prompt: prompt, language: language, control: control, tuning: tuning)
        let total = Double(max(samples.count, 1))
        try samples.withUnsafeBufferPointer { buffer in
            for range in chunks ?? [0..<samples.count] {
                try session.feed(UnsafeBufferPointer(rebasing: buffer[range]), offset: range.lowerBound,
                                 progressBase: Double(range.lowerBound) / total, progressSpan: Double(range.count) / total)
            }
        }
        if session.segments.isEmpty { throw WhisperError.empty }
        return session.segments
    }

    /// 从文件依序读、一段一段转录，不先解码整段（design §21.16）。切的位置跟 `chunks(_:seconds:)` 相同。
    /// 回传逐字稿、分段的位置（第几个采样）、总采样数
    static func transcribe(file url: URL, chunkSeconds: Double, modelPath: String, prompt: String, language: String,
                           control: Control, tuning: TranscriptionOptions.DecoderTuning? = nil) async throws -> (segments: [TranscribedSegment], seams: [Int], sampleCount: Int) {
        let stream = try await AudioDecoder.Stream(url)
        let session = try Session(modelPath: modelPath, prompt: prompt, language: language, control: control, tuning: tuning)
        let rate = Int(AudioDecoder.sampleRate)
        let chunk = Int(chunkSeconds * Double(rate))
        // 剩下超过「一段＋2 分钟」才切，所以要读到这么多才能决定；不分段时读完整段
        let need = chunk > 0 ? chunk + 120 * rate + 1 : Int.max
        let total = Double(max(stream.estimatedCount, 1))
        var buffer: [Float] = []
        var offset = 0
        var seams: [Int] = []
        while true {
            if control.isCancelled { throw WhisperError.cancelled }
            try stream.fill(&buffer, upTo: need)
            let cut = chunk > 0 && buffer.count >= need
                ? buffer.withUnsafeBufferPointer { quietestCut($0, start: 0, target: chunk) } : buffer.count
            try buffer.withUnsafeBufferPointer { buffer in
                try session.feed(UnsafeBufferPointer(rebasing: buffer[0..<cut]), offset: offset,
                                 progressBase: min(Double(offset) / total, 1), progressSpan: Double(cut) / total)
            }
            buffer.removeFirst(cut)
            offset += cut
            // 没切（cut 是整个 buffer）时一定已经读完
            if buffer.isEmpty && stream.finished { break }
            seams.append(offset)
        }
        if session.segments.isEmpty { throw WhisperError.empty }
        return (session.segments, seams, offset)
    }

    /// 前一段最后的文字：中文、日文 120 字、英文 400 个字符以内
    private static func tail(of segments: [TranscribedSegment], language: String) -> String {
        let limit = language == "en" ? 400 : 120
        var text = ""
        for segment in segments.reversed() {
            text = segment.text + (text.isEmpty ? "" : (language == "en" ? " " : "")) + text
            if text.count >= limit { break }
        }
        return String(text.suffix(limit))
    }

    /// 识别一段；时间点换成整段录音的时间
    private static func run(_ ctx: OpaquePointer, samples: UnsafeBufferPointer<Float>, offset start: Int, prompt: String, language: String,
                            progress: ChunkProgress, tuning: TranscriptionOptions.DecoderTuning? = nil) throws -> [TranscribedSegment] {
        let control = progress.control
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.beam_search.beam_size = 5
        params.greedy.best_of = 5
        params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.suppress_blank = true
        // 评估用的实验开关（design §17.1）：正式转录都是 nil
        if let tuning {
            if let v = tuning.noContext { params.no_context = v }
            if let v = tuning.beamSize { params.beam_search.beam_size = Int32(v); params.greedy.best_of = Int32(v) }
            if let v = tuning.temperatureInc { params.temperature_inc = v }
            if let v = tuning.entropyThold { params.entropy_thold = v }
            if let v = tuning.logprobThold { params.logprob_thold = v }
            if let v = tuning.noSpeechThold { params.no_speech_thold = v }
            if let v = tuning.suppressNst { params.suppress_nst = v }
            if let v = tuning.maxLen, v > 0 { params.max_len = Int32(v); params.split_on_word = true; params.token_timestamps = true }
        }

        let progressPointer = Unmanaged.passUnretained(progress).toOpaque()
        params.progress_callback = { _, _, value, userData in
            guard let userData else { return }
            let progress = Unmanaged<ChunkProgress>.fromOpaque(userData).takeUnretainedValue()
            progress.control.onProgress(min(1, progress.base + Double(value) / 100 * progress.span))
        }
        params.progress_callback_user_data = progressPointer
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<Control>.fromOpaque(userData).takeUnretainedValue().isCancelled
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(control).toOpaque()

        let result: Int32 = withExtendedLifetime(progress) {
            language.withCString { lang in
                prompt.withCString { promptPointer in
                    params.language = lang
                    params.initial_prompt = promptPointer
                    return whisper_full(ctx, params, samples.baseAddress, Int32(samples.count))
                }
            }
        }
        if control.isCancelled { throw WhisperError.cancelled }
        guard result == 0 else { throw WhisperError.failed(result) }

        let offset = Double(start) / AudioDecoder.sampleRate
        let limit = Double(start + samples.count) / AudioDecoder.sampleRate
        let eot = whisper_token_eot(ctx)
        var segments: [TranscribedSegment] = []
        for i in 0..<whisper_full_n_segments(ctx) {
            let text = String(cString: whisper_full_get_segment_text(ctx, i)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            var logSum = 0.0, count = 0
            for j in 0..<whisper_full_n_tokens(ctx, i) where whisper_full_get_token_id(ctx, i, j) < eot {
                logSum += Foundation.log(max(Double(whisper_full_get_token_p(ctx, i, j)), 1e-6))
                count += 1
            }
            let avgLogProb = count > 0 ? logSum / Double(count) : -10
            let noSpeech = Double(whisper_full_get_segment_no_speech_prob(ctx, i))
            // 几乎确定没人讲话、信心又低：Whisper 对静音的幻觉
            let keepAll = tuning?.keepAll == true
            if !keepAll && noSpeech > 0.6 && avgLogProb < -1.0 { continue }
            if !keepAll && text.count < 40 && hallucinationPhrases.contains(where: { text.contains($0) }) { continue }
            // 最后一个 30 秒的窗会补零，时间点可能超过这一段的结尾
            segments.append(TranscribedSegment(
                start: min(offset + Double(whisper_full_get_segment_t0(ctx, i)) / 100, limit),
                end: min(offset + Double(whisper_full_get_segment_t1(ctx, i)) / 100, limit),
                text: text,
                lowConfidence: avgLogProb < -1.0 || compressionRatio(text) > 2.4))
        }
        return segments
    }

    /// Whisper 用来判断重复幻觉的压缩比：原始字节数 ÷ zlib 压缩后的字节数
    static func compressionRatio(_ text: String) -> Double {
        let input = Array(text.utf8)
        guard input.count > 16 else { return 1 }
        var output = [UInt8](repeating: 0, count: input.count + 64)
        let size = compression_encode_buffer(&output, output.count, input, input.count, nil, COMPRESSION_ZLIB)
        return size > 0 ? Double(input.count) / Double(size) : 1
    }
}

#if DEBUG
extension WhisperEngine {
    /// whisper.cpp 的默认解码参数（transcribe-eval 的输出附上，实验时对照用）
    static func defaultParameters() -> [String: Any] {
        let d = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        return ["noContext": d.no_context, "temperatureInc": d.temperature_inc, "entropyThold": d.entropy_thold, "logprobThold": d.logprob_thold,
                "noSpeechThold": d.no_speech_thold, "suppressNst": d.suppress_nst, "maxInitialTs": d.max_initial_ts,
                "lengthPenalty": d.length_penalty, "nMaxTextCtx": d.n_max_text_ctx]
    }

    /// dump-golden 用（design-windows §4.1）：前一段最后的文字、下一段的提示词
    static func debugChunkPrompt(base: String, previous: [TranscribedSegment], language: String) -> String {
        previous.isEmpty ? base : base + (language == "en" ? " " : "") + tail(of: previous, language: language)
    }
}
#endif
