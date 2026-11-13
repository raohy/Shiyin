import Foundation

/// 会前准备独立于用户笔记保存（design §46）。
struct MeetingPreparation: Codable, Equatable {
    var background = ""
    var goals = ""
    var role = ""
    var initialQuestions = ""
    var enabled = false

    var hasContext: Bool { !(background + goals).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var bounded: MeetingPreparation {
        MeetingPreparation(background: String(background.prefix(4000)), goals: String(goals.prefix(2000)),
                           role: String(role.prefix(1000)), initialQuestions: String(initialQuestions.prefix(4000)), enabled: enabled)
    }
}

struct CoachQuestion: Codable, Equatable, Identifiable {
    enum Status: String, Codable, CaseIterable { case pending, asked, ignored }
    var id = UUID().uuidString
    var text: String
    var reason = ""
    var time: Double? = nil
    var quote = ""
    var priority = 2
    var status: Status = .pending
}

struct MeetingAssistance: Codable, Equatable {
    var preparation = MeetingPreparation()
    var summary = ""
    /// 下次读取的音频复核稿序号和字符偏移；同一个长段落可以分多批处理。
    var nextSeq = 0
    var offset = 0
    var questions: [CoachQuestion] = []

    var pending: [CoachQuestion] {
        questions.filter { $0.status == .pending }.sorted { $0.priority < $1.priority }
    }

    mutating func seedQuestions() {
        for line in preparation.initialQuestions.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, questions.count < 100, !questions.contains(where: { Self.similar($0.text, text) }) else { continue }
            questions.append(CoachQuestion(text: String(text.prefix(500))))
        }
    }

    mutating func merge(_ output: CoachOutput, batch: CoachBatch) {
        let summary = output.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { self.summary = ChineseScript.toSimplified(String(summary.prefix(4000))) }
        nextSeq = batch.nextSeq
        offset = batch.offset
        for candidate in output.questions.prefix(10) {
            guard let line = batch.lines.first(where: { $0.seq == candidate.segment }) else { continue }
            let text = ChineseScript.toSimplified(String(candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)))
            guard !Self.key(text).isEmpty else { continue }
            if let index = questions.firstIndex(where: { Self.similar($0.text, text) }) {
                // 只补充待问问题的依据，不能覆盖用户标记或重新激活已处理问题。
                if questions[index].status == .pending && questions[index].time == nil {
                    questions[index].reason = ChineseScript.toSimplified(String(candidate.reason.prefix(300)))
                    questions[index].time = line.start
                    questions[index].quote = String(line.text.prefix(240))
                }
                continue
            }
            guard questions.count < 100 else { continue }
            questions.append(CoachQuestion(text: text, reason: ChineseScript.toSimplified(String(candidate.reason.prefix(300))),
                                           time: line.start, quote: String(line.text.prefix(240)),
                                           priority: min(3, max(1, candidate.priority))))
        }
    }

    static func key(_ text: String) -> String {
        ChineseScript.toSimplified(text).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let x = key(a), y = key(b)
        if x == y { return true }
        guard min(x.count, y.count) >= 6 else { return false }
        func pairs(_ s: String) -> Set<String> {
            let chars = Array(s)
            return Set((0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) })
        }
        let xs = pairs(x), ys = pairs(y)
        return Double(xs.intersection(ys).count) / Double(xs.union(ys).count) >= 0.75
    }

    /// 给会后整理的非事实参考；不把会前计划写进逐字稿。
    var notesReference: String {
        var lines = ["Meeting preparation and suggested questions (context only, not facts).",
                     "Only the transcript establishes what happened. Asked does not mean answered. Keep unanswered relevant questions in openQuestions.",
                     "Background: \(preparation.background)", "Goals: \(preparation.goals)", "My role and concerns: \(preparation.role)"]
        lines += questions.filter { $0.status != .ignored }.map { "[\($0.status.rawValue)] \($0.text)" }
        return lines.joined(separator: "\n")
    }
}

struct CoachLine: Codable, Equatable {
    var seq: Int
    var start: Double
    var text: String
}

struct CoachBatch: Equatable {
    var lines: [CoachLine] = []
    var nextSeq: Int
    var offset: Int

    init(lines: [CoachLine], state: MeetingAssistance, limit: Int = 12000) {
        nextSeq = state.nextSeq
        offset = state.offset
        var remaining = max(1, limit)
        for line in lines.sorted(by: { $0.seq < $1.seq }) where line.seq >= state.nextSeq {
            let skip = line.seq == state.nextSeq ? state.offset : 0
            let rest = line.text.dropFirst(skip)
            let text = String(rest.prefix(remaining))
            if !text.isEmpty {
                self.lines.append(CoachLine(seq: line.seq, start: line.start, text: text))
                remaining -= text.count
            }
            if text.count == rest.count {
                nextSeq = line.seq + 1
                offset = 0
            } else {
                nextSeq = line.seq
                offset = skip + text.count
            }
            if remaining == 0 { break }
        }
    }
}

struct CoachOutput: Codable {
    struct Question: Codable {
        var text: String
        var reason: String
        var segment: Int
        var priority: Int
    }
    var summary: String
    var questions: [Question]
}
