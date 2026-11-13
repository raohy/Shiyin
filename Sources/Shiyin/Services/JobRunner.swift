import AVFoundation
import Foundation
import Observation
import os

let log = Logger(subsystem: "com.weiwei.shiyin", category: "app")

/// 设置（UserDefaults）。界面用 @AppStorage 读写同样的 key。
enum AppSettings {
    static let providerKey = "llmProvider"
    static let autoSummarizeKey = "autoSummarize"
    static let compressAudioKey = "compressAudio"
    static let diarizeKey = "diarize"
    static let splitChannelsKey = "splitChannels"
    static let correctTranscriptKey = "correctTranscript"
    static let liveTranscriptionKey = "liveTranscription"
    static let autoDetectLanguageKey = "autoDetectLanguage"
    static let recordSourceKey = "recordSource"          // mic / system / both
    static let inputDeviceKey = "inputDeviceUID"
    static let defaultTemplateKey = "defaultTemplate"
    static let globalHotKeyKey = "globalHotKey"
    static let transcriptionEngineKey = "transcriptionEngine"   // breeze / qwen / system（没有值 = breeze，design §32.6）
    static let defaultMeetingLanguageKey = "defaultMeetingLanguage"   // zh / en / ja
    static let voiceprintsKey = "voiceprints"
    static let meetingDetectionKey = "meetingDetection"
    static let bookmarkHotKeyKey = "bookmarkHotKey"
    static let idleStopKey = "idleStop"
    static let textSizeKey = "contentTextSize"   // 会议内容的文字大小，−1～5，0 是 100%（design §38.5）
    static let notesViewKey = "notesView"   // 记录标签页：list（条列）／mindMap（心智图，design §42.4）
    static let mcpEnabledKey = "mcpEnabled"   // 让 AI 工具读取会议（本地 MCP，design §44.1），默认关

    private static var d: UserDefaults { .standard }

    /// 开关类的设置。不能用 `object(forKey:) as? Bool`：启动参数（`-autoSummarize NO`）读进来是字符串 "NO"，
    /// 转不成 Bool 会落回默认值；`bool(forKey:)` 认得字符串的 YES、NO
    private static func flag(_ key: String, default value: Bool) -> Bool {
        d.object(forKey: key) == nil ? value : d.bool(forKey: key)
    }

    #if DEBUG
    /// shiyinctl llmprovider：只在内存换整理工具，不改跟用户共用的设置（design §19.5）
    nonisolated(unsafe) static var debugProvider: LLMProvider?
    nonisolated(unsafe) static var debugModel: String?
    #endif

    /// 用户选过的整理工具；没选过（或不是认得的值）是 nil（R35）
    static var chosenProvider: LLMProvider? { LLMProvider(rawValue: d.string(forKey: providerKey) ?? "") }

    /// 没选过时自动用这台 Mac 上有的 CLI（先 claude 再 codex），都没有就先不整理（R35.1、design §19.6）。
    /// 每次都重新找：之后装了 CLI 就自动用上
    static var detectedProvider: LLMProvider {
        if Paths.findTool("claude") != nil { return .claude }
        if Paths.findTool("codex") != nil { return .codex }
        return .none
    }

    static var provider: LLMProvider {
        #if DEBUG
        if let debugProvider { return debugProvider }
        #endif
        return chosenProvider ?? detectedProvider
    }

