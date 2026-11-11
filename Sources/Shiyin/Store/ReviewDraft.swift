import Foundation
import Observation

/// 待确认的回答（design §31.2、R41.2）：待确认标签页和记录旁的就地回答共用同一份，两边看到的一样。
/// 草稿存在数据库（§21.15、R20.6）：打字停 0.8 秒存一次；换标签页、换会议、结束拾音都还在，直到送出。
/// 回答是照题号存的：题目换了（依回答修正、刷新、复原上一版）就清掉，不然会配到别的题目（`sync`）
@MainActor
@Observable
final class ReviewDraft {
    let meetingId: Int64
    /// 题号 → 回答（是非题是 `YesNoAnswer` 的文字）
    var answers: [Int: String] = [:] { didSet { scheduleSave() } }
    var dismissed: Set<Int> = [] { didSet { scheduleSave() } }
    /// 说话者编号 → 回答（「是」「不是，名字」）
    var speakerAnswers: [Int: String] = [:] { didSet { scheduleSave() } }
    var speakerSkipped: Set<Int> = [] { didSet { scheduleSave() } }
    /// 就地回答展开中的那一条记录（R41.2），同时只展开一条
    var expanded: NoteItemRef?

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var questions: [String] = []
    /// 说话者编号 → 草稿的 key（建议换了人就是新的题目）
    @ObservationIgnored private var speakerKeys: [Int: String] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var muted = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(meetingId: Int64, model: AppModel) {
        self.meetingId = meetingId
        self.model = model
        // 拾音要结束了：马上存（design §21.15）
        observer = NotificationCenter.default.addObserver(forName: .flushDrafts, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 加载会议、会议记录或说话者换掉时调用：第一次从数据库读草稿；题目变了就清掉回答；
    /// 说话者的建议被套用或清掉（例如从「猜到几位说话者」那边）就不留那位的回答
    func sync(items: [MeetingNotes.ReviewItem], suggestions: [Int: SpeakerNaming.Suggestion]) {
        let newQuestions = items.map(\.question)
        let newKeys = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.key, "\($0.key):\($0.value.name)") })
        if !loaded {
            loaded = true
            questions = newQuestions
            speakerKeys = newKeys
            let drafts = model.drafts(meetingId)
            guard !drafts.isEmpty else { return }
            withoutSaving {
                for (index, question) in newQuestions.enumerated() {
                    if let answer = drafts["review:" + question] { answers[index] = answer }
                    if drafts["review-skip:" + question] != nil { dismissed.insert(index) }
                }
                for (idx, key) in newKeys {
                    if let answer = drafts["speaker-review:" + key] { speakerAnswers[idx] = answer }
                    if drafts["speaker-review-skip:" + key] != nil { speakerSkipped.insert(idx) }
                }
            }
            return
        }
        if newQuestions != questions {
            // 题目换了（送出一部分、依回答修正、刷新、复原上一版）：草稿是照题目文字存的，
            // 还在的题目把回答照文字接回来，不在的删掉草稿（design §31.2）
            saveTask?.cancel()
            var answerByText: [String: String] = [:], skippedTexts: Set<String> = []
            for (index, question) in questions.enumerated() {
                if let answer = answers[index] { answerByText[question] = answer }
                if dismissed.contains(index) { skippedTexts.insert(question) }
            }
            let surviving = Set(newQuestions)
            for question in questions where !surviving.contains(question) {
                model.saveDraft(meetingId, key: "review:" + question, text: "")
                model.saveDraft(meetingId, key: "review-skip:" + question, text: "")
            }
            questions = newQuestions
            withoutSaving {
                answers = [:]
                dismissed = []
                for (index, question) in newQuestions.enumerated() {
                    if let answer = answerByText[question] { answers[index] = answer }
                    if skippedTexts.contains(question) { dismissed.insert(index) }
                }
            }
            expanded = nil
        }
        if newKeys != speakerKeys {
            speakerKeys = newKeys
            withoutSaving {
                speakerAnswers = speakerAnswers.filter { newKeys[$0.key] != nil }
                speakerSkipped = speakerSkipped.filter { newKeys[$0] != nil }
            }
        }
    }

    /// 「全部略过」（R41.5）：还没回答的题目都标成略过，已经有回答的不动
    func skipAllUnanswered(questionCount: Int, speakers: [Int]) {
        var skipQuestions = dismissed
        for index in 0..<max(0, questionCount) where (answers[index] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            skipQuestions.insert(index)
        }
        dismissed = skipQuestions
        var skipSpeakers = speakerSkipped
        for idx in speakers where (speakerAnswers[idx] ?? "").isEmpty { skipSpeakers.insert(idx) }
        speakerSkipped = skipSpeakers
    }

    /// 还有没回答也没略过的题目（「全部略过」才有东西可以略）
    func hasUnanswered(questionCount: Int, speakers: [Int]) -> Bool {
        (0..<max(0, questionCount)).contains { !dismissed.contains($0) && (answers[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            || speakers.contains { !speakerSkipped.contains($0) && (speakerAnswers[$0] ?? "").isEmpty }
    }

    /// 送出后：草稿删掉、回答清空
    func clear() {
        saveTask?.cancel()
        model.deleteDrafts(meetingId, prefix: "review")
        model.deleteDrafts(meetingId, prefix: "speaker-review")
        withoutSaving { answers = [:]; dismissed = []; speakerAnswers = [:]; speakerSkipped = [] }
        expanded = nil
    }

    /// 卡片只送了这几题（R41.2）：只清这几题的回答，其他留着；题目消失后 `sync` 会把它们的草稿删掉
    func clear(indexes: Set<Int>) {
        withoutSaving {
            for index in indexes { answers[index] = nil }
            dismissed.subtract(indexes)
        }
        expanded = nil
    }

    /// 马上存（结束拾音、换会议）
    func flush() {
        saveTask?.cancel()
        save()
    }

    // MARK: 题数、送出钮（待确认标签页和就地回答共用）

    /// 已回答的题数；`only` 给了就只算这几题（卡片）
    func answeredCount(only: Set<Int>? = nil) -> Int {
        answers.filter { (only?.contains($0.key) ?? true) && !dismissed.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    func dismissedCount(only: Set<Int>? = nil) -> Int {
        only.map { dismissed.intersection($0).count } ?? dismissed.count
    }

    var answeredCount: Int { answeredCount() }

    var speakerAnsweredCount: Int {
        speakerAnswers.filter { !speakerSkipped.contains($0.key) && !$0.value.isEmpty }.count
    }

    /// 待确认标签页：全部的题目（含说话者题目）；卡片（`only`）：只有这几题
    func hasSomethingToSubmit(only: Set<Int>? = nil) -> Bool {
        if let only { return answeredCount(only: only) + dismissedCount(only: only) > 0 }
        return answeredCount + speakerAnsweredCount > 0 || !dismissed.isEmpty || !speakerSkipped.isEmpty
    }

    var hasSomethingToSubmit: Bool { hasSomethingToSubmit() }

    func submitTitle(only: Set<Int>? = nil) -> String {
        let answered = answeredCount(only: only) + (only == nil ? speakerAnsweredCount : 0)
        let skipped = dismissedCount(only: only) + (only == nil ? speakerSkipped.count : 0)
        switch (answered, skipped) {
        case (0, 0): return String(localized: "送出")
        case (0, let d): return String(localized: "略过 \(d) 题")
        case (let a, 0): return String(localized: "送出 \(a) 题回答")
        case (let a, let d): return String(localized: "送出 \(a) 题回答、略过 \(d) 题")
        }
    }

    var submitTitle: String { submitTitle() }

    // MARK: 存草稿

    private func withoutSaving(_ body: () -> Void) {
        muted = true
        body()
        muted = false
    }

    /// 打字停 0.8 秒存一次
    private func scheduleSave() {
        guard loaded, !muted else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        guard loaded else { return }
        for (index, question) in questions.enumerated() {
            model.saveDraft(meetingId, key: "review:" + question, text: answers[index] ?? "")
            model.saveDraft(meetingId, key: "review-skip:" + question, text: dismissed.contains(index) ? "1" : "")
        }
        for (idx, key) in speakerKeys {
            model.saveDraft(meetingId, key: "speaker-review:" + key, text: speakerAnswers[idx] ?? "")
            model.saveDraft(meetingId, key: "speaker-review-skip:" + key, text: speakerSkipped.contains(idx) ? "1" : "")
        }
    }
}
