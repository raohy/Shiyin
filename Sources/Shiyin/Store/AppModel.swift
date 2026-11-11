import AppKit
import Foundation
import GRDB
import Observation

/// 列表与标题列显示的状态
enum MeetingStatus: Equatable {
    case prepared
    case recording
    case queued
    case transcribing(Double?, String)
    case summarizing
    case failed(JobKind, String)
    case cancelled
    case review(Int)
    case done

    var label: String {
        switch self {
        case .prepared: return String(localized: "待录音")
        case .recording: return String(localized: "录音中")
        case .queued: return String(localized: "排队中")
        case .transcribing(_, let stage) where stage == String(localized: "等企业服务器"):
            // 在等企业服务器（R50.5）：不接「中」、不显示百分比
            return stage
        case .transcribing(let p, let stage):
            let name = stage.isEmpty || stage == String(localized: "转录") ? String(localized: "转录中") : String(localized: "\(stage)中")
            return p.map { "\(name) \(Int($0 * 100))%" } ?? name
        case .summarizing: return String(localized: "整理中")
        case .failed(let kind, _): return kind == .transcribe ? String(localized: "转录失败") : String(localized: "整理失败")
        case .cancelled: return String(localized: "已取消")
        case .review(let n): return String(localized: "待确认 \(n) 题")
        case .done: return String(localized: "完成")
        }
    }

    var isActive: Bool {
        switch self {
        case .queued, .transcribing, .summarizing, .recording: return true
        default: return false
        }
    }
}

/// 会议页的三个标签页（R44.1，design §33.1）：记录（摘要、决议、待办、未决问题、议题、自订段落，顶部一条待确认）、逐字稿（顶部可收合的我的笔记）、提问
enum DetailTab: String, CaseIterable, Identifiable {
    case summary, transcript, ask
    var id: String { rawValue }
    var label: String {
        switch self {
        case .summary: return String(localized: "记录")
        case .transcript: return String(localized: "逐字稿")
        case .ask: return String(localized: "提问")
        }
    }

    /// 4.0 以前的标签页名称（topics、review、notes）当别名：DEBUG 的 tab 命令、旧脚本。回传标签页，和要不要顺便展开待确认、我的笔记
    static func resolve(_ name: String) -> (tab: DetailTab, expandReview: Bool, expandNotes: Bool)? {
        switch name {
        case "topics": return (.summary, false, false)
        case "review": return (.summary, true, false)
        case "notes": return (.transcript, false, true)
        default: return DetailTab(rawValue: name).map { ($0, false, false) }
        }
    }
}

/// 选中中的会议的完整资料
struct MeetingDetail: Equatable {
    var meeting: Meeting
    var segments: [Segment]
    var notes: MeetingNotes?
    var versionCount: Int
    var latestJob: Job?
    var speakers: [Int: String]
    var bookmarks: [Bookmark]
    /// 逐字稿校正建议（design §17.4）
    var corrections: [Correction] = []
    /// 会议的参考文档（design §39.1）和照长度分配后每一份用了多少（§39.3，菜单显示「太长，只用前 N 页」）
    var documents: [MeetingDocument] = []
    var documentUse: [Int64: DocumentPrompt.Allocated] = [:]
    /// 逐字稿标签页用的索引，加载时算一次，不要每次画面更新都重算（design §21.12）：
    /// 每段的校正（不含已忽略的）、依开始时间排好的段落
    var correctionsBySegment: [Int64: [Correction]] = [:]
    var timelineStarts: [Double] = []
    var timelineIds: [Int64] = []
    /// 段落 id → 在 segments 里的位置（找连续的同一位说话者，design §24.3）
    var segmentIndex: [Int64: Int] = [:]
    /// 说话者名字的来源（default / manual / voiceprint / suggestion），声纹带入的显示「自动」（design §21.4）
    var speakerSources: [Int: String] = [:]
    /// AI 猜的名字（design §21.5）、声纹没把握的（§21.4、R33）：还是默认名称的说话者才有
    var speakerSuggestions: [Int: SpeakerNaming.Suggestion] = [:]
    /// 每位说话者最像的几位认识的人（R33）：「是别人」的菜单、待确认的「不是」
    var speakerCandidates: [Int: [String]] = [:]
    /// 待确认的题数：会议记录的待确认＋说话者的建议（R33.3）
    var reviewCount: Int { (notes?.reviewItems.count ?? 0) + speakerSuggestions.count }
    /// 可以复原的说话者调整（合并、改句子）的说明，没有就是 nil；显示在改名小窗口和逐字稿右键菜单（R44.4）
    var speakerUndoLabel: String? = nil
    /// 有上一版会议记录可以复原（R44.4）：记录标签页的编辑列才显示「复原上一版」
    var canUndoNotes: Bool { versionCount > 0 }
    /// 最后几分钟没人说话、没有转录（design §35.3、R48.3）：自动停止的录音，录音比转录的范围长 1 分钟以上才有
    var untranscribedMinutes: Int? = nil
    /// 待确认的题目对应到哪一条记录（R41.1，design §31.1）：加载时算一次，会议记录换了就重算（`linkReviewItems`）
    var reviewLinks: [NoteItemRef: [Int]] = [:]

    /// 这一条记录对到几题待确认
    func reviewCount(_ ref: NoteItemRef) -> Int { reviewLinks[ref]?.count ?? 0 }

    mutating func linkReviewItems() {
        reviewLinks = notes?.reviewLinks() ?? [:]
    }

    mutating func loadDocuments(_ rows: [MeetingDocument]) {
        documents = rows
        let allocated = DocumentPrompt.allocate(rows.map(DocumentText.init))
        documentUse = Dictionary(uniqueKeysWithValues: zip(rows, allocated).compactMap { row, use in row.id.map { ($0, use) } })
    }