    /// 还没选过整理工具、也找不到 CLI：界面说「还没设置整理工具」，不说「不整理」（R35.2）
    static var needsProviderSetup: Bool {
        #if DEBUG
        if debugProvider != nil { return false }
        #endif
        return chosenProvider == nil && provider == .none
    }
    static var model: String {
        #if DEBUG
        if let debugModel { return debugModel }
        #endif
        return d.string(forKey: provider.modelKey) ?? ""
    }
    static var autoSummarize: Bool { flag(autoSummarizeKey, default: true) }
    static var mcpEnabled: Bool { flag(mcpEnabledKey, default: false) }
    static var compressAudio: Bool { flag(compressAudioKey, default: true) }
    static var diarize: Bool { flag(diarizeKey, default: true) }
    /// 在线会议的麦克风、电脑声音分开转录（design §17.3）；还在评估，设置里没有开关，测试时用 defaults 打开
    static var splitChannels: Bool { flag(splitChannelsKey, default: false) }
    /// 转录完先找出可能听错的字（design §17.4）；评估后默认打开（§17.6）
    static var correctTranscript: Bool { flag(correctTranscriptKey, default: true) }
    static var liveTranscription: Bool { flag(liveTranscriptionKey, default: true) }
    /// 录音开始后自动检测主要语言（design §18.8、R16）
    static var autoDetectLanguage: Bool { flag(autoDetectLanguageKey, default: true) }
    static var recordSource: String { d.string(forKey: recordSourceKey) ?? "mic" }
    static var inputDeviceUID: String { d.string(forKey: inputDeviceKey) ?? "" }
    static var defaultTemplate: String { d.string(forKey: defaultTemplateKey) ?? "general" }
    static var globalHotKey: Bool { flag(globalHotKeyKey, default: true) }
    /// 记住说话者的声音，之后的会议自动带入名字（design §21.4、R19.3）
    static var voiceprints: Bool { flag(voiceprintsKey, default: true) }
    /// 录音中按 ⌃⌥⌘B 标记重点（design §21.10、R19.5）
    static var bookmarkHotKey: Bool { flag(bookmarkHotKeyKey, default: true) }
    /// 很久没人说话时提醒，30 分钟后自动停止（design §35、R48.5）
    static var idleStop: Bool { flag(idleStopKey, default: true) }
    /// 正式转录用 macOS 内置识别（design §6.2.1）
    static var useSystemTranscriber: Bool { d.string(forKey: transcriptionEngineKey) == "system" }
    /// 正式转录引擎（design §32.6）：breeze（默认，联发科）、qwen（阿里巴巴，可选）、system；不认得的值当 breeze
    static var transcriptionEngine: String {
        let value = d.string(forKey: transcriptionEngineKey) ?? ""
        return ["breeze", "qwen", "system", "server"].contains(value) ? value : "breeze"
    }
    /// 正式转录用企业服务器（design §36.3、R50.1）：选了而且登录过（登录失效也算，工作停着等重新登录）
    @MainActor static var usesEnterpriseTranscription: Bool {
        transcriptionEngine == "server" && EnterpriseServer.shared.hasAccount
    }
    /// 本 fork 的中文和粤语统一使用大陆简体，与转录语言档保持一致。
    static func simplifiedChinese(for language: MeetingLanguage) -> Bool {
        language.profile.transcription.simplified == true
    }
    static func script(_ text: String, for language: MeetingLanguage) -> String {
        language.outputScript(text)
    }
    /// 新会议的会议语言（design §16.3）；没设置时跟着界面语言
    static var defaultMeetingLanguage: MeetingLanguage {
        MeetingLanguage(rawValue: d.string(forKey: defaultMeetingLanguageKey) ?? "") ?? .systemDefault
    }
}

struct RevisePayload: Codable {
    var answers: [ReviewAnswer]
}

/// 整理工作的 payload：draft 是用实时逐字稿整理草稿（design §21.3）
struct SummarizePayload: Codable {
    var draft = false
}

/// 转录工作的 payload（design §35.3）：until 是只转录到第几秒（没人说话太久而自动停止的录音）；
/// remoteId 是企业服务器上还没拿到结果的工作（design §36.3），app 重开时接着传、接着等
struct TranscribePayload: Codable {
    var until: Double?
    var remoteId: String?
}

/// 工作队列：转录线、整理线各跑一个循环，互不等待（沿用 v2 §4）
@MainActor
@Observable
final class JobRunner {
    struct Running {
        var job: Job
        var startedAt = Date()
        var stage = ""                 // 目前阶段，显示用
        var progress: Double?
        /// 转录交给企业服务器时的状态：有值就显示「改在这台电脑转录」（R50.3、R50.5）
        var server: ServerNote?
        var provider: LLMProvider?
        @ObservationIgnored var cancelAction: (() -> Void)?

        /// 预估剩余秒数：已经过时间 ÷ 目前进度
        var remaining: TimeInterval? {
            guard let progress, progress > 0.03 else { return nil }
            let elapsed = Date().timeIntervalSince(startedAt)
            return elapsed / progress - elapsed
        }
    }

    private(set) var running: [JobLane: Running] = [:]
    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private var sleepers: [JobLane: Task<Void, Never>] = [:]
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onFinished: ((Job, Error?) -> Void)?
    @ObservationIgnored var onAudioReplaced: ((Int64) -> Void)?
    /// 正式版取代了用户改过的草稿（design §21.3）
    @ObservationIgnored var onEditedDraftReplaced: ((Int64) -> Void)?
    /// 重新识别说话者做完（分出几位）或失败（design §23.3）
    @ObservationIgnored var onRediarized: ((Int64, Result<Int, Error>) -> Void)?

    /// 用户按了「改在这台电脑转录」的工作（R50.5）：只在内存，app 重开后照设置
    @ObservationIgnored private var localJobs: Set<Int64> = []

    init(db: AppDatabase) {
        self.db = db
    }

    /// 这场会议正在等企业服务器的转录改在这台 Mac 转（R50.5）
    func transcribeLocally(meetingId: Int64) {
        guard let job = running[.transcribe]?.job, job.meetingId == meetingId, let id = job.id else { return }
        localJobs.insert(id)
        log.info("job \(id) switched to local transcription")
    }

