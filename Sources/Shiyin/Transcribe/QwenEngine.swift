import Foundation
import QwenShim

/// Qwen3-ASR（llama.cpp，design §32.4、D107）：先依说话者片段和安静处分段，每段各自转录，段落的时间就是分段的时间。
/// 跳针（同一个字重复到截断）时先加重复惩罚重试，再切半，最后修剪并标成低信心（R43.5）。
enum QwenEngine {
    /// 一段要转录的音频（采样的范围）
    struct Chunk: Equatable {
        var range: Range<Int>
    }

    /// 每段最长几秒（评估：15 秒跟 30 秒的错误率一样，短一点说话者标得细）
    static let maxChunkSeconds = 15.0
    /// 文字＋音频 token 的上限：15 秒音频约 190 个 token，加提示词和输出绰绰有余；分段最长 120 秒时也够
    static let contextTokens: Int32 = 4096

    // MARK: 分段

    /// 在安静处切、优先切在换人说话的地方（design §32.4）：
    /// - 每个换人的时间点前后 1 秒内最安静的 0.3 秒，能量低于整段中位数的 15% 才切（真的有停顿才切，不切在字中间）
    /// - 超过 maxSeconds 的段在预定位置前后 5 秒内最安静的 0.5 秒切开（同 §21.16 的规则）
    /// - 短于 0.5 秒的并进前一段（模型的最短输入）
    /// 没有说话者片段时只做后两步
    /// splitMixed（默认开）：混到第二个人 ≥ 1.5 秒且 ≥ 25% 的段，照片段边界再切，说话者才标得准（§32.4 第三步）；
    /// anyChange（评估用）：换人处不看能量门槛，一律在最安静点切
    static func chunks(_ samples: [Float], turns: [Diarizer.Turn], maxSeconds: Double = maxChunkSeconds,
                       anyChange: Bool = false, splitMixed: Bool = true) -> [Chunk] {
        let rate = Int(AudioDecoder.sampleRate)
        let n = samples.count
        guard n > 0 else { return [] }
        // 能量的前缀和，任何一段的能量都能 O(1) 算出来
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(samples[i] * samples[i]) }
        func energy(_ a: Int, _ b: Int) -> Double { prefix[min(b, n)] - prefix[max(a, 0)] }
        /// [lo, hi) 里最安静的 window 个采样的中点和能量
        func quietest(lo: Int, hi: Int, window: Int) -> (center: Int, energy: Double)? {
            guard hi - window > lo else { return nil }
            var best = lo, bestEnergy = Double.greatestFiniteMagnitude
            var p = lo
            while p + window <= hi {
                let e = energy(p, p + window)
                if e < bestEnergy { bestEnergy = e; best = p }
                p += rate / 100
            }
            return (best + window / 2, bestEnergy)
        }

