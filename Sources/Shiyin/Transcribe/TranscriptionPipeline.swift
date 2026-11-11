import Foundation

/// 转录的设置（design §6、§17）。JobRunner 用目前的 app 设置产生；评估工具（shiyinctl transcribe-eval）从 JSON 读，
/// 同一段录音可以换设置重跑比较（§17.1）
struct TranscriptionOptions: Codable {
    /// breeze：whisper.cpp，模型依会议语言（中文、英文 Breeze，日文 large-v3-turbo，design §18.2）；system：macOS 内置识别；
    /// qwen：Qwen3-ASR（llama.cpp，中文、英文，design §32）；server：企业服务器（design §36.3，说话者照样在本机识别）
    enum Engine: String, Codable { case breeze, system, qwen, server }
    /// 分声道时怎么处理麦克风收到的回音（design §17.3）
    enum Echo: String, Codable {
        case none
        case dedupe   // 转录后删掉跟电脑声音重复的麦克风段落
    }

    var engine: Engine = .breeze
    var language: MeetingLanguage = .zh
    var glossary: [String] = []
    var diarize = true
    /// 双声道录音（麦克风、电脑声音）分开转录（design §17.3）；还在评估，设置里没有开关
    var splitChannels = false
    var echo: Echo = .dedupe
    /// 评估用：换一个 whisper 模型档（design §18.2 比较日文引擎）；nil 依会议语言选
    var model: String?
    /// 没分声道时声纹记成哪种收音（design §21.4）：mic、system，双声道混在一起是 mix
    var audioSource = "mix"
    /// whisper 每段几秒（design §21.16、D34）；评估时设 0 不分段
    var chunkSeconds: Double = 600
    /// 说话者识别至少分出几个人（design §23.2），nil 自动判断
    var minSpeakers: Int?
    /// 评估用：whisper 解码参数和提示词的写法（design §17.1）；nil 用 app 的默认值。正式转录不设
    var tuning: DecoderTuning?

    /// whisper 解码的实验开关（只有 transcribe-eval 会设）：每一项 nil 就用 whisper.cpp 或 app 的默认值
    struct DecoderTuning: Codable {
        /// whisper.cpp 的 no_context（默认 true：每个 30 秒的窗只用基本提示词，不接前一个窗的文字）
        var noContext: Bool?
        var beamSize: Int?
        /// 默认 0.2；-1 关掉信心不够时升温重试
        var temperatureInc: Float?
        var entropyThold: Float?
        var logprobThold: Float?
        var noSpeechThold: Float?
        /// 压掉非语音的 token（音乐、掌声这类标记）
        var suppressNst: Bool?
        /// 不做 app 的幻觉过滤，看过滤丢掉了什么
        var keepAll: Bool?
        /// 提示词的写法：nil 是现在的「以下是…词汇：…」；natural 是写成像逐字稿的一句话（design §17.1）
        var promptStyle: String?
        /// 段落最长几个字（搭配 split_on_word），0 或 nil 不限制
        var maxLen: Int?
        /// Qwen3-ASR（design §32.4）：每段最长几秒（默认 15）、跳针时要不要重试（默认 true）、要不要先识别说话者再分段（默认 true）
        var qwenChunkSeconds: Double?
        var qwenRetry: Bool?
        var qwenTurns: Bool?
        var qwenGuard: Bool?
        var qwenCutsAny: Bool?
        var qwenSplitMixed: Bool?
    }

    init() {}

    /// 写进 meetings.transcribed_with（design §21.17）
    var transcribedWith: String { engine == .system ? "system" : engine == .qwen ? "qwen" : language.usesTurbo ? "japanese" : "breeze" }

