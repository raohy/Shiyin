import Foundation
import GRDB

/// 一组问答（design §21.8）：meeting_id 是 NULL 时是问所有会议
struct QuestionRecord: SnakeCaseRecord, Identifiable, Hashable {
    static let databaseTableName = "questions"
    var id: Int64?
    var meetingId: Int64?
    var scope: String = ""
    var question: String
    var answer: String          // AskPrompt.Answer 的 JSON
    var provider: String
    var createdAt: String = Clock.now()

    var decoded: AskPrompt.Answer? { try? JSONDecoder().decode(AskPrompt.Answer.self, from: Data(answer.utf8)) }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

enum AskTarget: Equatable {
    case meeting(Int64)
    case all
}

/// 提交后立即显示的问题；完成前不把空回答写入历史记录。
struct AskRequest: Identifiable {
    enum Phase {
        case preparing, keywords, searching, answering, saving, cancelled, failed(String)

        var isRunning: Bool {
            switch self {
            case .cancelled, .failed: return false
            default: return true
            }
        }

        var label: String {
            switch self {
            case .preparing: return String(localized: "正在准备会议记录和逐字稿…")
            case .keywords: return String(localized: "正在理解问题，提取搜索关键词…")
            case .searching: return String(localized: "正在查找相关会议和录音片段…")
            case .answering: return String(localized: "正在分析会议内容并生成回答…")
            case .saving: return String(localized: "正在整理回答和出处…")
            case .cancelled: return String(localized: "已取消回答，问题已保留")
            case .failed(let reason): return String(localized: "回答失败：\(reason)")
            }
        }
    }

    let id = UUID()
    let target: AskTarget
    let question: String
    let scope: AskScope
    let folder: String?
    let providerLabel: String
    let startedAt = Date()
    var phase: Phase = .preparing
}

/// 问所有会议的范围
enum AskScope: String, CaseIterable, Identifiable {
    case all, folder, recent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return String(localized: "所有会议")
        case .folder: return String(localized: "目前的文件夹")
        case .recent: return String(localized: "最近 30 天")
        }
    }
}

extension AppDatabase {
    func questions(meetingId: Int64?) throws -> [QuestionRecord] {
        try pool.read { db in
            if let meetingId {
                return try QuestionRecord.filter(Column("meeting_id") == meetingId).order(Column("id")).fetchAll(db)
            }
            return try QuestionRecord.filter(Column("meeting_id") == nil).order(Column("id")).fetchAll(db)
        }
    }

    func saveQuestion(_ record: QuestionRecord) throws {
        try pool.write { db in
            var record = record
            try record.insert(db)
        }
    }

    func deleteQuestions(meetingId: Int64?) throws {
        try pool.write { db in
            if let meetingId {
                try db.execute(sql: "DELETE FROM questions WHERE meeting_id = ?", arguments: [meetingId])
            } else {
                try db.execute(sql: "DELETE FROM questions WHERE meeting_id IS NULL")
            }
        }
    }
}

/// 对会议提问（design §21.8、R19.6、D32）：不排进工作队列，用户在等；同时只问一题
extension AppModel {
    /// 跨会议时最多带几场会议、总共多少字
    static let askMeetingLimit = 8
    static let askCharacterLimit = 40_000

    func loadMeetingQuestions(_ meetingId: Int64) {
        meetingQuestions = (try? db.questions(meetingId: meetingId)) ?? []
    }

    func loadAllQuestions() {
        allQuestions = (try? db.questions(meetingId: nil)) ?? []
    }

    func clearQuestions(meetingId: Int64?) {
        try? db.deleteQuestions(meetingId: meetingId)
        if let meetingId { loadMeetingQuestions(meetingId) } else { loadAllQuestions() }
    }

    /// 不能问时的原因（还没设置整理工具、设置为不整理、正在问别的）
    var askUnavailableReason: String? {
        if AppSettings.provider == .none {
            return AppSettings.needsProviderSetup
                ? String(localized: "还没设置整理工具，没办法提问；请到设置选择 Claude、Codex 或 API")
                : String(localized: "整理工具设置为「不整理」，没办法提问；请到设置改成 Claude、Codex 或 API")
        }
        // 没登录、没有 key…（R45.4）
        if let problem = AppSettings.summarizerProblem { return problem.message }
        return nil
    }

    func cancelAsk() {
        guard asking != nil else { return }
        askRequest?.phase = .cancelled
        askProcess?.terminate()
        askTask?.cancel()
    }

    func retryAsk() {
        guard asking == nil, let request = askRequest else { return }
        switch request.target {
        case .meeting(let id): askMeeting(request.question, meetingId: id)
        case .all: askAll(request.question, scope: request.scope, folder: request.folder)
        }
    }