    mutating func loadSpeakers(_ rows: [SpeakerName]) {
        speakers = Dictionary(uniqueKeysWithValues: rows.map { ($0.idx, $0.name) })
        speakerSources = Dictionary(uniqueKeysWithValues: rows.map { ($0.idx, $0.nameSource) })
        speakerSuggestions = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard row.nameSource == "default", let name = row.suggestedName else { return nil }
            return (row.idx, SpeakerNaming.Suggestion(speaker: row.idx, name: name, reason: row.suggestionReason ?? "",
                                                      time: row.suggestionTime ?? ""))
        })
    }

    mutating func buildIndexes() {
        correctionsBySegment = Dictionary(grouping: corrections.filter { $0.status != "rejected" }, by: \.segmentId)
        let ordered = segments.compactMap { s in s.id.map { (start: s.start, id: $0) } }.sorted { $0.start < $1.start }
        timelineStarts = ordered.map(\.start)
        timelineIds = ordered.map(\.id)
        segmentIndex = Dictionary(segments.enumerated().compactMap { i, s in s.id.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
    }

    /// 跟这段同一位说话者、在逐字稿里前后连在一起的段落（「这段连续的话是谁说的」，design §24.3）
    func speakerRun(around id: Int64) -> [Int64] {
        guard let i = segmentIndex[id], let speaker = segments[i].speaker else { return [id] }
        var low = i, high = i
        while low > 0, segments[low - 1].speaker == speaker { low -= 1 }
        while high + 1 < segments.count, segments[high + 1].speaker == speaker { high += 1 }
        return segments[low...high].compactMap(\.id)
    }

    /// 说话者可能分得不够的提示（design §24.5）：自我检查觉得可能把人并在一起、用户没选过人数、没按过「不用了」
    var showsSpeakerHint: Bool {
        meeting.mayHaveMergedSpeakers && meeting.minSpeakers == nil && !meeting.speakerHintDismissed
            && segments.contains { $0.kind == "final" && $0.channel == nil }
    }

    /// 播放到 time 时的段落：开始时间不晚于 time + 0.05 的最后一段（二分搜索）
    func segmentId(at time: Double) -> Int64? {
        var low = 0, high = timelineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if timelineStarts[mid] <= time + 0.05 { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? timelineIds[low - 1] : nil
    }

    /// 待确认的校正依「原文 → 建议」分组，处数多的在前；组内依逐字稿的顺序（design §21.11、R20.2）
    var correctionGroups: [[Correction]] {
        let pending = corrections.filter { $0.status == "pending" }
        let order = Dictionary(segments.enumerated().compactMap { i, s in s.id.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
        return Dictionary(grouping: pending) { "\($0.original)\u{1F}\($0.suggestion)" }.values
            .map { $0.sorted { (order[$0.segmentId] ?? 0) < (order[$1.segmentId] ?? 0) } }
            .sorted { $0.count != $1.count ? $0.count > $1.count : (order[$0[0].segmentId] ?? 0) < (order[$1[0].segmentId] ?? 0) }
    }

    func speakerName(_ idx: Int?) -> String? {
        guard let idx else { return nil }
        return speakers[idx] ?? meeting.meetingLanguage.defaultSpeaker(idx)  // l10n-skip
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let db: AppDatabase
    let runner: JobRunner
    let coach: MeetingCoach
    let models = ModelStore()
    let player = Player()
    let recorder = Recorder()
    let notifier = Notifier()
    let updater = Updater()

    var environment: EnvironmentStatus
    /// 整理工具准备好了没（design §34.1）：会议页的提示、失败横幅跟着变。只在值真的变了才设（重排整个窗口很贵，§21.12）
    private(set) var summarizerProblem: SummarizerProblem?
    @ObservationIgnored private var summarizerObservers: [NSObjectProtocol] = []
    var meetings: [MeetingRow] = []
    var trash: [MeetingRow] = []
    var showTrash = false
    var selection: Int64? {
        didSet {
            if oldValue != selection {
                reviewExpanded = false
                userNotesExpanded = false
                reloadDetail()
            }
        }
    }
    var detail: MeetingDetail?
    var meetingAssistance: MeetingAssistance?
    var showPreparationSheet = false
    var preparationMeetingId: Int64?
    /// 待确认的回答（design §31.2）：待确认标签页和记录旁的就地回答共用；换会议就换一份（`syncReviewDraft`）
    var reviewDraft: ReviewDraft?
    var tab: DetailTab = .summary
    /// 记录顶部「还有 N 题待确认」、逐字稿顶部「我的笔记」展开了没（design §33.1）：只记这次选中期间，换会议就收起
    var reviewExpanded = false
    var userNotesExpanded = false
    /// 正在读取的参考文档：会议 id → 文件名（design §39.4）
    var readingDocuments: [Int64: [String]] = [:]
    /// 已经有会议记录、之后才加入或移除文档的会议（R61.8）：记录标签页顶部提示刷新。只记在内存
    var documentsChanged: Set<Int64> = []
    var filter = ""
    /// 侧栏目前只看的文件夹；nil 是所有会议（R9.2）
    var folderFilter: String?
    /// 正在输入名称的文件夹动作：添加（要移入的会议）或改名（旧名称）
    var folderPrompt: FolderPrompt?
    enum FolderPrompt: Equatable { case create(Int64), rename(String) }
    var glossary: [GlossaryTerm] = []
    var glossarySuggestions: [GlossarySuggestion] = []
    /// 公司词汇表（R53）：设置页显示、建议的新词要排除
    var companyGlossary: [String] = CompanyGlossary.terms
    var templates: [TemplateRecord] = []

    var searchQuery = "" { didSet { runSearch() } }
    var searchResults: [SearchHit] = []
    /// 搜索结果点进来时要高亮的逐字稿段落
    var highlightSegment: Int64?

    var pendingImport: [URL] = []
    var showImportSheet = false
    var showFileImporter = false
    var showExportSheet = false
    /// 重新识别说话者的小窗口（design §23.4）和它要处理的会议
    var showRediarizeSheet = false
    var rediarizeMeetingId: Int64?
    /// 导出对话框要导出的会议：打开时记下，对话框开着时选中的会议换了也不变（design §20.9、R18.9）
    var exportMeetingId: Int64?
    var confirmDelete = false
    /// 垃圾桶里「永久删除」要确认的会议
    var confirmPurge: Int64?
    /// 确认对话框要删的会议：按下 ⌘⌫ 时就决定，不然确认前选中的会议变了（例如录音停止后跳到那场）会删到别场
    var deleteTarget: Int64?
    var queuedCount = 0
    var errorMessage: String?
    var noticeMessage: String?
    /// 第二版留下的 Python 环境、mlx 模型（R10.5）
    var legacyBytes: Int64 = 0

    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored var openWindowById: ((String) -> Void)?

    private init() {
        do {
            try Paths.ensureDirectories()
            db = try AppDatabase(path: Paths.database.path, documentsRoot: Paths.documentsDir)
        } catch {
            // 迁移在交易里进行，失败时原本的资料不会被改到（N3）；说明清楚后结束，不要直接闪退
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = String(localized: "拾音没办法打开数据库")
            let reason = (error as? DatabaseError)?.message ?? error.localizedDescription
            log.error("open database failed: \(reason, privacy: .public)")
            alert.informativeText = String(localized: "原因：\(reason)\n\n你的资料没有被改动。升级前的备份在：\(Paths.backupsDir.path)\n请把这个消息截屏给维护拾音的人。")
            alert.addButton(withTitle: String(localized: "结束拾音"))
            alert.runModal()
            exit(1)
        }
        runner = JobRunner(db: db)
        coach = MeetingCoach(db: db)
        environment = EnvironmentStatus(items: [])
        coach.canAnalyze = { [weak self] id in
            self?.recorder.isRecording == true && self?.recorder.meetingId == id && self?.recorder.isPaused == false
        }
        coach.onChange = { [weak self] id in self?.reloadAssistance(id) }
        runner.onChange = { [weak self] in self?.reload() }
        runner.onFinished = { [weak self] job, error in self?.jobFinished(job, error: error) }
        recorder.onLiveFinished = { [weak self] id, duration in self?.enqueueDraftNotes(meetingId: id, duration: duration) }
        runner.onRediarized = { [weak self] id, result in
            guard let self, self.selection == id else { return }
            switch result {
            case .success(let count):
                self.noticeMessage = String(localized: "已重新识别说话者：分出 \(count) 位。名字请再确认一下；会议记录要更新的话，请刷新会议记录。")
            case .failure(let error):
                if !(error is CancellationError) { self.errorMessage = String(localized: "重新识别说话者失败：\(error.localizedDescription)") }
            }
        }
        runner.onEditedDraftReplaced = { [weak self] id in
            guard let self, self.selection == id else { return }
            self.noticeMessage = String(localized: "正式版的会议记录好了；你改过的草稿留在版本记录里，按记录标签页「编辑」旁的「复原上一版」可以找回")
        }
        runner.onAudioReplaced = { [weak self] id in
            guard let self, self.selection == id else { return }
            // 录音压缩成 m4a 后换文件：接着原本的位置，正在播的继续播
            let (time, playing) = (self.player.currentTime, self.player.isPlaying)
            self.player.unload()
            self.reloadDetail(forceAudio: true)
            if time > 0 || playing { self.player.seek(to: time, play: playing) }
        }
        recorder.onFinished = { [weak self] result in self?.recordingFinished(result) }
        recorder.onLiveFinal = { [weak self] id, start, end, text in
            try? self?.db.appendLiveSegment(id, start: start, end: end, text: text)
        }
        recorder.onLanguageChange = { [weak self] id, language in
            guard let self else { return }
            self.perform { try self.db.setLanguage(id, language) }
        }
        notifier.onOpen = { [weak self] id in self?.reveal(id) }
    }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        notifier.activate()
        // 检测在线会议、提醒录音（design §21.7、R19.4）
        meetingDetector.isRecording = { [weak self] in self?.recorder.isRecording ?? false }
        meetingDetector.onPrompt = { [weak self] in self?.showMeetingPrompt($0) }
        notifier.onMeetingAction = { [weak self] action, bundle in self?.handleMeetingAction(action, bundle: bundle) }
        notifier.onIdleAction = { [weak self] action in
            guard let self else { return }
            if action == "stop" { self.recorder.stop() } else if action == "continue" { self.recorder.continueAfterIdle() }
        }
        meetingDetector.start()
        BuiltinTemplates.seed(db)
        // 本地 MCP 的启动档指到目前这份拾音（design §44.3）：搬家、更新后 AI 工具的设置不用动
        if AppSettings.mcpEnabled { _ = try? MCPSetup.installLauncher() }
        // claude、codex 的登录状态（design §34.1）：没登录时不自动整理
        Task { await CLILogin.refreshIfStale() }
        // 企业服务器：公司在后台加了模型、改了设置，不用重新登录（R51.5）
        Task {
            await EnterpriseServer.shared.refreshInfo()
            refreshSummarizerProblem()
        }
        refreshSummarizerProblem()
        // 设置（整理工具、模型、网址）、key、登录状态、暂停变了就重算
        for name in [UserDefaults.didChangeNotification, .summarizerStateChanged] {
            summarizerObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.refreshSummarizerProblem() }
            })
        }
        summarizerObservers.append(NotificationCenter.default.addObserver(forName: .companyGlossaryChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AppModel.shared.companyGlossary = CompanyGlossary.terms
                AppModel.shared.reload()
            }
        })
        cleanUpPreviousRun()
        purgeExpiredTrash()
        recoverRecordings()
        runner.start()
        // 语言检测模型很小（60 MB），开着自动检测就先下载好
        if AppSettings.autoDetectLanguage { models.autoStart(.languageDetection) }
        GlobalHotKey.shared.onPress = { [weak self] in self?.toggleRecording() }
        GlobalHotKey.shared.onBookmark = { [weak self] in self?.bookmarkFromHotKey() }
        recorder.onStarted = { [weak self] in
            GlobalHotKey.shared.setBookmarkEnabled(AppSettings.bookmarkHotKey)
            if let self, let id = self.recorder.meetingId { self.coach.begin(id) }
        }
        recorder.onLevelHint = { [weak self] hint in self?.levelHintAppeared(hint) }
        recorder.onMicHint = { [weak self] hint in self?.micHintAppeared(hint) }
        // 忘了停止录音（design §35、R48）：提醒一出现就送通知（人多半不在电脑前）
        recorder.onIdlePrompt = { [weak self] in
            guard let self, let id = self.recorder.meetingId else { return }
            self.notifier.idlePrompt(meetingId: id)
        }
        GlobalHotKey.shared.setEnabled(AppSettings.globalHotKey)
        updater.scheduleAutomaticChecks()
        UsageStats.shared.touch()
        UsageStats.shared.scheduleAutomaticSends()
        refreshEnvironment()
        legacyBytes = Paths.legacyItems.reduce(0) { $0 + Self.directorySize($1) }
        reload()
    }

    // MARK: 读取

    func reload() {
        #if DEBUG
        DebugMetrics.bump("reloadList")
        #endif
        do {
            meetings = try db.meetingRows()
            trash = try db.meetingRows(trash: true)
            glossary = try db.glossary()
            // 公司已经有的词不再建议（R53.3）
            glossarySuggestions = try db.glossarySuggestions().filter { !CompanyGlossary.contains($0.term) }
            templates = try db.templates()
            queuedCount = try db.activeJobs().filter { $0.status == .queued }.count
        } catch {
            errorMessage = error.localizedDescription
        }
        if let selection, !meetings.contains(where: { $0.id == selection }), !trash.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
        // 文件夹里最后一场会议移走后，文件夹就不存在了，回到所有会议
        if let folderFilter, !meetings.contains(where: { $0.meeting.folder == folderFilter }) { self.folderFilter = nil }
        reloadDetail()
    }

    /// 这场会议是用 macOS 内置识别（模型下载好之前）或 Breeze 转的，现在目前引擎的模型下载好了，可以重新转录（design §21.17、§32.6）
    func canUpgradeTranscript(_ meeting: Meeting) -> Bool {
        guard !AppSettings.useSystemTranscriber, !AppSettings.usesEnterpriseTranscription, meeting.hasAudio, meeting.deletedAt == nil,
              models.isInstalled(transcriptionFor: meeting.meetingLanguage) else { return false }
        let older = ModelStore.transcription(for: meeting.meetingLanguage) == .qwen ? ["system", "breeze"] : ["system"]
        return older.contains(meeting.transcribedWith)
    }

    // MARK: 更新（R10.6）

    /// 从菜单检查：结果一定要让用户看到
    func checkForUpdatesFromMenu() async {
        await updater.check(userInitiated: true)
        switch updater.state {
        case .upToDate: noticeMessage = String(localized: "已是最新版本（\(Updater.currentVersion)）")
        case .failed(let reason): errorMessage = String(localized: "检查更新失败：\(reason)")
        case .available: openMainWindow?()
        default: break
        }
    }

    // MARK: 文件夹（R9.2）

    /// 现有的文件夹和各自的场数（不含垃圾桶），依名称排序
    var folders: [(name: String, count: Int)] {
        let counts = Dictionary(grouping: meetings.filter { !$0.meeting.folder.isEmpty }, by: \.meeting.folder).mapValues(\.count)
        return counts.map { (name: $0.key, count: $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 新会议要放进的文件夹：正在看某个文件夹时就放那里
    var currentFolder: String { showTrash ? "" : folderFilter ?? "" }

    func moveToFolder(_ id: Int64, folder: String) {
        let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = try? db.meeting(id)?.folder, current == name {
            noticeMessage = name.isEmpty ? String(localized: "这场会议没有在任何文件夹里") : String(localized: "这场会议已经在「\(name)」")
            return
        }
        perform { try db.setFolder([id], folder: name) }
        noticeMessage = name.isEmpty ? String(localized: "已移出文件夹") : String(localized: "已移到「\(name)」")
    }

    func renameFolder(_ old: String, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != old else { return }
        // 先切换筛选，reload 时才不会因为旧名称不存在而跳回所有会议
        if folderFilter == old { folderFilter = name }
        perform { try db.renameFolder(old, to: name) }
    }

    /// 删除文件夹：会议留着，移回「不在文件夹」
    func deleteFolder(_ name: String) {
        perform { try db.renameFolder(name, to: "") }
        if folderFilter == name { folderFilter = nil }
    }

    func reloadDetail(forceAudio: Bool = false) {
        #if DEBUG
        DebugMetrics.bump("reloadDetail")
        let started = Date()
        defer { DebugMetrics.time("reloadDetail", since: started) }
        #endif
        guard let id = selection, let meeting = try? db.meeting(id) else {
            detail = nil
            meetingAssistance = nil
            syncReviewDraft()
            player.unload()
            return
        }
        let previous = detail?.meeting
        reloadAssistance(id)
        let speakerRows = (try? db.speakers(id)) ?? []
        var loaded = MeetingDetail(
            meeting: meeting, segments: (try? db.segments(id)) ?? [], notes: meeting.decodedNotes,
            versionCount: (try? db.versionCount(id)) ?? 0, latestJob: try? db.latestJob(id),
            speakers: Dictionary(uniqueKeysWithValues: speakerRows.map { ($0.idx, $0.name) }),
            bookmarks: (try? db.bookmarks(id)) ?? [], corrections: (try? db.corrections(id)) ?? [])
        loaded.loadSpeakers(speakerRows)
        loaded.loadDocuments((try? db.documents(id)) ?? [])
        loaded.speakerCandidates = (try? db.voiceprintCandidates(id)) ?? [:]
        loaded.speakerUndoLabel = try? db.speakerUndoLabel(id)
        if let until = try? db.transcribedUntil(id), let duration = meeting.durationSeconds, Double(duration) - until >= 60 {
            loaded.untranscribedMinutes = Int(((Double(duration) - until) / 60).rounded())
        }
        loaded.buildIndexes()
        loaded.linkReviewItems()
        detail = loaded
        syncReviewDraft()
        if forceAudio || previous?.id != meeting.id || previous?.audioFile != meeting.audioFile {
            if meeting.hasAudio { player.load(meeting.audioURL) } else { player.unload() }
        }
    }

    var filteredMeetings: [MeetingRow] {
        var source = showTrash ? trash : meetings
        if !showTrash, let folderFilter { source = source.filter { $0.meeting.folder == folderFilter } }
        let keyword = filter.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return source }
        return source.filter { $0.meeting.displayTitle.localizedCaseInsensitiveContains(keyword) }
    }

    func status(_ row: MeetingRow) -> MeetingStatus {
        if row.meeting.source == "prepared" { return .prepared }
        return status(meetingId: row.id, latestJob: row.latestJob, reviewCount: row.reviewCount)
    }

    func status(meetingId: Int64, latestJob: Job?, reviewCount: Int) -> MeetingStatus {
        if recorder.meetingId == meetingId { return .recording }
        if let running = runner.runningJob(for: meetingId) {
            return running.job.kind == .transcribe ? .transcribing(running.progress, running.stage) : .summarizing
        }
        if let job = latestJob {
            switch job.status {
            case .queued, .running: return .queued
            case .failed: return .failed(job.kind, job.error ?? "")
            case .cancelled where job.kind == .transcribe: return .cancelled
            default: break
            }
        }
        return reviewCount > 0 ? .review(reviewCount) : .done
    }

    var detailStatus: MeetingStatus? {
        guard let detail else { return nil }
        if detail.meeting.source == "prepared" { return .prepared }
        return status(meetingId: detail.meeting.id!, latestJob: detail.latestJob, reviewCount: detail.reviewCount)
    }

    /// 用全域快捷键标记重点后，菜单列图标换成星号 1 秒（design §21.10）
    var bookmarkFlash = false

    /// ⌃⌥⌘B：在其他 app 里标记重点，有音效和菜单列图标的反馈
    func bookmarkFromHotKey() {
        guard recorder.isRecording, let id = recorder.meetingId else { return }
        addBookmark(at: recorder.elapsed, meetingId: id)
        NSSound(named: "Tink")?.play()
        bookmarkFlash = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            bookmarkFlash = false
        }
    }

    var menuBarSymbol: String {
        if bookmarkFlash { return "star.circle.fill" }
        // 收音提醒还在时换成警示的样子（R42.2），按「知道了」或提示消失就换回来
        if recorder.isRecording {
            return recorder.levelHint != nil || recorder.micHint != nil || recorder.idlePrompt ? "mic.badge.exclamationmark" : "record.circle.fill"
        }
        if runner.isBusy || queuedCount > 0 { return "waveform.circle.fill" }
        return "waveform"
    }

    /// 收音提醒第一次出现（R42.1、design §31.5）：拾音不是最前面的 app、或主窗口没开时送通知，点了打开录音中的会议。
    /// 每场每种最多一次由 Recorder 管；拾音在前面时只有录音画面和菜单列的提示
    private func levelHintAppeared(_ hint: Recorder.LevelHint) {
        guard let id = recorder.meetingId, !mainWindowInFront else { return }
        notifier.levelHint(hint.text, kind: hint.rawValue, meetingId: id)
    }

    /// 用蓝牙耳机的麦克风录现场会议（design §38.4、R58.3）：通知的规则同收音提醒
    private func micHintAppeared(_ hint: Recorder.MicHint) {
        guard let id = recorder.meetingId, !mainWindowInFront else { return }
        notifier.levelHint(hint.text, kind: "bluetooth", meetingId: id)
    }

    private var mainWindowInFront: Bool {
        NSApp.isActive && NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
    }

    /// 换麦克风（design §38.2、§38.3、R58）：录音中就接着用新的这支录；没在录音时只改设置。提示让人知道选到了
    func switchMicrophone(_ uid: String) {
        let monitor = MicrophoneMonitor.shared
        recorder.switchMicrophone(uid: uid)
        let name = monitor.resolve(uid)?.name ?? ""
        if recorder.isRecording {
            noticeMessage = uid.isEmpty ? String(localized: "已改用系统默认的麦克风（\(name)），之后的录音也用系统默认")
                : String(localized: "已改用 \(name)，之后的录音也用这支")
        } else {
            noticeMessage = uid.isEmpty ? String(localized: "之后的录音用系统默认的麦克风（\(name)）")
                : String(localized: "之后的录音用 \(name)")
        }
    }

    func refreshEnvironment() {
        models.refresh()
        environment = EnvironmentStatus.check(models: models)
    }

    // MARK: 导入（R3）

    func requestImport(_ urls: [URL]) {
        // 文档加到选中中的会议（R61.1、R61.3）；其他照旧导入
        let documents = urls.filter(DocumentReader.isDroppedDocument)
        if !documents.isEmpty { addDroppedDocuments(documents) }
        let urls = urls.filter { !DocumentReader.isDroppedDocument($0) }
        guard !urls.isEmpty else { return }
        let packages = urls.filter { $0.pathExtension.lowercased() == "shiyin" }
        let transcripts = urls.filter { ["srt", "vtt", "txt"].contains($0.pathExtension.lowercased()) }
        let markdown = urls.filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
        packages.forEach(importPackage)
        transcripts.forEach { importTranscript($0) }
        if !markdown.isEmpty { importMarkdownNotes(markdown) }
        let media = urls.filter(Self.isMedia)
        guard !media.isEmpty else {
            if packages.isEmpty && transcripts.isEmpty && markdown.isEmpty { errorMessage = String(localized: "只能导入录音、视频、逐字稿（srt、vtt、txt）、Markdown 或 .shiyin 档") }
            return
        }
        pendingImport = media
        showImportSheet = true
    }

    func confirmImport(_ options: ImportOptions) {
        let urls = pendingImport
        pendingImport = []
        showImportSheet = false
        importFiles(urls, options: urls.count == 1 ? options : ImportOptions(participants: options.participants, templateId: options.templateId,
                                                                              language: options.language))
    }

    /// 从 Dock 或 Finder 导入：不跳对话框，直接用默认值
    func importDirectly(_ urls: [URL]) {
        let other = urls.filter { !Self.isMedia($0) }
        if !other.isEmpty { requestImport(other) }
        importFiles(urls.filter(Self.isMedia), options: ImportOptions())
        openMainWindow?()
    }

    /// 正在导入的文件数，侧边栏下方显示（design §21.13、R20.4）
    var importingCount = 0

    /// 复制文件在背景做，大文件（或从外接硬盘复制）时不卡住画面（design §21.13、R20.4）
    private func importFiles(_ urls: [URL], options: ImportOptions) {
        guard !urls.isEmpty else { return }
        var options = options
        if options.folder.isEmpty { options.folder = currentFolder }
        let db = db
        importingCount += urls.count
        Task {
            var last: Meeting?
            var failures: [String] = []
            for url in urls {
                do {
                    last = try await Task.detached(priority: .userInitiated) { [options] in
                        try Importer.importFile(url, options: options, db: db)
                    }.value
                    runner.wake()
                    reload()
                } catch { failures.append(error.localizedDescription) }
                importingCount -= 1
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
            if let last { showTrash = false; selection = last.id }
        }
    }

    static func isMedia(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else {
            return ["m4a", "mp3", "wav", "aac", "flac", "mp4", "mov", "caf", "aiff", "aif", "m4v"].contains(url.pathExtension.lowercased())
        }
        return Importer.contentTypes.contains { type.conforms(to: $0) }
    }

    // MARK: 录音（R1、R2）

    func toggleRecording() {
        if recorder.isRecording { recorder.stop() } else { startRecording() }
    }

    func startRecording() {
        guard !recorder.isRecording else { return }
        MeetingPromptPanel.shared.close()
        #if DEBUG
        // 启动参数 -debugRecordFile <音档>：开始录音改用模拟录音，验证时不要真的用用户的麦克风录（design §21.7）
        if let file = UserDefaults.standard.string(forKey: "debugRecordFile") {
            startSimulatedRecording(file: URL(fileURLWithPath: file), speed: 1, both: false)
            return
        }
        #endif
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let now = Date()
        do {
            let meeting: Meeting
            if var prepared = try selectedPreparedMeeting() {
                prepared.source = "recording"
                prepared.channels = AppSettings.recordSource
                prepared.meetingDate = DateText.string(now)
                try db.updateMeeting(prepared)
                meeting = prepared
            } else {
                meeting = try db.insertMeeting(Meeting(
                    meetingDate: DateText.string(now), sourceFilename: String(localized: "录音 \(formatter.string(from: now))"),
                    templateId: AppSettings.defaultTemplate, source: "recording", channels: AppSettings.recordSource,
                    folder: currentFolder, language: AppSettings.defaultMeetingLanguage.rawValue),
                    audioExtension: nil)
            }
            recorder.start(meetingId: meeting.id!, language: meeting.meetingLanguage)
            reload()
            showTrash = false
            selection = meeting.id
            tab = .transcript
        } catch {
            errorMessage = String(localized: "没办法开始录音：\(error.localizedDescription)")
        }
    }

    #if DEBUG
    /// 只在 DEBUG：用音频档模拟录音（shiyinctl record-sim）
    func startSimulatedRecording(file: URL, speed: Double, both: Bool) {
        guard !recorder.isRecording else { return }
        let meeting: Meeting
        do {
            if var prepared = try selectedPreparedMeeting() {
                prepared.source = "recording"
                prepared.channels = both ? "both" : "mic"
                try db.updateMeeting(prepared)
                meeting = prepared
            } else {
                meeting = try db.insertMeeting(Meeting(
                    meetingDate: DateText.string(Date()), sourceFilename: String(localized: "模拟录音"), source: "recording",
                    channels: both ? "both" : "mic", folder: currentFolder, language: AppSettings.defaultMeetingLanguage.rawValue),
                    audioExtension: nil)
            }
        } catch { errorMessage = error.localizedDescription; return }
        recorder.startSimulated(meetingId: meeting.id!, file: file, speed: speed, both: both, language: meeting.meetingLanguage)
        reload()
        selection = meeting.id
    }
    #endif

    /// 录音结束：把录音档接到会议上并排转录（R2.5）
    private func recordingFinished(_ result: Recorder.Result) {
        coach.stop()
        MeetingPromptPanel.shared.close()   // 还开着的「要停止录音吗？」不用了
        GlobalHotKey.shared.setBookmarkEnabled(false)   // 不录音时不占用 ⌃⌥⌘B
        do {
            if let error = result.error {
                errorMessage = error
                UsageStats.shared.failed(.recording)
            }
            guard var meeting = try db.meeting(result.meetingId) else { return }
            // 只有文件本身确实几乎是空的（不到 0.5 秒的音频）才当作没录到东西；
            // 不能只看 duration，万一计算出错会把整场录音删掉
            let bytes = (result.file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }) ?? 0
            guard let file = result.file, bytes > 44 + Int(CaptureFormat.sampleRate) else {
                if let file = result.file { try? FileManager.default.removeItem(at: file) }
                try preservePreparationOrDelete(result.meetingId)
                reload()
                return
            }
            let destination = Paths.audioDir.appendingPathComponent("\(result.meetingId).wav")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: file, to: destination)
            let original = meeting
            do {
                meeting.audioFile = destination.lastPathComponent
                if result.duration > 0 { meeting.durationSeconds = Int(result.duration.rounded()) }
                try db.updateMeeting(meeting)
                // 没人说话太久而自动停止：只转录到最后说话后 15 秒（design §35.3、R48.3）
                let until = result.idleSince.map { $0 + 15 }.flatMap { $0 < result.duration ? $0 : nil }
                let payload = until.flatMap { try? JSONEncoder().encode(TranscribePayload(until: $0)) }.map { String(decoding: $0, as: UTF8.self) }
                try db.enqueue(result.meetingId, kind: .transcribe, payload: payload)
                if result.idleSince != nil { notifier.idleStopped(meetingId: result.meetingId, title: meeting.displayTitle) }
                UsageStats.shared.recorded(seconds: result.duration)
            } catch {
                // 数据库写不进去（磁盘满时常一起发生）：搬回 recording/，下次打开由复原流程接回（design §20.3）。
                // 会议已经改到一半的话改回去，不要指向搬走的文件
                try? FileManager.default.moveItem(at: destination, to: file)
                try? db.updateMeeting(original)
                throw error
            }
            runner.wake()
            reload()
            selection = result.meetingId
        } catch {
            errorMessage = String(localized: "录音存档失败：\(error.localizedDescription)（文件还在 \(result.file?.path ?? "")）")
        }
    }

    /// 草稿记录（design §21.3、R19.1）：实时识别收尾后，录音够长、实时逐字稿够多、会自动整理时，
    /// 转录的同时先用实时逐字稿整理一份草稿
    private func enqueueDraftNotes(meetingId: Int64, duration: Double) {
        guard duration >= Self.draftMinimumSeconds, AppSettings.autoSummarize, AppSettings.summarizerReady,
              let meeting = try? db.meeting(meetingId), meeting.hasAudio, meeting.notes == nil,
              let live = try? db.segments(meetingId, kind: "live"),
              live.reduce(0, { $0 + $1.text.count }) >= 100 else { return }
        let payload = String(decoding: (try? JSONEncoder().encode(SummarizePayload(draft: true))) ?? Data(), as: UTF8.self)
        do {
            try db.enqueue(meetingId, kind: .summarize, payload: payload)
            runner.wake()
        } catch { log.error("enqueue draft notes failed: \(error.localizedDescription)") }
    }

    /// 录音太短就不整理草稿：转录很快，等正式版就好
    static var draftMinimumSeconds: Double {
        #if DEBUG
        // 启动参数 -debugDraftMinimumSeconds 10：验证时不用真的录 3 分钟
        if UserDefaults.standard.object(forKey: "debugDraftMinimumSeconds") != nil {
            return UserDefaults.standard.double(forKey: "debugDraftMinimumSeconds")
        }
        #endif
        return 180
    }

    /// 启动时处理上次没正常结束的录音（R1.5）
    private func recoverRecordings() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.recordingDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "wav" {
            do {
                try WAVRepair.repair(file)
                // 文件名是 <会议id>-<uuid>.wav；找不到会议就建一场新的
                let id = Int64(file.deletingPathExtension().lastPathComponent.split(separator: "-").first ?? "")
                if let id, var meeting = try db.meeting(id) {
                    let destination = Paths.audioDir.appendingPathComponent("\(id).wav")
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: file, to: destination)
                    let original = meeting
                    do {
                        meeting.audioFile = destination.lastPathComponent
                        if meeting.title.isEmpty { meeting.title = String(localized: "复原的录音") }
                        try db.updateMeeting(meeting)
                        try db.enqueue(id, kind: .transcribe)
                    } catch {
                        // 搬回 recording/、会议改回去，下次打开再试（design §20.6）
                        try? FileManager.default.moveItem(at: destination, to: file)
                        try? db.updateMeeting(original)
                        throw error
                    }
                } else {
                    try Importer.importFile(file, options: ImportOptions(title: String(localized: "复原的录音"), sourceName: String(localized: "复原的录音.wav")),
                                            db: db, move: true)
                }
                noticeMessage = String(localized: "找到上次没有正常结束的录音，已经复原并开始转录。")
            } catch {
                log.error("recover recording failed: \(error.localizedDescription)")
            }
        }
        // 录音中途当掉、连录音档都没有的空会议（design §20.6）。直接查数据库（这时 meetings 还没加载）；
        // recording/ 里还有录音档的会议是这次没复原成功的，留着下次再试
        let remaining = Set(((try? FileManager.default.contentsOfDirectory(at: Paths.recordingDir, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { Int64($0.deletingPathExtension().lastPathComponent.split(separator: "-").first ?? "") })
        for id in (try? db.emptyRecordingMeetings()) ?? [] where !remaining.contains(id) && recorder.meetingId != id {
            try? preservePreparationOrDelete(id)
        }
    }

    private func cleanUpPreviousRun() {
        if let leftovers = try? FileManager.default.contentsOfDirectory(at: Paths.tmpDir, includingPropertiesForKeys: nil) {
            leftovers.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    // MARK: 会议操作

    func reveal(_ id: Int64) {
        reload()
        showTrash = trash.contains { $0.id == id }
        selection = id
        openMainWindow?()
    }

    /// 会议链接 shiyin://open?meeting=…&t=…（design §44.5）：有时间点时切到逐字稿、从那里开始，没有时看记录
    func openMeetingLink(_ id: Int64, seconds: Double?, activate: Bool = true) {
        if activate { NSApp.activate() }
        guard (try? db.meeting(id)) != nil else {
            openMainWindow?()
            noticeMessage = String(localized: "找不到这场会议，可能已经删掉了")
            return
        }
        reveal(id)
        guard let seconds else {
            tab = .summary
            return
        }
        tab = .transcript
        player.seek(to: seconds, play: false)
        if let segment = detail?.segmentId(at: seconds) { flashSegment(segment) }
    }

    func updateInfo(title: String, date: String, participants: String) {
        guard let id = selection else { return }
        perform { try db.updateInfo(id, title: title, date: date, participants: participants) }
    }

    /// 改会议语言（design §16.3）：之后的转录、整理、导出都用新的语言，已经有的逐字稿和记录不会自动重做
    func setMeetingLanguage(_ language: MeetingLanguage) {
        guard let meeting = detail?.meeting, let id = meeting.id, meeting.meetingLanguage != language else { return }
        if recorder.isRecording && recorder.meetingId == id {
            // 录音中：实时逐字稿也要换语言（跟自动检测换语言同一条路，会一起更新数据库）
            recorder.switchLanguage(to: language)
            noticeMessage = String(localized: "会议语言改成 \(language.name)，实时逐字稿也跟着换了")
            return
        }
        perform { try db.setLanguage(id, language) }
        noticeMessage = String(localized: "会议语言改成 \(language.name)，要重新转录或整理的话，从「更多 → 重新处理」选")
    }

    /// 录音中选「大约几个人」（design §26.2）：录完转录时用
    func setMinSpeakers(_ count: Int?) {
        guard let id = selection else { return }
        perform(.detail([.meeting])) { try db.setMinSpeakers(id, count) }
    }

    func setTemplate(_ templateId: String) {
        guard let id = detail?.meeting.id else { return }
        perform { try db.setTemplate(id, templateId: templateId) }
    }

    /// 「会议 → 移到垃圾桶…」：先记住是哪一场，再问要不要删
    func requestDelete() {
        guard let id = selection else { return }
        deleteTarget = id
        confirmDelete = true
    }

    /// 移到垃圾桶（R9.3）
    func moveToTrash(_ id: Int64) {
        if recorder.isRecording && recorder.meetingId == id {
            errorMessage = String(localized: "这场会议还在录音，请先停止录音再移到垃圾桶")
            return
        }
        // 已经在垃圾桶里就不再处理，不然 30 天的期限会重新计算
        if (try? db.meeting(id))?.deletedAt != nil { return }
        runner.cancel(meetingId: id)
        perform { try db.setTrashed(id, true) }
        noticeMessage = String(localized: "已移到垃圾桶，30 天内都可以还原")
    }

    func restore(_ id: Int64) {
        perform { try db.setTrashed(id, false) }
        showTrash = false
        selection = id
    }

    /// 永久删除（垃圾桶里的「立即删除」）
    func deletePermanently(_ id: Int64) {
        guard let meeting = try? db.meeting(id), !(recorder.isRecording && recorder.meetingId == id) else { return }
        runner.cancel(meetingId: id)
        if selection == id { player.unload() }
        perform {
            try db.deleteMeeting(id)
            if meeting.hasAudio { try? FileManager.default.removeItem(at: meeting.audioURL) }
        }
    }

    private func purgeExpiredTrash() {
        for meeting in (try? db.expiredTrash(olderThan: 30)) ?? [] {
            try? db.deleteMeeting(meeting.id!)
            if meeting.hasAudio { try? FileManager.default.removeItem(at: meeting.audioURL) }
        }
    }

    func cancelJobs() {
        guard let id = selection else { return }
        runner.cancel(meetingId: id)
    }

    func retry() {
        guard let id = selection, let job = detail?.latestJob, job.status == .failed || job.status == .cancelled else { return }
        // 整理工具还没准备好时重试也一样会失败（R46.2）：说原因
        if job.kind.usesSummarizer, let problem = AppSettings.summarizerProblem { errorMessage = problem.message; return }
        perform { try db.enqueue(id, kind: job.kind, payload: job.payload) }
        runner.wake()
    }

    /// 重新转录、刷新、检查听错的字、复原上一版之前再挡一次：工具列和菜单的禁用状态可能没有更新，
    /// 不挡的话会在处理中重复排工作（多花整理工具的额度），或替垃圾桶里的会议跑
    private func readyForAction(_ id: Int64) -> Bool {
        if detail?.meeting.deletedAt != nil {
            noticeMessage = String(localized: "垃圾桶里的会议要先还原才能操作")
            return false
        }
        if recorder.isRecording && recorder.meetingId == id {
            noticeMessage = String(localized: "这场会议还在录音")
            return false
        }
        if detailStatus?.isActive == true {
            noticeMessage = String(localized: "这场会议还在处理中，完成后再试一次")
            return false
        }
        return true
    }

    func retranscribe() {
        guard let id = selection, readyForAction(id) else { return }
        guard detail?.meeting.hasAudio == true else {
            noticeMessage = String(localized: "这场会议没有录音，没办法重新转录")
            return
        }
        perform { try db.enqueue(id, kind: .transcribe) }
        runner.wake()
    }

    /// 「更多 → 重新识别说话者…」（design §23.4）：按下时检查能不能做（R22.4），可以才打开选人数的窗口
    func requestRediarize() {
        guard let id = selection, readyForAction(id) else { return }
        if let problem = rediarizeProblem(id) {
            noticeMessage = problem
            return
        }
        rediarizeMeetingId = id
        showRediarizeSheet = true
    }

    private func rediarizeProblem(_ id: Int64) -> String? {
        guard let detail, detail.meeting.id == id else { return nil }
        if !detail.meeting.hasAudio { return String(localized: "这场会议没有录音，没办法重新识别说话者") }
        if !detail.segments.contains(where: { $0.kind == "final" }) { return String(localized: "还没有正式逐字稿，转录完成后再试一次") }
        if detail.segments.contains(where: { $0.channel != nil }) { return String(localized: "这场会议是分声道转录的，请用「重新转录」") }
        if (try? db.hasActiveJob(id, kind: .rediarize)) == true { return String(localized: "已经在重新识别说话者了") }
        return nil
    }

    /// 选人数的窗口按「开始」（DEBUG 的 rediarize 也用这个）：记住人数（R22.3），排重新识别的工作
    func rediarize(meetingId: Int64, minSpeakers: Int?) {
        perform { try db.setMinSpeakers(meetingId, minSpeakers); try db.enqueue(meetingId, kind: .rediarize) }
        runner.wake()
    }

    // MARK: 说话者的修正（design §24、R23）

    /// 转录或重新识别说话者时不能改：完成时会整份写回段落的说话者
    private func speakerEditProblem(_ id: Int64) -> String? {
        if detail?.meeting.deletedAt != nil { return String(localized: "垃圾桶里的会议要先还原才能操作") }
        if detailStatus?.isActive == true || (try? db.hasActiveJob(id, kind: .rediarize)) == true {
            return String(localized: "正在处理这场会议，完成后才能改说话者")
        }
        return nil
    }

    /// 「合并到…」（R23.1）：from 说的话全部算 into 的；会议记录里的名字跟着换
    func mergeSpeaker(_ from: Int, into: Int) {
        guard let id = selection else { return }
        if let problem = speakerEditProblem(id) {
            noticeMessage = problem
            return
        }
        guard let fromName = detail?.speakerName(from), let intoName = detail?.speakerName(into) else { return }
        let source = detail?.speakerSources[into]
        perform(.detail([.speakers, .segments, .meeting])) {
            guard try db.mergeSpeakers(id, from: from, into: into,
                                       label: String(localized: "把「\(fromName)」合并到「\(intoName)」")) != nil else { return }
            // 用户取的名字：用合并后的声纹重新学（自动带入的名字不学，design §21.4）
            if AppSettings.voiceprints, source == "manual" || source == "suggestion" {
                try db.learnVoiceprint(id, idx: into, name: intoName, source: source ?? "manual")
            }
            noticeMessage = String(localized: "已把「\(fromName)」合并到「\(intoName)」。要复原的话，点说话者的名字选「复原」。")
        }
    }

    /// 「这句是谁说的」（R23.2）：to 是 nil 时添加一位说话者
    func reassignSegments(_ ids: [Int64], to idx: Int?) {
        guard let id = selection, !ids.isEmpty else { return }
        if let problem = speakerEditProblem(id) {
            noticeMessage = problem
            return
        }
        let target = idx.flatMap { detail?.speakerName($0) } ?? String(localized: "新的说话者")
        let label = ids.count == 1 ? String(localized: "把一句改成「\(target)」说的")
                                   : String(localized: "把 \(ids.count) 句改成「\(target)」说的")
        perform(.detail([.speakers, .segments])) {
            try db.reassignSegments(id, ids: ids, to: idx, label: label)
        }
    }

    /// 「复原说话者的调整」（改名小窗口、逐字稿右键菜单）：只复原最近一次合并或改句子
    func undoSpeakerEdit() {
        guard let id = selection else { return }
        if let problem = speakerEditProblem(id) {
            noticeMessage = problem
            return
        }
        guard let label = try? db.speakerUndoLabel(id) else {
            noticeMessage = String(localized: "没有可以复原的说话者调整（改名、重新识别说话者之后就不能复原之前的调整）")
            return
        }
        perform(.detail([.speakers, .segments, .meeting])) {
            if try db.undoSpeakerEdit(id) { noticeMessage = String(localized: "已复原：\(label)") }
        }
    }

    /// 说话者可能分得不够的提示（design §24.5）
    func dismissSpeakerHint() {
        guard let id = selection else { return }
        perform(.detail([.meeting])) { try db.dismissSpeakerHint(id) }
    }

    func resummarize() {
        guard let id = selection, readyForAction(id) else { return }
        if let detail, detail.segments.isEmpty && detail.meeting.userNotes.isEmpty {
            noticeMessage = String(localized: "还没有逐字稿或笔记可以整理")
            return
        }
        guard AppSettings.provider != .none else {
            errorMessage = AppSettings.needsProviderSetup
                ? String(localized: "还没设置整理工具，请先到设置选择 Claude、Codex 或 API")
                : String(localized: "整理工具设置为「不整理」，请先到设置改成 Claude、Codex 或 API")
            return
        }
        // 没登录、没有 key…：不排，说原因（R45.4、design §34.2）
        if let problem = AppSettings.summarizerProblem { errorMessage = problem.message; return }
        documentsChanged.remove(id)
        perform { try db.enqueue(id, kind: .summarize) }
        runner.wake()
    }

    func undoNotes() {
        guard let id = selection, readyForAction(id) else { return }
        perform {
            if try !db.undoNotes(id) { noticeMessage = String(localized: "没有上一版可以复原") }
        }
    }

    /// 手动编辑会议记录（R6.6）
    /// 编辑器按「完成」或关掉时存档。编辑期间会议记录被别的工作改过的话提醒一下：旧的那一版还在版本记录里
    func finishNotesEdit(_ draft: MeetingNotes, base: MeetingNotes?, meetingId: Int64, automatically: Bool = false) {
        guard draft != base else { return }
        if let base, let current = try? db.meeting(meetingId)?.decodedNotes, current != base {
            noticeMessage = String(localized: "编辑期间会议记录有更新，已用你改的版本存档；按「编辑」旁的「复原上一版」可以找回更新的内容")
        } else if automatically {
            noticeMessage = String(localized: "已保存刚才编辑的会议记录")
        }
        saveEditedNotes(draft, meetingId: meetingId)
    }

    /// meetingId 要明确给：编辑器关掉时（切到别场会议、录音停止后自动跳到那场），selection 可能已经是别场
    func saveEditedNotes(_ notes: MeetingNotes, meetingId: Int64) {
        guard let current = try? db.meeting(meetingId)?.decodedNotes, notes != current else { return }
        perform { try db.saveNotes(meetingId, notes: notes, by: nil, reason: String(localized: "手动编辑")) }
    }

    /// 回传是否送出成功；失败时画面上的回答要留着
    @discardableResult
    func submitReview(answers: [Int: String], dismissed: Set<Int>) -> Bool {
        guard let id = selection, let detail, let notes = detail.notes, readyForAction(id) else { return false }
        let language = detail.meeting.meetingLanguage
        // 回答分三类（design §31.3）：确认（是非题回答「是」、没填答案）和略过直接从记录移除，不送整理工具（R41.4、D103）；
        // 只有要改内容的回答（打字的、「不是」）才送整理工具依回答修正
        var confirmed: Set<Int> = []
        var dismissed = dismissed
        var modified: [(Int, ReviewAnswer)] = []
        for (index, text) in answers {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !dismissed.contains(index), notes.reviewItems.indices.contains(index) else { continue }
            let item = notes.reviewItems[index]
            if let choice = YesNoAnswer(trimmed, language: language), choice.isYes == true {
                confirmed.insert(index)
            } else if let choice = YesNoAnswer(trimmed, language: language), choice.isYes == false, choice.correction.isEmpty {
                dismissed.insert(index)   // 「不是」没填答案：有问题但不知道对的是什么，跟略过一样（R41.4）
            } else {
                modified.append((index, ReviewAnswer(time: item.time, question: item.question, answer: trimmed)))
            }
        }
        let answered = modified.sorted { $0.0 < $1.0 }.map(\.1)
        if !answered.isEmpty && AppSettings.provider == .none {
            errorMessage = AppSettings.needsProviderSetup
                ? String(localized: "还没设置整理工具，没办法依回答修正。请先到设置选择 Claude、Codex 或 API")
                : String(localized: "整理工具设置为「不整理」，没办法依回答修正。请先到设置改成 Claude、Codex 或 API")
            return false
        }
        if !answered.isEmpty, let problem = AppSettings.summarizerProblem {
            errorMessage = problem.message
            return false
        }
        perform {
            if !confirmed.isEmpty || !dismissed.isEmpty { try db.resolveReviewItems(id, confirmed: confirmed, dismissed: dismissed) }
            if !answered.isEmpty {
                let payload = String(decoding: try JSONEncoder().encode(RevisePayload(answers: answered)), as: UTF8.self)
                try db.enqueue(id, kind: .revise, payload: payload)
            }
        }
        runner.wake()
        // 匿名统计（R41.7）：只记题数
        UsageStats.shared.reviewed(answered: answered.count, confirmed: confirmed.count,
                                   skipped: dismissed.filter { notes.reviewItems.indices.contains($0) }.count)
        return true
    }

    func updateSegment(_ segmentId: Int64, text: String) {
        perform(.segments([segmentId])) { try db.updateSegmentText(segmentId, text: text) }
    }

    // MARK: 逐字稿校正（design §17.4）

    /// 手动检查可能听错的字（「更多」菜单）
    func checkTranscript() {
        guard let id = selection, readyForAction(id) else { return }
        if detail?.segments.isEmpty != false {
            noticeMessage = String(localized: "还没有逐字稿可以检查")
            return
        }
        guard AppSettings.provider != .none else {
            errorMessage = AppSettings.needsProviderSetup
                ? String(localized: "还没设置整理工具，请先到设置选择 Claude、Codex 或 API")
                : String(localized: "整理工具设置为「不整理」，请先到设置改成 Claude、Codex 或 API")
            return
        }
        if let problem = AppSettings.summarizerProblem { errorMessage = problem.message; return }
        perform { try db.enqueue(id, kind: .correct) }
        runner.wake()
    }

    /// 这几则校正改到的段落（只重读这几段，design §21.12）
    private func segmentIds(ofCorrections ids: [Int64]) -> [Int64] {
        let wanted = Set(ids)
        return Array(Set(detail?.corrections.filter { $0.id.map(wanted.contains) ?? false }.map(\.segmentId) ?? []))
    }

    func acceptCorrection(_ id: Int64) {
        perform(.segments(segmentIds(ofCorrections: [id]), [.corrections])) {
            if try !db.acceptCorrection(id) {
                noticeMessage = String(localized: "这一段已经改过，找不到建议要改的文字")
            }
        }
    }

    func rejectCorrection(_ id: Int64) {
        perform(.detail([.corrections])) { try db.rejectCorrection(id) }
    }

    func revertCorrection(_ id: Int64) {
        perform(.segments(segmentIds(ofCorrections: [id]), [.corrections])) {
            if try !db.revertCorrection(id) {
                noticeMessage = String(localized: "这一段已经改过，没办法还原")
            }
        }
    }

    func acceptAllCorrections() {
        guard let pending = detail?.corrections.filter({ $0.status == "pending" }) else { return }
        acceptCorrections(pending.compactMap(\.id))
    }

    func rejectAllCorrections() {
        guard let pending = detail?.corrections.filter({ $0.status == "pending" }) else { return }
        rejectCorrections(pending.compactMap(\.id))
    }

    /// 同一个词的每一处一起接受或忽略（design §21.11、R20.2）
    func acceptCorrections(_ ids: [Int64]) {
        perform(.segments(segmentIds(ofCorrections: ids), [.corrections])) {
            let failed = try db.acceptCorrections(ids)
            if failed > 0 { noticeMessage = String(localized: "有 \(failed) 则建议的段落已经改过，没有套用") }
        }
    }

    func rejectCorrections(_ ids: [Int64]) {
        perform(.detail([.corrections])) { try db.rejectCorrections(ids) }
    }

    // MARK: 编辑中的草稿（design §21.15、R20.6）：会议内容，存在数据库，不放 UserDefaults

    func drafts(_ meetingId: Int64) -> [String: String] { (try? db.drafts(meetingId)) ?? [:] }

    func latestDraft(_ meetingId: Int64, prefix: String) -> (key: String, text: String)? {
        try? db.latestDraft(meetingId, prefix: prefix)
    }

    func saveDraft(_ meetingId: Int64, key: String, text: String) {
        do { try db.setDraft(meetingId, key: key, text: text) } catch { log.error("save draft failed: \(error.localizedDescription)") }
    }

    func deleteDrafts(_ meetingId: Int64, prefix: String) {
        try? db.deleteDrafts(meetingId, prefix: prefix)
    }

    #if DEBUG
    /// shiyinctl editsegment：等于点那一段开始编辑（逐字稿标签页看到就开始）
    var debugEditSegment: Int64?
    /// shiyinctl settingsaction：等于在设置的整理工具页按「选择」（pickmodel）或粘贴 key 按「保存 key」（savekey）
    var debugSettingsAction: [String]?
    #endif

    /// 卷到这一段并暂时加底色。先清掉再设，同一段点第二次也会卷过去；几秒后拿掉底色，不要一直留着
    func flashSegment(_ id: Int64) {
        highlightSegment = nil
        Task { @MainActor in
            highlightSegment = id
            try? await Task.sleep(for: .seconds(6))
            if highlightSegment == id { highlightSegment = nil }
        }
    }

    /// source：manual（用户改名）或 suggestion（套用 AI 猜的名字，design §21.5）
    func renameSpeaker(_ idx: Int, to name: String, source: String = "manual") {
        guard let id = selection else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // 清空就回到默认名称，用会议语言（会带进会议记录和导出），不是界面语言
        let language = detail?.meeting.meetingLanguage ?? .zh
        let fallback = language.defaultSpeaker(idx)  // l10n-skip
        let name = trimmed.isEmpty ? fallback : trimmed
        let old = detail?.speakers[idx]
        perform(.detail([.speakers, .meeting])) {
            try db.renameSpeaker(id, idx: idx, name: name)
            // 记住这个人的声音（design §21.4）；改回默认名称就忘掉这场会议的这一份
            if AppSettings.voiceprints { try db.learnVoiceprint(id, idx: idx, name: name, source: source) }
            try db.clearSpeakerSuggestion(id, idx: idx)
            // 会议记录里的旧名字换成新名字（design §21.6）
            if let old { try db.replaceSpeakerNameInNotes(id, from: old, to: name) }
        }
    }

    /// 「不是他」：声纹自动带入的名字不对，回到默认名称（design §21.4）；会议记录里的名字也换回去
    func rejectVoiceprintMatch(_ idx: Int) {
        guard let id = selection else { return }
        let language = detail?.meeting.meetingLanguage ?? .zh
        let fallback = language.defaultSpeaker(idx)  // l10n-skip
        let old = detail?.speakers[idx]
        perform(.detail([.speakers, .meeting])) {
            try db.rejectVoiceprintMatch(id, idx: idx, defaultName: fallback)
            if let old { try db.replaceSpeakerNameInNotes(id, from: old, to: fallback) }
        }
    }

    // MARK: 猜说话者的建议（design §21.5、R19.2）

    func applySpeakerSuggestion(_ idx: Int) {
        guard let suggestion = detail?.speakerSuggestions[idx] else { return }
        renameSpeaker(idx, to: suggestion.name, source: "suggestion")
    }

    func applyAllSpeakerSuggestions() {
        for idx in (detail?.speakerSuggestions.keys.sorted() ?? []) { applySpeakerSuggestion(idx) }
    }

    func dismissSpeakerSuggestion(_ idx: Int) {
        guard let id = selection else { return }
        perform(.detail([.speakers])) { try db.clearSpeakerSuggestion(id, idx: idx) }
    }

    /// 待确认的说话者题目送出（R33.2、design §27）：回答是 YesNoAnswer 的文字（依会议语言）。
    /// 是 = 套用建议；不是而且有名字 = 改成那个名字；不是没填、略过 = 清掉建议；还没选的不动
    func answerSpeakerQuestions(_ answers: [Int: String], skipped: Set<Int>) {
        guard let detail else { return }
        let language = detail.meeting.meetingLanguage
        for idx in detail.speakerSuggestions.keys.sorted() {
            if skipped.contains(idx) {
                dismissSpeakerSuggestion(idx)
                continue
            }
            guard let choice = YesNoAnswer(answers[idx] ?? "", language: language), let yes = choice.isYes else { continue }
            let name = choice.correction.trimmingCharacters(in: .whitespacesAndNewlines)
            if yes {
                applySpeakerSuggestion(idx)
            } else if !name.isEmpty {
                renameSpeaker(idx, to: name)
            } else {
                dismissSpeakerSuggestion(idx)
            }
        }
    }

    // MARK: 检测在线会议（design §21.7、R19.4）

    @ObservationIgnored let meetingDetector = MeetingDetector()

    /// 有通知权限就发通知（带按钮），没有就用不抢焦点的浮动窗口
    func showMeetingPrompt(_ prompt: MeetingDetector.Prompt) {
        Task {
            if await notifier.isAuthorized() {
                notifier.meetingPrompt(prompt)
            } else {
                showMeetingPanel(prompt)
            }
        }
    }

    private func showMeetingPanel(_ prompt: MeetingDetector.Prompt) {
        switch prompt {
        case .start(let app):
            MeetingPromptPanel.shared.show(prompt, actions: [
                ("later", String(localized: "这次不用"), {}),
                // 名称长的 app（Microsoft Teams）放进按钮会被截掉；消息里已经有 app 的名字
                ("mute", String(localized: "不要再提醒这个 app"), { MeetingDetector.mute(app.bundleID) }),
                ("start", String(localized: "开始录音"), { [weak self] in self?.startRecording() }),
            ], message: String(localized: "\(app.name) 正在开会，要开始录音吗？"))
        case .stop:
            MeetingPromptPanel.shared.show(prompt, actions: [
                ("continue", String(localized: "继续录"), {}),
                ("stop", String(localized: "停止并转录"), { [weak self] in self?.recorder.stop() }),
            ], message: String(localized: "会议好像结束了，要停止录音吗？"))
        }
    }

    /// 通知上的按钮
    func handleMeetingAction(_ action: String, bundle: String) {
        switch action {
        case "start": startRecording()
        case "mute": MeetingDetector.mute(bundle)
        case "stop": recorder.stop()
        default: break
        }
    }

    // MARK: 对会议提问的状态（design §21.8；流程在 Asking.swift）

    /// 正在问哪里：一场会议或所有会议
    var asking: AskTarget?
    /// 目前会议的问答记录、问所有会议的问答记录
    var meetingQuestions: [QuestionRecord] = []
    var allQuestions: [QuestionRecord] = []
    @ObservationIgnored var askTask: Task<Void, Never>?
    @ObservationIgnored var askProcess: Subprocess?

    // MARK: 认识的人（设置页，design §21.4）

    var people: [PersonSummary] = []

    func reloadPeople() {
        people = (try? db.peopleSummaries()) ?? []
    }

    func renamePerson(_ id: Int64, to name: String) {
        perform { try db.renamePerson(id, to: name) }
        reloadPeople()
    }

    func deletePerson(_ id: Int64) {
        perform { try db.deletePerson(id) }
        reloadPeople()
    }

    func deleteAllPeople() {
        perform { try db.deleteAllPeople() }
        reloadPeople()
    }

    func updateUserNotes(_ text: String) {
        guard let id = selection ?? recorder.meetingId else { return }
        perform { try db.updateUserNotes(id, text) }
    }

    /// 笔记编辑器存档（design §20.4）：画面上是同一场会议时只更新它的笔记，不整份重新读取。
    /// 编辑器切标签页后重新出现时，读到的就是刚存的内容，不会用旧的盖回去
    func saveUserNotes(_ id: Int64, _ text: String) {
        do {
            try db.updateUserNotes(id, text)
            if detail?.meeting.id == id { detail?.meeting.userNotes = text }
        } catch {
            log.error("save user notes failed: \(error.localizedDescription)")
        }
    }

    func addBookmark(at time: Double, meetingId: Int64? = nil, label: String = "") {
        guard let id = meetingId ?? selection else { return }
        perform(.detail([.bookmarks])) { try db.addBookmark(id, time: time, label: label) }
    }

    func deleteBookmark(_ id: Int64) {
        perform(.detail([.bookmarks])) { try db.deleteBookmark(id) }
    }

    func replace(find: String, with replacement: String, addToGlossary: Bool) -> ReplaceResult? {
        guard let id = selection, !find.isEmpty, find != replacement else { return nil }
        var result: ReplaceResult?
        perform {
            result = try db.replace(id, find: find, with: replacement)
            if addToGlossary { try db.addTerm(replacement) }
        }
        return result
    }

    func addTerm(_ term: String) { perform { try db.addTerm(term) } }
    func dismissGlossarySuggestion(_ term: String) { perform { try db.dismissGlossarySuggestion(term) } }
    func deleteTerm(_ id: Int64) { perform { try db.deleteTerm(id) } }

    func saveTemplate(_ template: TemplateRecord) { perform { try db.saveTemplate(template) } }
    func deleteTemplate(_ id: String) { perform { try db.deleteTemplate(id) } }

    // MARK: 导入其他格式（R3.3～R3.5）

    /// 解开封包、复制录音在背景做（design §21.13、R20.4）
    func importPackage(_ url: URL) {
        let (db, folder) = (db, currentFolder)
        importingCount += 1
        Task {
            defer { importingCount -= 1 }
            do {
                let meeting = try await Task.detached(priority: .userInitiated) {
                    try MeetingPackage.importPackage(url, db: db, folder: folder)
                }.value
                reload()
                showTrash = false
                selection = meeting.id
                noticeMessage = String(localized: "已导入「\(meeting.displayTitle)」")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func importTranscript(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .utf16)) else {
            errorMessage = String(localized: "读不到「\(url.lastPathComponent)」")
            return
        }
        let parsed = TranscriptImporter.parse(text, ext: url.pathExtension.lowercased())
        guard !parsed.segments.isEmpty else {
            errorMessage = String(localized: "「\(url.lastPathComponent)」里没有可以用的逐字稿内容")
            return
        }
        do {
            let meeting = try db.insertMeeting(Meeting(
                meetingDate: Importer.inferDate(filename: url.lastPathComponent, modified: Importer.modificationDate(url)),
                sourceFilename: url.lastPathComponent, templateId: AppSettings.defaultTemplate, source: "transcript",
                folder: currentFolder, language: AppSettings.defaultMeetingLanguage.rawValue),
                audioExtension: nil)
            let id = meeting.id!
            try db.saveTranscript(id, segments: parsed.segments.enumerated().map { i, s in
                Segment(meetingId: id, seq: i, start: s.start, end: s.end, text: s.text, lowConfidence: false, speaker: nil, kind: "final")
            }, duration: Int(parsed.segments.last?.end ?? 0), speakerCount: 0)
            if AppSettings.autoSummarize && AppSettings.summarizerReady { try db.enqueue(id, kind: .summarize) }
            runner.wake()
            reload()
            showTrash = false
            selection = id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Markdown 当成用户笔记：有选会议就加到那场，没有就建一场新的（R3.5）
    func importMarkdownNotes(_ urls: [URL]) {
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let id = selection, let meeting = try? db.meeting(id) {
                let merged = meeting.userNotes.isEmpty ? text : meeting.userNotes + "\n\n" + text
                perform { try db.updateUserNotes(id, merged) }
                tab = .transcript
                userNotesExpanded = true
            } else if let meeting = try? db.insertMeeting(Meeting(
                meetingDate: DateText.string(Date()), sourceFilename: url.lastPathComponent, userNotes: text, source: "transcript",
                folder: currentFolder, language: AppSettings.defaultMeetingLanguage.rawValue),
                audioExtension: nil) {
                perform { try db.updateUserNotes(meeting.id!, text) }
                selection = meeting.id
                tab = .transcript
                userNotesExpanded = true
            }
        }
    }

    // MARK: 导出（R7）

    func openExportSheet() {
        exportMeetingId = selection
        showExportSheet = true
    }

    /// 依会议 id 从数据库读要导出的资料；会议已经被永久删除时丢出错误（design §20.9）
    func exportBundle(meetingId: Int64) throws -> ExportBundle {
        guard let meeting = try db.meeting(meetingId) else { throw ExportError.meetingGone }
        return ExportBundle(meeting: meeting, segments: try db.segments(meetingId),
                            speakers: Dictionary(uniqueKeysWithValues: try db.speakers(meetingId).map { ($0.idx, $0.name) }),
                            bookmarks: try db.bookmarks(meetingId), notes: meeting.decodedNotes, documents: try db.documents(meetingId))
    }

    func exportBundle() -> ExportBundle? {
        guard let d = detail else { return nil }
        return ExportBundle(meeting: d.meeting, segments: d.segments, speakers: d.speakers, bookmarks: d.bookmarks, notes: d.notes,
                            documents: d.documents)
    }

    /// 写出文件
    func export(_ item: ExportItem, format: String, times: Bool, speakers: Bool, meetingId: Int64, to url: URL) async throws {
        let b = try exportBundle(meetingId: meetingId)
        switch item {
        case .notes:
            switch format {
            case "pdf": try await HTML.pdf(NotesExporter.html(b), to: url)
            case "docx": try await HTML.docx(NotesExporter.html(b)).write(to: url)
            default: try NotesExporter.markdown(b).write(to: url, atomically: true, encoding: .utf8)
            }
        case .mindMap:
            // 心智图（design §42.4）：段落名称跟着会议语言，同其他导出
            guard let layout = MindMapExport.layout(b) else { throw ExportError.noNotes }
            let language = b.meeting.meetingLanguage
            switch format {
            case "svg": try MindMap.svg(layout, language: language).write(to: url, atomically: true, encoding: .utf8)
            case "pdf": try MindMapExport.pdf(layout, language: language, to: url)
            default:
                guard let data = MindMapExport.png(layout, language: language) else { throw ExportError.noNotes }
                try data.write(to: url)
            }
        case .transcript:
            if format == "docx" { try await HTML.docx(TranscriptExporter.html(b, times: times, speakers: speakers)).write(to: url) }
            else {
                // 文字格式、封包在背景写，长会议不卡住画面（design §21.13）；Word、PDF 用异步的 HTML 转换
                try await Task.detached(priority: .userInitiated) {
                    try TranscriptExporter.text(b, format: format, times: times, speakers: speakers).write(to: url, atomically: true, encoding: .utf8)
                }.value
            }
        case .audio:
            try await AudioExporter.export(b, format: format, to: url)
        case .package:
            try await Task.detached(priority: .userInitiated) { try MeetingPackage.export(b, to: url) }.value
        }
    }

    func suggestedFilename(_ item: ExportItem, format: String, meeting: Meeting?) -> String {
        guard let m = meeting else { return String(localized: "会议.\(format)") }
        let base = "\(m.meetingDate) \(m.displayTitle)".replacingOccurrences(of: "/", with: "／").replacingOccurrences(of: ":", with: "：")  // l10n-skip
        switch item {
        case .transcript: return String(localized: "\(base)（逐字稿）.\(format)")
        case .mindMap: return String(localized: "\(base)（心智图）.\(format)")
        case .audio: return "\(base).\(format)"
        default: return "\(base).\(format)"
        }
    }

    enum ExportError: LocalizedError {
        case meetingGone, noNotes
        var errorDescription: String? {
            switch self {
            case .meetingGone: return String(localized: "这场会议已经被删除，没办法导出")
            case .noNotes: return String(localized: "这场会议还没有会议记录，画不出心智图")
            }
        }
    }

    enum CopyStyle { case plain, markdown, rich }

    func copyNotes(_ style: CopyStyle) {
        guard let b = exportBundle() else { return }
        guard b.notes != nil else {
            noticeMessage = String(localized: "还没有会议记录可以复制")
            return
        }
        switch style {
        case .plain:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(NotesExporter.plain(b), forType: .string)
        case .markdown:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(NotesExporter.markdown(b), forType: .string)
        case .rich:
            HTML.copy(plain: NotesExporter.plain(b), html: NotesExporter.html(b))
        }
        noticeMessage = String(localized: "已复制会议记录")
    }

    /// 复制心智图（design §42.4）：PNG 放进剪贴板，贴到聊天软件、演示文稿
    func copyMindMap() {
        guard let b = exportBundle() else { return }
        guard let layout = MindMapExport.layout(b), let png = MindMapExport.png(layout, language: b.meeting.meetingLanguage) else {
            noticeMessage = String(localized: "还没有会议记录可以画成心智图")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        noticeMessage = String(localized: "已复制心智图")
    }

    // MARK: 搜索（R9.1）

    private func runSearch() {
        searchResults = (try? db.search(searchQuery)) ?? []
    }

    func openSearchHit(_ hit: SearchHit) {
        showTrash = false
        selection = hit.meetingId
        switch hit.kind {
        case .segment:
            tab = .transcript
            flashSegment(hit.ref)
            if let segment = detail?.segments.first(where: { $0.id == hit.ref }) { player.seek(to: segment.start, play: false) }
        case .notes, .title: tab = .summary
        case .userNotes: tab = .transcript; userNotesExpanded = true
        }
    }

    // MARK: 第二版留下的文件（R10.5）

    func deleteLegacyItems() {
        for url in Paths.legacyItems { try? FileManager.default.removeItem(at: url) }
        legacyBytes = 0
        noticeMessage = String(localized: "已删除第二版的 Python 环境和旧模型")
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: 内部

    /// 操作完要重读什么（design §21.12）：全部（会议列表和目前的会议），或只重读目前这场会议的某几样
    enum ReloadScope {
        case all
        case detail(DetailParts)
        /// 只重读改到的这几段（长会议整份重读要几十毫秒），以及其他几样
        case segments([Int64], DetailParts = [])
    }

    struct DetailParts: OptionSet {
        let rawValue: Int
        static let speakers = DetailParts(rawValue: 1 << 0)
        static let bookmarks = DetailParts(rawValue: 1 << 1)
        static let segments = DetailParts(rawValue: 1 << 2)
        static let corrections = DetailParts(rawValue: 1 << 3)
        static let meeting = DetailParts(rawValue: 1 << 4)   // 会议本身、会议记录、版本数
        static let documents = DetailParts(rawValue: 1 << 5)
    }

    func perform(_ scope: ReloadScope = .all, _ work: () throws -> Void) {
        #if DEBUG
        let started = Date()
        defer { DebugMetrics.recordPerform(Date().timeIntervalSince(started) * 1000) }
        #endif
        do { try work() } catch { errorMessage = error.localizedDescription }
        switch scope {
        case .all: reload()
        case .detail(let parts): reloadDetail(parts)
        case .segments(let ids, let parts): reloadDetail(parts, segmentIds: ids)
        }
    }

    /// 只重读目前这场会议的某几样（segmentIds：只换掉这几段）；目前没有显示这场会议时整个重读
    func reloadDetail(_ parts: DetailParts, segmentIds: [Int64] = []) {
        guard let id = selection, var updated = detail, updated.meeting.id == id else { return reloadDetail() }
        if !segmentIds.isEmpty, let fresh = try? db.segments(ids: segmentIds) {
            let index = Dictionary(updated.segments.enumerated().compactMap { i, s in s.id.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
            for segment in fresh { if let id = segment.id, let i = index[id] { updated.segments[i] = segment } }
        }
        #if DEBUG
        DebugMetrics.bump("reloadDetailParts")
        #endif
        if parts.contains(.speakers) {
            updated.loadSpeakers((try? db.speakers(id)) ?? [])
            updated.speakerCandidates = (try? db.voiceprintCandidates(id)) ?? [:]
            updated.speakerUndoLabel = try? db.speakerUndoLabel(id)
        }
        if parts.contains(.bookmarks) { updated.bookmarks = (try? db.bookmarks(id)) ?? [] }
        if parts.contains(.segments) { updated.segments = (try? db.segments(id)) ?? [] }
        if parts.contains(.corrections) { updated.corrections = (try? db.corrections(id)) ?? [] }
        if parts.contains(.documents) { updated.loadDocuments((try? db.documents(id)) ?? []) }
        if parts.contains(.meeting), let meeting = try? db.meeting(id) {
            updated.meeting = meeting
            updated.notes = meeting.decodedNotes
            updated.versionCount = (try? db.versionCount(id)) ?? 0
            updated.linkReviewItems()
        }
        if !parts.isDisjoint(with: [.segments, .corrections]) || !segmentIds.isEmpty { updated.buildIndexes() }
        detail = updated
        syncReviewDraft()
    }

    /// 待确认的回答跟着目前的会议（design §31.2）：换会议就换一份（旧的先存），题目或说话者的建议变了就同步
    private func syncReviewDraft() {
        guard let detail, let id = detail.meeting.id else {
            reviewDraft?.flush()
            reviewDraft = nil
            return
        }
        if reviewDraft?.meetingId != id {
            reviewDraft?.flush()
            reviewDraft = ReviewDraft(meetingId: id, model: self)
        }
        reviewDraft?.sync(items: detail.notes?.reviewItems ?? [], suggestions: detail.speakerSuggestions)
    }

    /// 送出待确认的回答（待确认标签页和就地回答共用，R41.2）：先送整理工具要处理的题目（题目文字可能有说话者的名字，
    /// 改名后会变），失败时全部留着；再处理说话者的题目（design §27）
    func submitReviewDraft(only indexes: Set<Int>? = nil) {
        guard let draft = reviewDraft, detail?.meeting.id == draft.meetingId else { return }
        if let indexes {
            // 卡片只送这一条对到的题目（R41.2），说话者题目不算，其他题目的回答留着
            let answers = draft.answers.filter { indexes.contains($0.key) }
            let dismissed = draft.dismissed.intersection(indexes)
            guard !answers.isEmpty || !dismissed.isEmpty, submitReview(answers: answers, dismissed: dismissed) else { return }
            draft.clear(indexes: indexes)
            return
        }
        if draft.answeredCount > 0 || !draft.dismissed.isEmpty {
            guard submitReview(answers: draft.answers, dismissed: draft.dismissed) else { return }
        }
        answerSpeakerQuestions(draft.speakerAnswers, skipped: draft.speakerSkipped)
        draft.clear()
    }

    private func jobFinished(_ job: Job, error: Error?) {
        guard let meeting = try? db.meeting(job.meetingId) else { return }
        notifier.jobFinished(job, meeting: meeting, error: error)
    }
}

extension AppModel {
    /// 登录企业服务器后默认转录、整理都用它（R49.3）：设置页的登录、加入链接共用
    func applyEnterpriseDefaults(llm: Bool) {
        UserDefaults.standard.set("server", forKey: AppSettings.transcriptionEngineKey)
        if llm { UserDefaults.standard.set(LLMProvider.enterprise.rawValue, forKey: AppSettings.providerKey) }
        runner.wake()
        refreshEnvironment()
        NotificationCenter.default.post(name: .summarizerStateChanged, object: nil)
    }

    func refreshSummarizerProblem() {
        let problem = AppSettings.summarizerProblem
        if problem != summarizerProblem { summarizerProblem = problem }
    }
}

extension Notification.Name {
    /// 拾音要结束了：画面上还开着的编辑器马上存草稿（design §21.15）
    static let flushDrafts = Notification.Name("com.weiwei.shiyin.flushDrafts")
    /// 整理工具的登录状态、key、暂停变了（design §34.1）
    static let summarizerStateChanged = Notification.Name("com.weiwei.shiyin.summarizerStateChanged")
}