    /// local：用户在这一场按了「改在这台电脑转录」（R50.5），不用企业服务器
    @MainActor
    static func current(language: MeetingLanguage, glossary: [String], channels: String, minSpeakers: Int? = nil,
                        local: Bool = false) -> TranscriptionOptions {
        var options = TranscriptionOptions()
        options.minSpeakers = minSpeakers
        // 这个语言的模型还没下载好时，这一场先用 macOS 内置识别（design §21.17、D35）；
        // 中文、英文选了 Qwen3-ASR（design §32.3）而还没下载好、已经有 Breeze 时先用 Breeze（R43.7）；
        // 固定用 Qwen3-ASR 的语言（粤语）不用 Breeze，先用内置（design §41.3）
        let wanted = ModelStore.transcription(for: language)
        // 企业服务器（R50.1）：登录失效时也照样选它，工作停着等重新登录（R49.4）
        if AppSettings.usesEnterpriseTranscription && !local { options.engine = .server }
        else if AppSettings.useSystemTranscriber { options.engine = .system }
        else if ModelStore.isDownloaded(wanted) { options.engine = wanted == .qwen ? .qwen : .breeze }
        else if wanted == .qwen && language.profile.transcription.engineSetting && ModelStore.isDownloaded(.breeze) { options.engine = .breeze }
        else { options.engine = .system }
        options.language = language
        options.glossary = glossary
        options.diarize = AppSettings.diarize
        // 只有录音时选了「麦克风＋电脑声音」的会议才分声道；导入的双声道文件（音乐、视频）照旧混成一轨
        options.splitChannels = AppSettings.splitChannels && channels == "both"
        options.audioSource = channels == "both" ? "mix" : channels
        return options
    }

    // 评估用的 JSON 只写要改的字段，其他用默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decodeIfPresent(Engine.self, forKey: .engine) ?? .breeze
        language = try c.decodeIfPresent(MeetingLanguage.self, forKey: .language) ?? .zh
        glossary = try c.decodeIfPresent([String].self, forKey: .glossary) ?? []
        diarize = try c.decodeIfPresent(Bool.self, forKey: .diarize) ?? true
        splitChannels = try c.decodeIfPresent(Bool.self, forKey: .splitChannels) ?? false
        echo = try c.decodeIfPresent(Echo.self, forKey: .echo) ?? .dedupe
        model = try c.decodeIfPresent(String.self, forKey: .model)
        audioSource = try c.decodeIfPresent(String.self, forKey: .audioSource) ?? "mix"
        chunkSeconds = try c.decodeIfPresent(Double.self, forKey: .chunkSeconds) ?? 600
        minSpeakers = try c.decodeIfPresent(Int.self, forKey: .minSpeakers)
        tuning = try c.decodeIfPresent(DecoderTuning.self, forKey: .tuning)
    }
}

struct TranscriptionResult {
    var segments: [TranscribedSegment]
    var speakers: [Int?]
    /// 分声道时每段来自哪个声道（0 麦克风、1 电脑声音）；没分声道时都是 nil
    var channels: [Int?]
    var duration: Double
    /// 每位说话者（逐字稿上的编号）的声纹、说话秒数、收音（design §21.4）
    var voices: [Int: SpeakerVoice] = [:]
    /// whisper 分段的位置（秒）；评估工具用来检查接缝
    var seams: [Double] = []
    /// 说话者识别分得准不准的线索（design §24.3）；分声道、没识别时是 nil
    var diarizationQuality: Diarizer.Quality? = nil
    /// 企业服务器用的引擎（breeze、qwen、japanese）：写进 transcribed_with，取代 options.transcribedWith（design §36.3）
    var transcribedWith: String? = nil
}

struct SpeakerVoice {
    var embedding: [Float]
    var seconds: Double
    var source: String     // mic / system / mix
}