        var cuts = Set<Int>()
        if turns.count > 1 {
            // 整段的能量中位数（每 0.1 秒一格）
            let frame = rate / 10
            var frames: [Double] = []
            var p = 0
            while p < n { frames.append(energy(p, p + frame)); p += frame }
            let nonzero = frames.filter { $0 > 0 }.sorted()
            let median = nonzero.isEmpty ? 0 : nonzero[nonzero.count / 2]
            let window = rate * 3 / 10
            let threshold = median * 0.15 * Double(window) / Double(frame)
            let sorted = turns.sorted { $0.start < $1.start }
            for (previous, turn) in zip(sorted, sorted.dropFirst()) where previous.speaker != turn.speaker {
                let c = Int(turn.start * Double(rate))
                if let q = quietest(lo: max(window, c - rate), hi: min(n - window, c + rate), window: window), anyChange || q.energy <= threshold {
                    cuts.insert(q.center)
                }
            }
        }
        let bounds = [0] + cuts.filter { $0 > 0 && $0 < n }.sorted() + [n]
        let maxLength = Int(maxSeconds * Double(rate))
        var pieces: [Range<Int>] = []
        for (a, b) in zip(bounds, bounds.dropFirst()) where b > a {
            var start = a
            // 剩下超过一段半才切（最后一段不短于半段）
            while b - start > maxLength + maxLength / 2 {
                let target = start + maxLength
                let cut = quietest(lo: max(start + rate / 2, target - 5 * rate), hi: min(b - rate / 2, target + 5 * rate), window: rate / 2)?.center ?? target
                pieces.append(start..<cut)
                start = cut
            }
            pieces.append(start..<b)
        }
        var merged: [Range<Int>] = []
        for piece in pieces {
            if let last = merged.last, piece.count < rate / 2 {
                merged[merged.count - 1] = last.lowerBound..<piece.upperBound
            } else {
                merged.append(piece)
            }
        }
        guard splitMixed, !turns.isEmpty else { return merged.map { Chunk(range: $0) } }
        /// 每位说话者在 [a, b) 里讲了几秒
        func overlap(_ a: Int, _ b: Int) -> [Int: Double] {
            var out: [Int: Double] = [:]
            let (lo, hi) = (Double(a) / Double(rate), Double(b) / Double(rate))
            for t in turns where t.end > lo && t.start < hi { out[t.speaker, default: 0] += min(t.end, hi) - max(t.start, lo) }
            return out
        }
        var result: [Chunk] = []
        for piece in merged {
            let ranked = overlap(piece.lowerBound, piece.upperBound).values.sorted(by: >)
            guard ranked.count >= 2, ranked[1] >= 1.5, ranked[1] >= 0.25 * Double(piece.count) / Double(rate) else {
                result.append(Chunk(range: piece)); continue
            }
            // 照片段的起点切，太短的并进前一段
            let points = Set(turns.map { Int($0.start * Double(rate)) }.filter { $0 > piece.lowerBound && $0 < piece.upperBound }).sorted()
            var parts: [Range<Int>] = []
            for (a, b) in zip([piece.lowerBound] + points, points + [piece.upperBound]) where b > a {
                if let last = parts.last, b - a < rate / 2 { parts[parts.count - 1] = last.lowerBound..<b } else { parts.append(a..<b) }
            }
            result += parts.map { Chunk(range: $0) }
        }
        return result
    }

    // MARK: 转录

    /// 每段的结果：文字和是不是经过修剪（低信心）
    struct Piece {
        var range: Range<Int>
        var text: String
        var trimmed: Bool
    }

    /// 词汇表当作提示（Qwen3-ASR 的 contextual biasing）：跟 whisper 的提示词同样的上限（中文 150 字、英文 400 个字符）
    static func context(glossary: [String], language: MeetingLanguage) -> String {
        let limit = language.profile.whisperPrompt.limit, separator = language.profile.whisperPrompt.separator
        var picked: [String] = []
        for term in glossary {
            let candidate = (picked + [term]).joined(separator: separator)
            if candidate.count > limit { break }
            picked.append(term)
        }
        return picked.joined(separator: separator)
    }

    /// 语言档的 transcription.qwen；Qwen3-ASR 不能用的语言不会走到这里（ModelStore.transcription(for:)）
    static func languageName(_ language: MeetingLanguage) -> String { language.profile.transcription.qwen ?? "Chinese" }

    /// 每 0.1 秒一格的能量中位数（只算有声音的格）：分段和幻觉防线都用它当「有声音」的基准
    static func medianFrameEnergy(_ samples: UnsafeBufferPointer<Float>) -> Double {
        let frame = Int(AudioDecoder.sampleRate) / 10
        var frames: [Double] = []
        var p = 0
        while p + frame <= samples.count {
            var e = 0.0
            for i in p..<(p + frame) { e += Double(samples[i] * samples[i]) }
            if e > 0 { frames.append(e) }
            p += frame
        }
        guard !frames.isEmpty else { return 0 }
        frames.sort()
        return frames[frames.count / 2]
    }

    /// 这一段里有声音的秒数：能量超过整段中位数一半的 0.1 秒格数
    static func speechSeconds(_ samples: UnsafeBufferPointer<Float>, range: Range<Int>, median: Double) -> Double {
        let frame = Int(AudioDecoder.sampleRate) / 10
        let threshold = median * 0.5
        var count = 0
        var p = range.lowerBound
        while p + frame <= range.upperBound {
            var e = 0.0
            for i in p..<(p + frame) { e += Double(samples[i] * samples[i]) }
            if e > threshold { count += 1 }
            p += frame
        }
        return Double(count) * 0.1
    }

    /// 文字的长度单位：英文算字数，其他算字母和数字的个数
    static func units(_ text: String, language: String) -> Int {
        language == "English" ? text.split(whereSeparator: { $0.isWhitespace }).count : text.filter { $0.isLetter || $0.isNumber }.count
    }

    /// 输出比有声音的秒数能讲的还多（英文 5 字／秒、中日文 8 字／秒，加一点余裕）：短而吵的段落常会编出整段没说过的话
    static func tooLong(_ text: String, language: String, speechSeconds: Double) -> Bool {
        let cap = language == "English" ? speechSeconds * 5 + 3 : speechSeconds * 8 + 4
        return Double(units(text, language: language)) > cap
    }

    /// 两段文字的相似度（difflib 的 ratio：2 × 最长共同子序列 ÷ 两段长度和）
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var prev = [Int](repeating: 0, count: y.count + 1), cur = prev
        for i in 1...max(x.count, 1) where i <= x.count {
            for j in 1...max(y.count, 1) where j <= y.count {
                cur[j] = x[i - 1] == y[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
            }
            swap(&prev, &cur)
        }
        return 2 * Double(prev[y.count]) / Double(x.count + y.count)
    }

    /// 加载模型、逐段转录、释放模型。回传的段落时间是分段的时间（秒）。粤语的文字已经转成繁体并套用 scriptFixes，最后由 TranscriptionPipeline 统一转简体（design §45）
    static func transcribe(samples: [Float], chunks: [Chunk], modelPath: String, encoderPath: String, language: MeetingLanguage,
                           glossary: [String], control: WhisperEngine.Control, retry: Bool = true, guard useGuard: Bool = true) throws -> [TranscribedSegment] {
        let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        guard let engine = qwen_load(modelPath, encoderPath, contextTokens, threads, true) else { throw WhisperError.loadFailed }
        defer { qwen_free(engine) }
        let context = self.context(glossary: glossary, language: language)
        let languageName = languageName(language)
        let total = Double(max(samples.count, 1))
        var segments: [TranscribedSegment] = []
        try samples.withUnsafeBufferPointer { buffer in
            let median = useGuard ? medianFrameEnergy(buffer) : 0
            for chunk in chunks {
                if control.isCancelled { throw WhisperError.cancelled }
                for piece in try run(engine, buffer: buffer, range: chunk.range, context: context, language: languageName, control: control,
                                     retry: retry, guardMedian: useGuard ? median : nil, depth: 0) {
                    var text = piece.text
                    if language.profile.transcription.traditional { text = language.profile.fixScript(ChineseScript.toTaiwan(text)) }
                    guard !text.isEmpty else { continue }
                    segments.append(TranscribedSegment(start: Double(piece.range.lowerBound) / AudioDecoder.sampleRate,
                                                       end: Double(piece.range.upperBound) / AudioDecoder.sampleRate,
                                                       text: text, lowConfidence: piece.trimmed))
                }
                control.onProgress(min(1, Double(chunk.range.upperBound) / total))
            }
        }
        if segments.isEmpty { throw WhisperError.empty }
        return segments
    }

    /// 一段：坏掉（到达 max_tokens、压缩比 > 2.4、同一片段连续重复 5 次以上）就重试、切半、修剪（§32.4）
    private static func run(_ engine: OpaquePointer, buffer: UnsafeBufferPointer<Float>, range: Range<Int>, context: String, language: String,
                            control: WhisperEngine.Control, retry: Bool, guardMedian: Double?, depth: Int) throws -> [Piece] {
        let rate = Int(AudioDecoder.sampleRate)
        let seconds = Double(range.count) / Double(rate)
        var params = qwen_params_default()
        params.max_tokens = Int32(seconds * 12) + 64
        /// 幻觉防线（§32.4 第 4 步）：输出比有声音的秒数能讲的还多，就加温度重解一次；两次差很多就是编的，丢掉；差不多就留短的
        func guarded(_ text: String) throws -> Piece {
            guard let median = guardMedian, tooLong(text, language: language, speechSeconds: speechSeconds(buffer, range: range, median: median)) else {
                return Piece(range: range, text: text, trimmed: false)
            }
            var again = params
            again.temperature = 0.3
            again.seed = 7
            let second = try decode(engine, buffer: buffer, range: range, context: context, language: language, params: again, control: control)
            if similarity(text, second.text) < 0.6 { return Piece(range: range, text: "", trimmed: true) }
            return Piece(range: range, text: units(text, language: language) <= units(second.text, language: language) ? text : second.text, trimmed: true)
        }
        let first = try decode(engine, buffer: buffer, range: range, context: context, language: language, params: params, control: control)
        if !retry || !looksBad(first.text, truncated: first.truncated) {
            return [try guarded(first.text)]
        }
        // 1. 加重复惩罚和一点温度再来一次
        params.repeat_penalty = 1.3
        params.repeat_last_n = 128
        params.temperature = 0.2
        params.seed = 1
        let second = try decode(engine, buffer: buffer, range: range, context: context, language: language, params: params, control: control)
        if !looksBad(second.text, truncated: second.truncated) {
            return [try guarded(second.text)]
        }
        // 2. 够长就切成两半各自再来
        if seconds >= 6 && depth < 3 {
            let half = chunks(Array(buffer[range]), turns: [], maxSeconds: seconds / 2)
            if half.count >= 2 {
                var pieces: [Piece] = []
                for part in half {
                    let sub = (range.lowerBound + part.range.lowerBound)..<(range.lowerBound + part.range.upperBound)
                    pieces += try run(engine, buffer: buffer, range: sub, context: context, language: language, control: control, retry: true,
                                      guardMedian: guardMedian, depth: depth + 1)
                }
                return pieces
            }
        }
        // 3. 留压缩比较低的那次，重复的片段缩成 3 次，标成低信心
        let best = WhisperEngine.compressionRatio(first.text) <= WhisperEngine.compressionRatio(second.text) ? first.text : second.text
        return [Piece(range: range, text: trimRepeats(best), trimmed: true)]
    }

    private static func decode(_ engine: OpaquePointer, buffer: UnsafeBufferPointer<Float>, range: Range<Int>, context: String, language: String,
                               params: qwen_params, control: WhisperEngine.Control) throws -> (text: String, truncated: Bool) {
        var params = params
        var out = [CChar](repeating: 0, count: 1 << 16)
        var produced: Int32 = 0
        let rc: Int32 = context.withCString { contextPointer in
            language.withCString { languagePointer in
                params.context = contextPointer
                params.language = languagePointer
                let abort: qwen_abort_fn = { user in
                    guard let user else { return false }
                    return Unmanaged<WhisperEngine.Control>.fromOpaque(user).takeUnretainedValue().isCancelled
                }
                return qwen_transcribe(engine, buffer.baseAddress! + range.lowerBound, Int32(range.count), &params,
                                       abort, Unmanaged.passUnretained(control).toOpaque(), &out, Int32(out.count), &produced)
            }
        }
        if rc == -1 || control.isCancelled { throw WhisperError.cancelled }
        guard rc >= 0 || rc == -5 else { throw WhisperError.failed(rc) }
        return (clean(String(cString: out)), rc == 1 || rc == -5)
    }

    /// 去掉 tokenizer 漏出来的私用区字符和前后空白；模型把缩写一个字母一个字母拆开（「A P P」「O T P」），并回去
    static func clean(_ text: String) -> String {
        let stripped = String(text.unicodeScalars.filter { !(0xE000...0xF8FF).contains($0.value) }.map { Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joinSpelledAcronyms(stripped)
    }

    private static let spelled = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])(?:[A-Z] )+[A-Z](?![A-Za-z0-9])")

    /// 「A P P」→「APP」：两个以上单独的大写字母用空白隔开时并成一个字
    static func joinSpelledAcronyms(_ text: String) -> String {
        let ns = text as NSString
        var result = text
        for match in spelled.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let joined = ns.substring(with: match.range).replacingOccurrences(of: " ", with: "")
            result = (result as NSString).replacingCharacters(in: match.range, with: joined)
        }
        return result
    }

    /// 同一个 1～6 字的片段连续出现 5 次以上
    private static let repeats = try! NSRegularExpression(pattern: "(.{1,6}?)\\1{4,}", options: [.dotMatchesLineSeparators])

    static func looksBad(_ text: String, truncated: Bool) -> Bool {
        truncated || WhisperEngine.compressionRatio(text) > 2.4
            || repeats.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 连续重复的片段缩成 3 次（「对对对对对对对对」→「对对对」）
    static func trimRepeats(_ text: String) -> String {
        let ns = text as NSString
        var result = text
        for match in repeats.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let unit = ns.substring(with: match.range(at: 1))
            result = (result as NSString).replacingCharacters(in: match.range, with: String(repeating: unit, count: 3))
        }
        return result
    }
}