    func start() {
        do { try db.requeueRunning() } catch { log.error("requeue failed: \(error.localizedDescription)") }
        for lane in JobLane.allCases {
            Task { await loop(lane) }
        }
    }

    func wake() {
        sleepers.values.forEach { $0.cancel() }
    }

    var isBusy: Bool { !running.isEmpty }

    /// 画面上显示的执行中工作：转录优先，其次是整理（用户在等的）；背景的辅助工作（压缩、校正、猜说话者）不算
    func runningJob(for meetingId: Int64) -> Running? {
        JobLane.allCases.lazy.compactMap { self.running[$0] }
            .first { $0.job.meetingId == meetingId && !$0.job.kind.isAuxiliary }
    }

    func cancel(meetingId: Int64) {
        do {
            let ids = try db.cancelJobs(meetingId)
            for state in running.values where ids.contains(state.job.id ?? -1) {
                state.cancelAction?()
            }
        } catch {
            log.error("cancel failed: \(error.localizedDescription)")
        }
        onChange?()
    }

    /// 结束 app 时：执行中的工作先改回排队（不算意外结束，design §20.5），再停止，下次打开会从头重跑
    func terminateAll() {
        do { try db.releaseRunning() } catch { log.error("release running jobs failed: \(error.localizedDescription)") }
        running.values.forEach { $0.cancelAction?() }
    }

    private func loop(_ lane: JobLane) async {
        while !Task.isCancelled {
            let job: Job?
            // 模型还没下载好的语言先用 macOS 内置识别转录（design §21.17），模型在背景下载；
            // 日文模型在日文会议第一次要转录时才下载（design §18.2）
            if lane == .transcribe && !AppSettings.useSystemTranscriber && !AppSettings.usesEnterpriseTranscription {
                for language in MeetingLanguage.allCases where !ModelStore.hasTranscriptionModel(for: language)
                    && (try? db.hasQueuedTranscribe(language: language)) == true {
                    AppModel.shared.models.autoStartTranscription(for: language)
                }
            }
            do { job = try db.claimNext(lane: lane) } catch {
                log.error("claim failed: \(error.localizedDescription)")
                job = nil
            }
            if let job {
                await execute(job, lane: lane)
                continue
            }
            let sleeper = Task<Void, Never> { try? await Task.sleep(for: .seconds(2)) }
            sleepers[lane] = sleeper
            await sleeper.value
            sleepers[lane] = nil
        }
    }

    private func execute(_ job: Job, lane: JobLane) async {
        running[lane] = Running(job: job)
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: String(localized: "拾音正在转录或整理会议记录"))
        onChange?()
        log.info("job \(job.id ?? 0) \(job.kind.rawValue) started")
        var failure: Error?
        var notify = true
        do {
            switch job.kind {
            case .transcribe: try await transcribe(job, lane: lane)
            case .summarize:
                let payload = (try? JSONDecoder().decode(SummarizePayload.self, from: Data((job.payload ?? "{}").utf8))) ?? SummarizePayload()
                notify = try await summarize(job, lane: lane, answers: nil, draft: payload.draft)
            case .revise:
                let payload = try JSONDecoder().decode(RevisePayload.self, from: Data((job.payload ?? "{}").utf8))
                notify = try await summarize(job, lane: lane, answers: payload.answers)
            case .compress: try await compress(job)
            case .correct: await correct(job, lane: lane)
            case .nameSpeakers: await nameSpeakers(job, lane: lane)
            case .rediarize: try await rediarize(job, lane: lane)
            }
        } catch {
            failure = error
        }
        ProcessInfo.processInfo.endActivity(activity)
        running[lane] = nil