/// 转录流程：解码 → 识别 → 说话者识别（design §6）；双声道录音可以分开转录再合并（§17.3）
@MainActor
struct TranscriptionPipeline {
    var options: TranscriptionOptions
    /// whisper 模型档（engine 是 breeze 时用）：评估时可以指定，平常依会议语言选。不看引擎设置：设置是 Qwen 时 transcription(for:) 回 qwen，
    /// 但 whisper 这条路只认 Breeze 和 large-v3-turbo（2026-10-24 评估时 Breeze 跑去载 GGUF 而失败）
    var modelPath: String { options.model ?? ModelStore.path(options.language.usesTurbo ? .japanese : .breeze).path }
    /// 目前在做哪一步（显示在会议列表）
    var stage: (String) -> Void = { _ in }
    /// 整体进度 0～1，会从背景线程调用
    var progress: @Sendable (Double) -> Void = { _ in }
    /// 这一步要怎么取消（whisper 用 Control，macOS 内置用 Task）
    var setCancel: (@escaping () -> Void) -> Void = { _ in }
    /// 每一步之间检查工作是否还要继续
    var shouldContinue: () -> Bool = { true }
    /// 企业服务器（design §36.3）：上次传到一半、还没拿到结果的工作 id；换了就告诉 JobRunner 记下来
    var remoteId: String?
    var onRemoteId: (String?) -> Void = { _ in }
    /// 企业服务器的状态（排队第几、为什么在等）；nil 是服务器的部分做完了
    var onServer: (ServerNote?) -> Void = { _ in }
    /// 用户按了「改在这台电脑转录」（R50.5）
    var switchToLocal: () -> Bool = { false }

    /// 回传 nil 表示中途被取消
    func run(_ audio: URL) async throws -> TranscriptionResult? {
        guard var result = try await runEngine(audio) else { return nil }
        // 中文、粤语的结果一律转大陆简体（design §45、D151）：Breeze 输出台湾繁体，其他引擎的输出也可能夹杂繁体
        for i in result.segments.indices { result.segments[i].text = options.language.outputScript(result.segments[i].text) }
        return result
    }

    private func runEngine(_ audio: URL) async throws -> TranscriptionResult? {
        if options.engine == .server { return try await runServer(audio) }
        if options.engine == .qwen {
            guard ModelStore.isDownloaded(.qwen) else { throw WhisperError.modelMissing }
            return try await runQwen(audio)
        }
        guard options.engine == .system || FileManager.default.fileExists(atPath: modelPath) else { throw WhisperError.modelMissing }
        stage(String(localized: "读取录音"))
        if options.splitChannels {
            let channels = try await AudioDecoder.decodeChannels(audio)
            if channels.count == 2 { return try await runSplit(microphone: channels[0], system: channels[1]) }
        }
        if options.engine == .breeze { return try await runStreaming(audio) }
        let samples = try await AudioDecoder.decode(audio)
        guard shouldContinue() else { return nil }
        let duration = Double(samples.count) / AudioDecoder.sampleRate
        let diarize = options.diarize && duration > 5
        let share = diarize ? 0.85 : 1.0
        let report = progress
        progress(0)
        guard let (transcribed, seams) = try await transcribe(samples, from: 0, span: share) else { return nil }
        var speakers: [Int?] = transcribed.map { _ in nil }
        var voices: [Int: SpeakerVoice] = [:]
        var quality: Diarizer.Quality?
        if diarize {
            stage(String(localized: "识别说话者"))
            (speakers, voices, quality) = await self.speakers(of: transcribed, in: samples, source: options.audioSource) { report(share + $0 * (1 - share)) }
        }
        guard shouldContinue() else { return nil }
        return TranscriptionResult(segments: transcribed, speakers: speakers, channels: transcribed.map { _ in nil }, duration: duration,
                                   voices: voices, seams: seams, diarizationQuality: quality)
    }

    // MARK: 企业服务器（design §36.3、R50）