    // MARK: 一场会议

    func askMeeting(_ question: String, meetingId: Int64? = nil) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, asking == nil, let id = meetingId ?? selection, let meeting = try? db.meeting(id) else { return }
        if let reason = askUnavailableReason { errorMessage = reason; return }
        let provider = AppSettings.provider, model = AppSettings.model
        let language = meeting.meetingLanguage
        run(.meeting(id), question: question, providerLabel: provider.shortLabel) {
            let names = Dictionary(uniqueKeysWithValues: ((try? self.db.speakers(id)) ?? []).map { ($0.idx, $0.name) })
            let lines = ((try? self.db.segments(id)) ?? []).map { s in
                let speaker = s.speaker.map { (names[$0] ?? language.defaultSpeaker($0)) + language.text(zh: "：", en: ": ", ja: "：") } ?? ""
                return "[\(TimeFormat.string(s.start))] \(speaker)\(s.text)"
            }
            let history = ((try? self.db.questions(meetingId: id)) ?? []).suffix(3).compactMap { q in q.decoded.map { (q.question, $0.answer) } }
            let documents = ((try? self.db.documents(id)) ?? []).map(DocumentText.init)
            let prompt = AskPrompt.meetingPrompt(meeting: meeting, notes: meeting.decodedNotes, lines: lines, history: history, question: question,
                                                 documents: documents)
            let system = AskPrompt.meetingSystem(language, documents: !documents.isEmpty)
            self.askRequest?.phase = .answering
            let raw = try await AskPrompt.generate(AskPrompt.Answer.self, provider: provider, model: model, system: system,
                                                   prompt: prompt, format: AskPrompt.meetingFormat, onStart: { self.askProcess = $0 })
            return QuestionRecord(meetingId: id, question: question,
                                  answer: Self.json(AskPrompt.validate(raw, meetingIds: nil, documentCitations: !documents.isEmpty)),
                                  provider: provider.rawValue)
        }
    }

    // MARK: 所有会议

    func askAll(_ question: String, scope: AskScope) {
        askAll(question, scope: scope, folder: folderFilter)
    }

    private func askAll(_ question: String, scope: AskScope, folder: String?) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, asking == nil else { return }
        if let reason = askUnavailableReason { errorMessage = reason; return }
        let provider = AppSettings.provider, model = AppSettings.model
        let language = MeetingLanguage.interface
        run(.all, question: question, scope: scope, folder: folder, providerLabel: provider.shortLabel) {
            // 1. 抽关键词
            self.askRequest?.phase = .keywords
            struct Keywords: Decodable { var keywords: [String] }
            let keywords = try await AskPrompt.generate(Keywords.self, provider: provider, model: model, system: AskPrompt.keywordsSystem(language),
                                                        prompt: AskPrompt.keywordsPrompt(language, question: question),
                                                        format: AskPrompt.keywordsFormat, onStart: { self.askProcess = $0 }).keywords
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 2 }
            try Task.checkCancellation()
            // 2. 全文搜索，挑会议和片段
            self.askRequest?.phase = .searching
            let blocks = self.askBlocks(keywords: keywords, scope: scope, folder: folder)
            guard !blocks.isEmpty else {
                let answer = AskPrompt.Answer(answer: String(localized: "找不到跟这个问题有关的会议。可以换个说法，或用会议里实际讲的词再问一次。"),
                                              found: false, citations: [], keywords: keywords, meetingIds: [])
                return QuestionRecord(meetingId: nil, scope: scope.rawValue, question: question, answer: Self.json(answer), provider: provider.rawValue)
            }
            // 3. 回答
            self.askRequest?.phase = .answering
            let raw = try await AskPrompt.generate(AskPrompt.Answer.self, provider: provider, model: model, system: AskPrompt.allSystem(language),
                                                   prompt: AskPrompt.allPrompt(language, blocks: blocks, question: question),
                                                   format: AskPrompt.allFormat, onStart: { self.askProcess = $0 })
            var answer = AskPrompt.validate(raw, meetingIds: Set(blocks.map(\.id)))
            answer.keywords = keywords
            answer.meetingIds = blocks.map(\.id)
            return QuestionRecord(meetingId: nil, scope: scope.rawValue, question: question, answer: Self.json(answer), provider: provider.rawValue)
        }
    }

    /// 用每个关键词搜索，依命中数、日期挑最多 8 场会议；每场带摘要、决议和命中的段落（前后各一段），总长 40,000 字以内
    func askBlocks(keywords: [String], scope: AskScope, folder: String?) -> [AskPrompt.MeetingBlock] {
        var hits: [Int64: [SearchHit]] = [:]
        for keyword in keywords {
            for hit in (try? db.search(keyword, limit: 300)) ?? [] { hits[hit.meetingId, default: []].append(hit) }
        }
        let cutoff = DateText.string(Date().addingTimeInterval(-30 * 86_400))
        let candidates: [(meeting: Meeting, hits: [SearchHit])] = hits.compactMap { id, list in
            guard let meeting = try? db.meeting(id), meeting.deletedAt == nil else { return nil }
            switch scope {
            case .all: break
            case .folder: guard let folder, meeting.folder == folder else { return nil }
            case .recent: guard meeting.meetingDate >= cutoff else { return nil }
            }
            return (meeting, list)
        }
        .sorted { a, b in a.hits.count != b.hits.count ? a.hits.count > b.hits.count : a.meeting.meetingDate > b.meeting.meetingDate }
        var blocks: [AskPrompt.MeetingBlock] = []
        var total = 0
        for (meeting, list) in candidates.prefix(Self.askMeetingLimit) {
            let id = meeting.id!
            let language = meeting.meetingLanguage
            let notes = meeting.decodedNotes
            let summary = ((notes?.summary ?? []) + (notes?.decisions ?? [])).map { $0.time.isEmpty ? $0.text : "[\($0.time)] \($0.text)" }
            let segments = (try? db.segments(id)) ?? []
            let names = Dictionary(uniqueKeysWithValues: ((try? db.speakers(id)) ?? []).map { ($0.idx, $0.name) })
            let index = Dictionary(segments.enumerated().compactMap { i, s in s.id.map { ($0, i) } }, uniquingKeysWith: { a, _ in a })
            var wanted = Set<Int>()
            for hit in list where hit.kind == .segment {
                if let i = index[hit.ref] { wanted.formUnion([i - 1, i, i + 1].filter { segments.indices.contains($0) }) }
            }
            let lines = wanted.sorted().map { i -> String in
                let s = segments[i]
                let speaker = s.speaker.map { (names[$0] ?? language.defaultSpeaker($0)) + language.text(zh: "：", en: ": ", ja: "：") } ?? ""
                return "[\(TimeFormat.string(s.start))] \(speaker)\(s.text)"
            }
            var block = AskPrompt.MeetingBlock(id: id, title: meeting.displayTitle, date: meeting.meetingDate, summary: summary, lines: lines)
            let size = (block.summary + block.lines).reduce(0) { $0 + $1.count }
            if total + size > Self.askCharacterLimit {
                // 放不下整场：只放到上限为止的段落
                let room = Self.askCharacterLimit - total - block.summary.reduce(0) { $0 + $1.count }
                guard room > 200 else { break }
                var used = 0
                block.lines = block.lines.prefix { used += $0.count; return used <= room }.map { $0 }
            }
            total += (block.summary + block.lines).reduce(0) { $0 + $1.count }
            blocks.append(block)
        }
        return blocks
    }

    /// 共用的流程：标记正在问、可以取消、存问答、更新画面
    private func run(_ target: AskTarget, question: String, scope: AskScope = .all, folder: String? = nil, providerLabel: String,
                     _ work: @escaping @MainActor () async throws -> QuestionRecord) {
        askRequest = AskRequest(target: target, question: question, scope: scope, folder: folder, providerLabel: providerLabel)
        asking = target
        askTask = Task {
            defer {
                asking = nil
                askTask = nil
                askProcess = nil
            }
            do {
                await Task.yield()
                try Task.checkCancellation()
                let record = try await work()
                try Task.checkCancellation()
                askRequest?.phase = .saving
                try db.saveQuestion(record)
                UsageStats.shared.asked()
                if case .meeting(let id) = target {
                    if selection == id { loadMeetingQuestions(id) }
                } else { loadAllQuestions() }
                askRequest = nil
            } catch is CancellationError {
                askRequest?.phase = .cancelled
            } catch {
                // CLI 被结束（按了取消）时也会丢错误
                askRequest?.phase = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
        }
    }

    private static func json(_ answer: AskPrompt.Answer) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(answer)) ?? Data(), as: UTF8.self)
    }

    /// 点了回答里的出处：打开那场会议、切到逐字稿、从那个时间点播放
    func openCitation(meetingId: Int64, time: String) {
        openMainWindow?()
        showTrash = false
        selection = meetingId
        tab = .transcript
        guard let seconds = TimeFormat.seconds(time) else { return }
        player.seek(to: seconds, play: false)
        if let id = detail?.segmentId(at: seconds) { flashSegment(id) }
    }
}