        let jobId = job.id!
        if (try? db.jobStatus(jobId)) == .running {
            do {
                if let failure {
                    try db.finish(jobId, status: .failed, error: failure.localizedDescription, errorKind: failure.logSummary)
                    log.error("job \(jobId) failed: \(failure.logSummary, privacy: .public)")
                    // 设置问题（没登录、key 错误…）：暂停自动整理，设置改了、登录了、测试成功才再排（R46.3、design §34.4）
                    if job.kind == .summarize || job.kind == .revise, (failure as? LLMError)?.isSetupProblem == true,
                       AppSettings.provider != .none {
                        SummarizerPause.pause(AppSettings.provider, message: failure.localizedDescription)
                        log.info("summarizer paused after setup problem")
                    }
                } else {
                    try db.finish(jobId, status: .done)
                    log.info("job \(jobId) done")
                    if job.kind == .summarize || job.kind == .revise { SummarizerPause.clear() }
                }
                countUsage(job, failure: failure)
            } catch {
                log.error("finish failed: \(error.localizedDescription)")
            }
            // 压缩、逐字稿校正是背景的辅助工作，不发通知；有草稿时正式版不再发（design §21.3）
            if !job.kind.isAuxiliary && (notify || failure != nil) { onFinished?(job, failure) }
        }
        onChange?()
    }

    private func isStillRunning(_ job: Job) -> Bool { (try? db.jobStatus(job.id!)) == .running }

    /// 匿名使用统计（design §30.1）：只算真的跑完的工作（取消的不算）；转录成功在 transcribe 里算（要用到长度）
    private func countUsage(_ job: Job, failure: Error?) {
        switch (job.kind, failure) {
        case (.transcribe, .some): UsageStats.shared.failed(.transcribe)
        case (.rediarize, .none): UsageStats.shared.rediarized()
        case (.rediarize, .some): UsageStats.shared.failed(.diarize)
        case (.summarize, .none), (.revise, .none): UsageStats.shared.summarized(with: AppSettings.provider)
        case (.summarize, .some(let error)), (.revise, .some(let error)):
            // 种类、整理工具、是不是草稿另外记（R47、design §34.5）
            let draft = job.kind == .summarize
                && ((try? JSONDecoder().decode(SummarizePayload.self, from: Data((job.payload ?? "{}").utf8)))?.draft ?? false)
            UsageStats.shared.summarizeFailed(error, provider: AppSettings.provider, draft: draft)
        default: break
        }
    }

    /// 调用整理工具，按「取消」时 CLI 结束子程序、API 取消请求（design §21.14、R20.5）
    private func callLLM<T>(_ lane: JobLane, _ work: @escaping @MainActor (_ onStart: @escaping (Subprocess) -> Void) async throws -> T) async throws -> T {
        var process: Subprocess?
        let task = Task { @MainActor in try await work { process = $0 } }
        running[lane]?.cancelAction = { process?.terminate(); task.cancel() }
        return try await task.value
    }

    /// 自己的词＋公司的词（R53.2）：转录、猜说话者、校正、整理共用
    private func glossaryTerms() throws -> [String] { CompanyGlossary.merged(try db.glossary().map(\.term)) }

    // MARK: 转录（design §6）

    private func transcribe(_ job: Job, lane: JobLane) async throws {
        guard let meeting = try db.meeting(job.meetingId) else { return }
        let startedAt = Date()
        let payload = (try? JSONDecoder().decode(TranscribePayload.self, from: Data((job.payload ?? "{}").utf8))) ?? TranscribePayload()
        func makePipeline(local: Bool) throws -> TranscriptionPipeline {
            var pipeline = TranscriptionPipeline(options: .current(language: meeting.meetingLanguage,
                                                                    glossary: try glossaryTerms(),
                                                                    channels: meeting.channels, minSpeakers: meeting.minSpeakers, local: local))
            pipeline.stage = { [weak self] in self?.running[lane]?.stage = $0 }
            pipeline.progress = { [weak self] value in Task { @MainActor in self?.running[lane]?.progress = value } }
            pipeline.setCancel = { [weak self] in self?.running[lane]?.cancelAction = $0 }
            pipeline.shouldContinue = { [weak self] in self?.isStillRunning(job) ?? false }
            // 企业服务器（design §36.3）：记下服务器上的工作，app 重开时接着传；等服务器时画面可以改在这台 Mac 转
            pipeline.remoteId = payload.remoteId
            pipeline.onRemoteId = { [weak self] remoteId in
                var updated = payload
                updated.remoteId = remoteId
                if let id = job.id, let data = try? JSONEncoder().encode(updated) {
                    try? self?.db.setJobPayload(id, String(decoding: data, as: UTF8.self))
                }
            }
            pipeline.onServer = { [weak self] note in
                if self?.running[lane]?.server != note { self?.running[lane]?.server = note }
            }
            pipeline.switchToLocal = { [weak self] in job.id.map { self?.localJobs.contains($0) ?? false } ?? false }
            return pipeline
        }
        var pipeline = try makePipeline(local: false)
        if pipeline.options.engine == .system && !AppSettings.useSystemTranscriber {
            log.info("transcription model not ready, using the system recognizer")
        }
        // 没人说话太久而自动停止的录音：只转录到最后说话后 15 秒，录音档不动（design §35.3、R48.3）
        let until = payload.until
        let trimmed = try until.flatMap { try AudioTrim.prefix(of: meeting.audioURL, seconds: $0) }
        defer { if let trimmed { try? FileManager.default.removeItem(at: trimmed.deletingLastPathComponent()) } }
        if let until, trimmed != nil { log.info("transcribing only the first \(Int(until))s (idle auto-stop)") }
        let result: TranscriptionResult
        do {
            guard let value = try await pipeline.run(trimmed ?? meeting.audioURL) else { return }
            result = value
        } catch is ServerTranscriber.SwitchToLocal {
            // 改在这台 Mac 转（R50.5）：用本机的引擎，模型还没下载好就先下载、先用 macOS 内置（同 D35）
            running[lane]?.server = nil
            pipeline = try makePipeline(local: true)
            if !AppSettings.useSystemTranscriber { AppModel.shared.models.autoStartTranscription(for: meeting.meetingLanguage) }
            guard let value = try await pipeline.run(trimmed ?? meeting.audioURL) else { return }
            result = value
        }
        if let id = job.id { localJobs.remove(id) }
        let transcribedWith = result.transcribedWith ?? pipeline.options.transcribedWith
        let (transcribed, speakers, duration) = (result.segments, result.speakers, result.duration)
        // 只转录前段时，会议长度维持整个录音（播放、信息列用）
        let savedDuration = trimmed != nil ? max(Double(meeting.durationSeconds ?? 0), duration) : duration
        // 中文会议用简体时，存档前才转（design §47.2、D154）
        let simplified = AppSettings.simplifiedChinese(for: meeting.meetingLanguage)
        let segments = transcribed.enumerated().map { i, s in
            Segment(meetingId: job.meetingId, seq: i, start: s.start, end: s.end, text: simplified ? ChineseScript.toSimplified(s.text) : s.text,
                    lowConfidence: s.lowConfidence, speaker: speakers[i], kind: "final", channel: result.channels[i])
        }
        try db.saveTranscript(job.meetingId, segments: segments, duration: Int(savedDuration.rounded()),
                              speakerCount: speakers.compactMap { $0 }.max() ?? 0, voices: result.voices,
                              transcribedWith: transcribedWith)
        // 匿名使用统计（design §30.1）：语音长度、实际花的时间、引擎；说话者识别跟 pipeline 的条件一样
        UsageStats.shared.transcribed(seconds: duration, wallSeconds: Date().timeIntervalSince(startedAt),
                                      engine: pipeline.options.engine == .server ? "server" : transcribedWith, language: meeting.meetingLanguage,
                                      imported: meeting.source == "import", diarized: pipeline.options.diarize && duration > 5)
        // 说话者识别的碰撞率（design §24.3）：可能把人并在一起时，逐字稿标签页会提示
        try db.setSpeakerCheck(job.meetingId, result.diarizationQuality?.mergeRisk)
        // 声纹比对（design §21.4）：在整理之前，会议记录里就会是名字
        if AppSettings.voiceprints {
            let matched = try db.matchVoiceprints(job.meetingId)
            if matched > 0 { log.info("voiceprints matched \(matched) speakers") }
        }
        if AppSettings.compressAudio && meeting.audioURL.pathExtension.lowercased() == "wav" {
            try db.enqueue(job.meetingId, kind: .compress)
        }
        // 校正在辅助线、整理在整理线，两个同时开始（design §21.2、R20.1）。
        // 整理工具还没准备好（没登录、没有 key…）就都不排，不会「整理失败」（R45.4、§34.2）
        let summarizerReady = AppSettings.summarizerReady
        if !summarizerReady { log.info("summarizer not ready, skip auto jobs") }
        if AppSettings.correctTranscript && summarizerReady {
            try db.enqueue(job.meetingId, kind: .correct)
        }
        if AppSettings.autoSummarize && summarizerReady {
            try db.enqueue(job.meetingId, kind: .summarize)
            // 还有默认名称的说话者就猜名字（design §21.5）：在辅助线、校正后面，不挡整理
            if try db.speakers(job.meetingId).contains(where: { $0.nameSource == "default" }) {
                try db.enqueue(job.meetingId, kind: .nameSpeakers)
            }
        }
        wake()
    }

    // MARK: 重新识别说话者（design §23.3、R22）

    /// 只重跑说话者识别，用这场记住的人数；逐字稿文字、校正、重点、会议记录都不动
    private func rediarize(_ job: Job, lane: JobLane) async throws {
        guard let meeting = try db.meeting(job.meetingId) else { return }
        do {
            running[lane]?.stage = String(localized: "重新识别说话者")
            let samples = try await AudioDecoder.decode(meeting.audioURL)
            guard isStillRunning(job) else { return }
            let report: @Sendable (Double) -> Void = { [weak self] value in Task { @MainActor in self?.running[lane]?.progress = value } }
            let minSpeakers = meeting.minSpeakers
            let task = Task { try await Diarizer.diarize(samples: samples, minSpeakers: minSpeakers, onProgress: report) }
            running[lane]?.cancelAction = { task.cancel() }
            let output = try await task.value
            guard isStillRunning(job) else { return }

            let segments = try db.segments(job.meetingId)
            let transcribed = segments.map { TranscribedSegment(start: $0.start, end: $0.end, text: $0.text, lowConfidence: $0.lowConfidence) }
            var (speakers, numbering) = Diarizer.assignNumbering(output.turns, to: transcribed)
            // 短句再跟每位说话者比一次（R34、design §6.3.2）；用户改过的句子下面另外处理，不用查
            let locked = Set(segments.indices.filter { segments[$0].speakerManual })
            if let refined = try? await SpeakerRecheck.refine(transcribed, speakers: speakers, samples: samples, locked: locked) { speakers = refined }
            let source = meeting.channels == "both" ? "mix" : meeting.channels
            var voices: [Int: SpeakerVoice] = [:]
            for (raw, number) in numbering {
                if let embedding = output.voiceprints[raw] {
                    voices[number] = SpeakerVoice(embedding: embedding, seconds: output.speechSeconds[raw] ?? 0, source: source)
                }
            }
            let old = try db.speakers(job.meetingId)
            // 用户改过说话者的句子（design §24.2）不照新的结果，跟着原本那位说话者对应到的新说话者
            var assigned = speakers
            var inherited = Self.inheritNames(old: old, segments: segments.filter { !$0.speakerManual },
                                              newSpeakers: zip(segments, speakers).filter { !$0.0.speakerManual }.map(\.1))
            let mapping = Self.oldToNew(segments: segments, newSpeakers: speakers)
            var extra: [Int: Int] = [:]
            var next = (speakers.compactMap { $0 }.max() ?? 0) + 1
            for (i, segment) in segments.enumerated() where segment.speakerManual {
                guard let o = segment.speaker else { continue }
                if let n = mapping[o] {
                    assigned[i] = n
                } else {
                    if extra[o] == nil {
                        extra[o] = next
                        // 默认名称不沿用（编号变了，用新编号的默认名称）
                        if let speaker = old.first(where: { $0.idx == o }), speaker.nameSource != "default" {
                            inherited[next] = (speaker.name, speaker.nameSource, speaker.personId)
                        }
                        next += 1
                    }
                    assigned[i] = extra[o]
                }
            }
            try db.reassignSpeakers(job.meetingId, segmentSpeakers: zip(segments, assigned).compactMap { s, n in s.id.map { ($0, n) } },
                                    voices: voices, inherited: inherited)
            try db.setSpeakerCheck(job.meetingId, output.quality?.mergeRisk)
            // 沿用用户取的名字：用新的、比较干净的分群重新学声纹（自动带入的名字本来就不学）
            for (idx, item) in inherited where item.source != "voiceprint" {
                try db.learnVoiceprint(job.meetingId, idx: idx, name: item.name, source: item.source)
            }
            if AppSettings.voiceprints { try db.matchVoiceprints(job.meetingId) }
            if AppSettings.summarizerReady, try db.speakers(job.meetingId).contains(where: { $0.nameSource == "default" }) {
                try db.enqueue(job.meetingId, kind: .nameSpeakers)
            }
            let count = Set(assigned.compactMap { $0 }).count
            log.info("rediarized meeting \(job.meetingId): \(count) speakers, \(inherited.count) names kept")
            onRediarized?(job.meetingId, .success(count))
            wake()
        } catch {
            onRediarized?(job.meetingId, .failure(error))
            throw error
        }
    }

    /// 旧的说话者 → 新的说话者：旧的那位（没被用户改过的）段落分到最多的新说话者（design §24.2）
    nonisolated static func oldToNew(segments: [Segment], newSpeakers: [Int?]) -> [Int: Int] {
        var byOld: [Int: [Int: Double]] = [:]
        for (segment, new) in zip(segments, newSpeakers) where !segment.speakerManual {
            guard let new, let o = segment.speaker else { continue }
            byOld[o, default: [:]][new, default: 0] += max(0, segment.end - segment.start)
        }
        return byOld.compactMapValues { $0.max(by: { $0.value < $1.value })?.key }
    }

    /// 名字沿用（design §23.3）：新的说话者 n 的段落（依秒数）有 60% 以上原本是同一位取过名字的 o，
    /// 而且 o 原本的段落分到 n 最多，n 就沿用 o 的名字、名字来源、连到的人
    nonisolated static func inheritNames(old: [SpeakerName], segments: [Segment], newSpeakers: [Int?])
        -> [Int: (name: String, source: String, personId: Int64?)] {
        let named = Dictionary(old.filter { $0.nameSource != "default" }.map { ($0.idx, $0) }, uniquingKeysWith: { a, _ in a })
        var byNew: [Int: [Int: Double]] = [:]   // 新 → 旧 → 秒数
        var byOld: [Int: [Int: Double]] = [:]   // 旧 → 新 → 秒数
        for (segment, new) in zip(segments, newSpeakers) {
            guard let new, let oldSpeaker = segment.speaker else { continue }
            let seconds = max(0, segment.end - segment.start)
            byNew[new, default: [:]][oldSpeaker, default: 0] += seconds
            byOld[oldSpeaker, default: [:]][new, default: 0] += seconds
        }
        var result: [Int: (name: String, source: String, personId: Int64?)] = [:]
        for (new, shares) in byNew {
            let total = shares.values.reduce(0, +)
            guard total > 0, let top = shares.max(by: { $0.value < $1.value }), top.value / total >= 0.6,
                  let speaker = named[top.key],
                  byOld[top.key]?.max(by: { $0.value < $1.value })?.key == new else { continue }
            result[new] = (speaker.name, speaker.nameSource, speaker.personId)
        }
        return result
    }

    // MARK: 猜说话者（design §21.5、R19.2）

    /// 从对话内容猜还没有名字的说话者，存成建议。辅助功能：失败只记 log
    private func nameSpeakers(_ job: Job, lane: JobLane) async {
        do {
            guard let meeting = try db.meeting(job.meetingId) else { return }
            let provider = AppSettings.provider
            guard provider != .none else { return }
            let speakers = try db.speakers(job.meetingId)
            let unnamed = speakers.filter { $0.nameSource == "default" }.map(\.idx)
            let segments = try db.segments(job.meetingId)
            guard !unnamed.isEmpty, !segments.isEmpty else { return }
            running[lane]?.provider = provider
            running[lane]?.stage = String(localized: "猜说话者")
            let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.idx, $0.name) })
            let language = meeting.meetingLanguage
            let context = SpeakerNaming.Context(
                language: language, meetingDate: meeting.meetingDate, title: meeting.title, participants: meeting.participantList,
                knownPeople: try db.peopleNames(), glossary: try glossaryTerms(), unnamed: unnamed,
                speakerName: { names[$0] ?? language.defaultSpeaker($0) },
                segments: segments.map { ($0.start, $0.speaker, $0.text) })
            var suggestions = try await callLLM(lane) { onStart in
                try await SpeakerNaming.suggest(context, provider: provider, model: AppSettings.model, onStart: onStart)
            }
            guard isStillRunning(job) else { return }
            // 中文会议用简体时，原因、名字转成简体（design §47.2）
            if AppSettings.simplifiedChinese(for: language) {
                suggestions = suggestions.map { s in
                    var s = s
                    s.name = ChineseScript.toSimplified(s.name)
                    s.reason = ChineseScript.toSimplified(s.reason)
                    return s
                }
            }
            try db.saveSpeakerSuggestions(job.meetingId, suggestions)
            log.info("speaker names suggested: \(suggestions.count)")
        } catch {
            log.error("speaker naming failed: \(error.logSummary, privacy: .public)")
        }
    }

    // MARK: 逐字稿校正（design §17.4）

    /// 找出可能听错的字，存成待确认的建议。这是辅助功能：失败只记 log，不影响整理会议记录
    private func correct(_ job: Job, lane: JobLane) async {
        do {
            guard let meeting = try db.meeting(job.meetingId) else { return }
            let provider = AppSettings.provider
            guard provider != .none else { return }
            let segments = try db.segments(job.meetingId)
            guard !segments.isEmpty else { return }
            running[lane]?.provider = provider
            running[lane]?.stage = String(localized: "检查可能听错的字")
            let language = meeting.meetingLanguage
            let names = Dictionary(uniqueKeysWithValues: try db.speakers(job.meetingId).map { ($0.idx, $0.name) })
            let speakerName = { (idx: Int?) -> String? in
                idx.map { names[$0] ?? language.defaultSpeaker($0) }
            }
            let context = TranscriptCorrection.Context(
                language: language, title: meeting.title, participants: meeting.participantList,
                speakerNames: Array(Set(names.values)).sorted(), glossary: try glossaryTerms(),
                segments: segments.map { ($0.text, speakerName($0.speaker)) })
            let suggestions = try await callLLM(lane) { onStart in
                try await TranscriptCorrection.suggest(
                    context, provider: provider, model: AppSettings.model, onStart: onStart,
                    onProgress: { [weak self] value in self?.running[lane]?.progress = value })
            }
            guard isStillRunning(job) else { return }
            // 中文会议用简体时，建议和原因转成简体（原文照逐字稿，已经对过，design §47.2）
            let script = { (text: String) in AppSettings.script(text, for: language) }
            try db.saveCorrections(job.meetingId, suggestions.compactMap { s in
                segments[s.segment].id.map {
                    Correction(meetingId: job.meetingId, segmentId: $0, original: s.original, suggestion: script(s.suggestion), reason: script(s.reason))
                }
            })
        } catch {
            log.error("transcript correction failed: \(error.logSummary, privacy: .public)")
        }
    }

    // MARK: 压缩（design §6.4）

    private func compress(_ job: Job) async throws {
        guard let meeting = try db.meeting(job.meetingId), meeting.hasAudio,
              meeting.audioURL.pathExtension.lowercased() == "wav" else { return }
        let output = Paths.audioDir.appendingPathComponent("\(job.meetingId).m4a")
        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: meeting.audioURL), presetName: AVAssetExportPresetAppleM4A)
        else { throw LLMError.failed(String(localized: "无法创建压缩工作")) }
        try await export.export(to: output, as: .m4a)
        try db.setAudioFile(job.meetingId, output.lastPathComponent)
        try? FileManager.default.removeItem(at: meeting.audioURL)
        onAudioReplaced?(job.meetingId)
    }

    // MARK: 整理（design §8）

    /// 回传要不要发通知：草稿没做（正式逐字稿已经好了）、正式版取代了草稿时不发
    private func summarize(_ job: Job, lane: JobLane, answers: [ReviewAnswer]?, draft: Bool = false) async throws -> Bool {
        guard let meeting = try db.meeting(job.meetingId) else { return false }
        // 草稿（design §21.3）：正式逐字稿已经好了就不做（短的会议转录比较快）
        if try draft && !db.segments(job.meetingId).isEmpty { return false }
        let provider = AppSettings.provider
        guard provider != .none else {
            throw LLMError.notConfigured(AppSettings.needsProviderSetup
                ? String(localized: "还没设置整理工具，请到设置选择 Claude、Codex 或 API")
                : String(localized: "整理工具设置为「不整理」，请到设置改成 Claude、Codex 或 API"))
        }
        running[lane]?.provider = provider
        running[lane]?.stage = draft ? String(localized: "整理草稿") : answers == nil ? String(localized: "整理") : String(localized: "校稿")
        let segments = try db.segments(job.meetingId, kind: draft ? "live" : "final")
        guard !segments.isEmpty || !meeting.userNotes.isEmpty else { throw LLMError.failed(String(localized: "还没有逐字稿，请先完成转录")) }
        let templates = try db.templates()
        let template = templates.first { $0.id == meeting.templateId } ?? templates.first { $0.id == "general" }
        let context = NotesContext(
            meeting: meeting, segments: segments,
            speakers: Dictionary(uniqueKeysWithValues: try db.speakers(job.meetingId).map { ($0.idx, $0.name) }),
            bookmarks: try db.bookmarks(job.meetingId), glossary: try glossaryTerms(),
            template: template?.definition(for: meeting.meetingLanguage) ?? TemplateDefinition.decode("{}"),
            documents: try db.documents(job.meetingId).map(DocumentText.init),
            assistance: try db.assistance(job.meetingId)?.notesReference ?? "")
        let prompt: String
        if let answers {
            guard let notes = meeting.decodedNotes else { return false }
            prompt = NotesPrompt.revise(context, notes: notes, answers: answers)
        } else {
            prompt = NotesPrompt.summarize(context)
        }
        let system = NotesPrompt.system(meeting.meetingLanguage, documents: !context.documents.isEmpty)
        var notes = try await callLLM(lane) { onStart in
            try await LLMClient.generate(provider: provider, model: AppSettings.model, system: system, prompt: prompt, onStart: onStart)
                .outputScript(meeting.meetingLanguage)
        }
        guard isStillRunning(job) else { return false }
        // 中文会议用简体时，整理完才转（提示词照旧，design §47.2、D154）
        if AppSettings.simplifiedChinese(for: meeting.meetingLanguage) { notes = notes.simplified() }
        if draft {
            // 整理草稿的期间正式逐字稿好了、或已经有会议记录：丢掉草稿
            guard try db.segments(job.meetingId).isEmpty, try db.meeting(job.meetingId)?.notes == nil else { return false }
            try db.saveNotes(job.meetingId, notes: notes, by: provider.rawValue, reason: String(localized: "草稿"), source: .draft)
            return true
        }
        let hadDraft = try db.meeting(job.meetingId)?.notesDraft ?? 0
        let replacedEdited = try db.saveNotes(job.meetingId, notes: notes, by: provider.rawValue,
                                              reason: answers == nil ? String(localized: "刷新") : String(localized: "校稿"),
                                              source: answers == nil ? .generated : .revised)
        if replacedEdited { onEditedDraftReplaced?(job.meetingId) }
        return answers != nil || hadDraft == 0
    }
}