    /// 录音解成 16 kHz 单声道、写成 16-bit WAV 上传；服务器转录的同时，Mac 在本机识别说话者（声纹跟本机一样，D122）
    private func runServer(_ audio: URL) async throws -> TranscriptionResult? {
        stage(String(localized: "读取录音"))
        let samples = try await AudioDecoder.decode(audio)
        guard shouldContinue() else { return nil }
        let duration = Double(samples.count) / AudioDecoder.sampleRate
        let folder = try Paths.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("upload.wav")
        let samplesForWAV = samples
        let (bytes, sha256) = try await Task.detached(priority: .userInitiated) { try ServerTranscriber.writeWAV(samplesForWAV, to: wav) }.value
        guard shouldContinue() else { return nil }
        progress(0)

        // 说话者识别不用等逐字稿，跟服务器同时做
        let diarize = options.diarize && duration > 5
        let minSpeakers = options.minSpeakers
        let diarization: Task<Diarizer.Output?, Never>? = diarize ? Task {
            do { return try await Diarizer.diarize(samples: samples, minSpeakers: minSpeakers) { _ in } }
            catch { log.error("diarization failed: \(error.localizedDescription, privacy: .public)"); return nil }
        } : nil
        defer { diarization?.cancel() }

        let transcriber = ServerTranscriber(options: options, stage: stage, progress: progress, shouldContinue: shouldContinue,
                                            switchToLocal: switchToLocal, onServer: onServer, onRemoteId: onRemoteId)
        guard let remote = try await transcriber.transcribe(wav: wav, bytes: bytes, sha256: sha256, remoteId: remoteId) else { return nil }
        var speakers: [Int?] = remote.segments.map { _ in nil }
        var voices: [Int: SpeakerVoice] = [:]
        var quality: Diarizer.Quality?
        if let diarization {
            stage(String(localized: "识别说话者"))
            if let output = await diarization.value {
                guard shouldContinue() else { return nil }
                (speakers, voices) = await assignSpeakers(output, to: remote.segments, in: samples, source: options.audioSource)
                quality = output.quality
            }
        }
        progress(1)
        guard shouldContinue() else { return nil }
        return TranscriptionResult(segments: remote.segments, speakers: speakers, channels: remote.segments.map { _ in nil }, duration: duration,
                                   voices: voices, seams: remote.seams, diarizationQuality: quality, transcribedWith: remote.engine)
    }

    // MARK: whisper 从文件依序读（design §21.16）

    /// whisper 一段一段从文件读，说话者识别时才解码整段：转录时内存里不用留整段录音
    private func runStreaming(_ audio: URL) async throws -> TranscriptionResult? {
        guard shouldContinue() else { return nil }
        stage(String(localized: "转录"))
        // 还不知道长度（太短不识别说话者），先照要识别说话者算进度
        let share = options.diarize ? 0.85 : 1.0
        let report = progress
        progress(0)
        let control = WhisperEngine.Control { report($0 * share) }
        setCancel { control.cancel() }
        let prompt = WhisperEngine.prompt(glossary: options.glossary, language: options.language, style: options.tuning?.promptStyle)
        let (path, code, chunkSeconds, tuning) = (modelPath, options.language.whisperCode, options.chunkSeconds, options.tuning)
        let result = try await Task.detached(priority: .userInitiated) {
            try await WhisperEngine.transcribe(file: audio, chunkSeconds: chunkSeconds, modelPath: path, prompt: prompt, language: code,
                                               control: control, tuning: tuning)
        }.value
        guard shouldContinue() else { return nil }
        let duration = Double(result.sampleCount) / AudioDecoder.sampleRate
        var speakers: [Int?] = result.segments.map { _ in nil }
        var voices: [Int: SpeakerVoice] = [:]
        var quality: Diarizer.Quality?
        if options.diarize && duration > 5 {
            stage(String(localized: "识别说话者"))
            let samples = try await AudioDecoder.decode(audio)
            guard shouldContinue() else { return nil }
            (speakers, voices, quality) = await self.speakers(of: result.segments, in: samples, source: options.audioSource) {
                report(share + $0 * (1 - share))
            }
        }
        guard shouldContinue() else { return nil }
        return TranscriptionResult(segments: result.segments, speakers: speakers, channels: result.segments.map { _ in nil },
                                   duration: duration, voices: voices, seams: result.seams.map { Double($0) / AudioDecoder.sampleRate },
                                   diarizationQuality: quality)
    }

    // MARK: Qwen3-ASR（design §32.4）

    /// 先解码整段、先识别说话者，再依说话者片段和安静处分段转录；段落的时间就是分段的时间，说话者是那一段重叠最多的人
    private func runQwen(_ audio: URL) async throws -> TranscriptionResult? {
        stage(String(localized: "读取录音"))
        let samples = try await AudioDecoder.decode(audio)
        guard shouldContinue() else { return nil }
        let duration = Double(samples.count) / AudioDecoder.sampleRate
        let diarize = options.diarize && duration > 5 && options.tuning?.qwenTurns != false
        let report = progress
        progress(0)
        var output: Diarizer.Output?
        let share = diarize ? 0.15 : 0.0
        if diarize {
            stage(String(localized: "识别说话者"))
            do {
                output = try await Diarizer.diarize(samples: samples, minSpeakers: options.minSpeakers) { report($0 * share) }
            } catch {
                log.error("diarization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard shouldContinue() else { return nil }
        stage(String(localized: "转录"))
        let control = WhisperEngine.Control { report(share + $0 * (1 - share)) }
        setCancel { control.cancel() }
        let chunks = QwenEngine.chunks(samples, turns: output?.turns ?? [], maxSeconds: options.tuning?.qwenChunkSeconds ?? QwenEngine.maxChunkSeconds,
                                       anyChange: options.tuning?.qwenCutsAny ?? false, splitMixed: options.tuning?.qwenSplitMixed ?? true)
        let (language, glossary, retry, useGuard) = (options.language, options.glossary, options.tuning?.qwenRetry ?? true, options.tuning?.qwenGuard ?? true)
        let (modelPath, encoderPath) = (ModelStore.path(.qwen).path, ModelStore.path(.qwenEncoder).path)
        let segments = try await Task.detached(priority: .userInitiated) {
            try QwenEngine.transcribe(samples: samples, chunks: chunks, modelPath: modelPath, encoderPath: encoderPath, language: language,
                                      glossary: glossary, control: control, retry: retry, guard: useGuard)
        }.value
        guard shouldContinue() else { return nil }
        var speakers: [Int?] = segments.map { _ in nil }
        var voices: [Int: SpeakerVoice] = [:]
        if let output {
            (speakers, voices) = await assignSpeakers(output, to: segments, in: samples, source: options.audioSource)
        }
        return TranscriptionResult(segments: segments, speakers: speakers, channels: segments.map { _ in nil }, duration: duration,
                                   voices: voices, seams: chunks.dropFirst().map { Double($0.range.lowerBound) / AudioDecoder.sampleRate },
                                   diarizationQuality: output?.quality)
    }

    /// 已经识别好说话者：段落依重叠量标说话者、短句再确认（R34）、每位说话者的声纹（跟 speakers(of:in:source:) 后半一样）
    private func assignSpeakers(_ output: Diarizer.Output, to segments: [TranscribedSegment], in samples: [Float],
                                source: String) async -> ([Int?], [Int: SpeakerVoice]) {
        var (speakers, numbering) = Diarizer.assignNumbering(output.turns, to: segments)
        do {
            speakers = try await SpeakerRecheck.refine(segments, speakers: speakers, samples: samples)
        } catch {
            log.error("speaker recheck failed: \(error.localizedDescription, privacy: .public)")
        }
        var voices: [Int: SpeakerVoice] = [:]
        for (raw, number) in numbering {
            if let embedding = output.voiceprints[raw] {
                voices[number] = SpeakerVoice(embedding: embedding, seconds: output.speechSeconds[raw] ?? 0, source: source)
            }
        }
        return (speakers, voices)
    }

    // MARK: 分声道（design §17.3）

    private func runSplit(microphone: [Float], system: [Float]) async throws -> TranscriptionResult? {
        guard shouldContinue() else { return nil }
        let duration = Double(max(microphone.count, system.count)) / AudioDecoder.sampleRate
        let diarize = options.diarize && duration > 5
        let report = progress
        progress(0)

        // 两个声道各自转录、各自识别说话者；没有声音的声道（例如没有播放任何声音）直接跳过
        var parts: [(channel: Int, segments: [TranscribedSegment], speakers: [Int?], voices: [Int: SpeakerVoice])] = []
        let inputs = [(0, microphone), (1, system)].filter { Self.hasSound($0.1) }
        for (index, (channel, samples)) in inputs.enumerated() {
            let base = Double(index) / Double(inputs.count), width = 1 / Double(inputs.count)
            let share = diarize ? 0.85 : 1.0
            guard let (segments, _) = try await transcribe(samples, from: base, span: width * share) else { return nil }
            var speakers: [Int?] = segments.map { _ in nil }
            var voices: [Int: SpeakerVoice] = [:]
            if diarize && !segments.isEmpty {
                stage(String(localized: "识别说话者"))
                (speakers, voices, _) = await self.speakers(of: segments, in: samples, source: channel == 0 ? "mic" : "system") {
                    report(base + width * (share + $0 * (1 - share)))
                }
            }
            guard shouldContinue() else { return nil }
            parts.append((channel, segments, speakers, voices))
        }

        // 说话者编号：麦克风那一边的人先编，电脑声音那一边接着编
        var merged: [(segment: TranscribedSegment, speaker: Int?, channel: Int)] = []
        var offsetVoices: [Int: SpeakerVoice] = [:]
        var offset = 0
        for part in parts {
            merged += zip(part.segments, part.speakers).map { ($0, $1.map { $0 + offset }, part.channel) }
            for (number, voice) in part.voices { offsetVoices[number + offset] = voice }
            offset += part.speakers.compactMap { $0 }.max() ?? 0
        }
        if options.echo == .dedupe {
            let systemSegments = merged.filter { $0.channel == 1 }.map(\.segment)
            merged.removeAll { $0.channel == 0 && Self.isEcho($0.segment, of: systemSegments) }
        }
        merged.sort { $0.segment.start < $1.segment.start }
        let segments = merged.map(\.segment)
        // 删掉回音段落后，说话者编号可能有空号，依出现顺序重新编
        var numbering: [Int: Int] = [:]
        let speakers: [Int?] = merged.map { item in
            guard let speaker = item.speaker else { return nil }
            if let number = numbering[speaker] { return number }
            numbering[speaker] = numbering.count + 1
            return numbering.count
        }
        if segments.isEmpty { throw WhisperError.empty }
        var voices: [Int: SpeakerVoice] = [:]
        for (old, new) in numbering { if let voice = offsetVoices[old] { voices[new] = voice } }
        return TranscriptionResult(segments: segments, speakers: speakers, channels: merged.map(\.channel), duration: duration,
                                   voices: voices)
    }

    /// 方均根低于 -70 dBFS 就当作没有声音
    private static func hasSound(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var sum: Double = 0
        for s in samples { sum += Double(s * s) }
        return (sum / Double(samples.count)).squareRoot() > 3e-4
    }

    /// 麦克风段落跟电脑声音的某一段时间重叠一半以上、文字也很像，就是喇叭的回音
    nonisolated static func isEcho(_ segment: TranscribedSegment, of system: [TranscribedSegment]) -> Bool {
        let length = max(segment.end - segment.start, 0.01)
        let text = comparable(segment.text)
        guard !text.isEmpty else { return false }
        return system.contains { other in
            let overlap = min(segment.end, other.end) - max(segment.start, other.start)
            guard overlap / length > 0.5 else { return false }
            return similarity(text, comparable(other.text)) > 0.6
        }
    }

    /// 两句几乎一样（最长共同子序列 ÷ 较长那句的长度 > 0.8）；whisper 分段的接缝去掉重复用
    nonisolated static func similar(_ a: String, _ b: String) -> Bool {
        let x = comparable(a), y = comparable(b)
        guard min(x.count, y.count) >= 4 else { return false }
        return similarity(x, y) * Double(min(x.count, y.count)) / Double(max(x.count, y.count)) > 0.8
    }

    private nonisolated static func comparable(_ text: String) -> [Character] {
        text.lowercased().filter { $0.isLetter || $0.isNumber }.map { $0 }
    }

    /// 最长共同子序列 ÷ 较短那段的长度
    private nonisolated static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var cur = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() { cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j]) }
            prev = cur
        }
        return Double(prev[b.count]) / Double(min(a.count, b.count))
    }

    // MARK: 共用步骤

    /// 识别一段声音；进度换算到整体的 from…from+span。回传 nil 表示被取消；没有识别出任何文字时回传空数组。
    /// 另外回传 whisper 分段的位置（秒）
    private func transcribe(_ samples: [Float], from base: Double, span: Double) async throws -> ([TranscribedSegment], [Double])? {
        let report = progress
        let useSystem = options.engine == .system
        stage(useSystem ? String(localized: "转录（macOS 内置）") : String(localized: "转录"))
        let segments: [TranscribedSegment]
        var seams: [Double] = []
        do {
            if useSystem {
                let language = options.language
                let task = Task {
                    try await SystemTranscriber.transcribe(samples: samples, language: language) { report(base + $0 * span) }
                }
                setCancel { task.cancel() }
                segments = try await task.value
            } else {
                let control = WhisperEngine.Control { report(base + $0 * span) }
                setCancel { control.cancel() }
                let prompt = WhisperEngine.prompt(glossary: options.glossary, language: options.language, style: options.tuning?.promptStyle)
                let (path, code, chunkSeconds, tuning) = (modelPath, options.language.whisperCode, options.chunkSeconds, options.tuning)
                let chunks: [Range<Int>]
                (segments, chunks) = try await Task.detached(priority: .userInitiated) {
                    let chunks = WhisperEngine.chunks(samples, seconds: chunkSeconds)
                    return (try WhisperEngine.transcribe(samples: samples, chunks: chunks, modelPath: path, prompt: prompt, language: code,
                                                         control: control, tuning: tuning), chunks)
                }.value
                seams = chunks.dropFirst().map { Double($0.lowerBound) / AudioDecoder.sampleRate }
            }
        } catch WhisperError.empty where options.splitChannels {
            // 分声道时某一边没人说话是正常的
            segments = []
        }
        return shouldContinue() ? (segments, seams) : nil
    }

    /// 说话者识别；失败不影响逐字稿，回传全部没有说话者
    /// 每段的说话者，以及每位说话者的声纹（换成逐字稿上的编号）
    private func speakers(of segments: [TranscribedSegment], in samples: [Float], source: String,
                          onProgress: @escaping @Sendable (Double) -> Void) async -> ([Int?], [Int: SpeakerVoice], Diarizer.Quality?) {
        do {
            let output = try await Diarizer.diarize(samples: samples, minSpeakers: options.minSpeakers, onProgress: onProgress)
            var (speakers, numbering) = Diarizer.assignNumbering(output.turns, to: segments)
            // 短句再跟每位说话者比一次（R34、design §6.3.2）；模型下载不了或算不出来就照说话者识别的结果
            do {
                speakers = try await SpeakerRecheck.refine(segments, speakers: speakers, samples: samples)
            } catch {
                log.error("speaker recheck failed: \(error.localizedDescription, privacy: .public)")
            }
            var voices: [Int: SpeakerVoice] = [:]
            for (raw, number) in numbering {
                if let embedding = output.voiceprints[raw] {
                    voices[number] = SpeakerVoice(embedding: embedding, seconds: output.speechSeconds[raw] ?? 0, source: source)
                }
            }
            return (speakers, voices, output.quality)
        } catch {
            log.error("diarization failed: \(error.localizedDescription, privacy: .public)")
            return (segments.map { _ in nil }, [:], nil)
        }
    }
}
