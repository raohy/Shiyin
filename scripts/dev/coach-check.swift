// 会中提问助手的纯逻辑回归，不使用用户数据和真实模型。
// swiftc Sources/Shiyin/Transcribe/ChineseScript.swift Sources/Shiyin/Model/MeetingAssistance.swift \
//   Sources/Shiyin/Notes/MeetingCoachPrompt.swift scripts/dev/coach-check.swift -o /tmp/shiyin-coach-check
import Foundation

@main
enum CoachCheck {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError(label) }
            checks += 1
        }
        let preparation = MeetingPreparation(background: "供应商交付评审", goals: "确认范围、费用和日期", role: "采购方",
                                             initialQuestions: "接口费用何时确认？\n接口費用何時確認?\n谁负责验收？", enabled: true)
        var state = MeetingAssistance(preparation: preparation)
        state.seedQuestions()
        check(state.questions.count == 2, "初始问题繁简与标点去重")
        let firstId = state.questions[0].id
        state.questions[0].status = .asked
        let lines = [CoachLine(seq: 0, start: 12, text: "月底交付，接口需要单独评估。")]
        let batch = CoachBatch(lines: lines, state: state)
        state.merge(CoachOutput(summary: "接口尚待評估。", questions: [
            .init(text: "接口費用何時確認？", reason: "費用不明", segment: 0, priority: 1),
            .init(text: "交付范围包含接口吗？", reason: "接口需另外評估", segment: 0, priority: 1),
            .init(text: "没有出处的问题？", reason: "", segment: 99, priority: 2),
            .init(text: "？！", reason: "", segment: 0, priority: 2)]), batch: batch)
        check(state.questions.count == 3, "丢弃无效出处和空问题")
        check(state.questions[0].id == firstId && state.questions[0].status == .asked, "已问问题不得复活或换 id")
        check(state.summary == "接口尚待评估。", "摘要转简体")
        check(state.questions[2].reason == "接口需另外评估", "提问理由转简体")
        check(state.questions[2].time == 12 && state.questions[2].quote == lines[0].text, "依据来自真实输入")
        check(state.nextSeq == 1 && state.offset == 0, "已消费游标")
        check(state.pending.count == 2, "只展示待问")

        var longState = MeetingAssistance()
        let longText = String(repeating: "项目👨‍👩‍👧‍👦", count: 5000)
        let longLines = [CoachLine(seq: 0, start: 0, text: longText), CoachLine(seq: 1, start: 60, text: "最后一段")]
        let a = CoachBatch(lines: longLines, state: longState)
        check(a.lines.map(\.text).joined().count == 12000 && a.nextSeq == 0 && a.offset == 12000, "长段按字符分批")
        longState.merge(CoachOutput(summary: "", questions: []), batch: a)
        let b = CoachBatch(lines: longLines, state: longState)
        check(a.lines[0].text + b.lines[0].text == longText, "长段不丢字不重复")
        check(b.nextSeq == 2 && b.offset == 0, "长段后继续消费后续段落")
        longState.merge(CoachOutput(summary: "", questions: []), batch: b)
        check(CoachBatch(lines: longLines, state: longState).lines.isEmpty, "无新增不重复消费")

        state.questions[2].status = .ignored
        state.merge(CoachOutput(summary: "", questions: [.init(text: "交付范围包含接口吗", reason: "再次建议", segment: 0, priority: 1)]), batch: batch)
        check(state.questions.count == 3 && state.questions[2].status == .ignored, "忽略的问题不得复活")
        check(MeetingAssistance.similar("请问这次项目交付的具体日期是什么？", "请问这次项目交付的具体日期是什么时候？"), "近似问题去重")
        check(!MeetingAssistance.similar("费用多少？", "谁负责验收？"), "不同问题保留")
        let decoded = try JSONDecoder().decode(MeetingAssistance.self, from: JSONEncoder().encode(state))
        check(decoded == state, "持久化往返保留状态")
        let prompt = try MeetingCoachPrompt.input(state: state, batch: batch)
        check(prompt.contains("newTranscript") && prompt.contains("asked") && prompt.contains("ignored"), "模型获得已处理问题状态")
        check(state.notesReference.contains("Asked does not mean answered") && !state.notesReference.contains("交付范围包含接口吗"), "会后上下文不把建议当事实并排除忽略问题")
        var limited = state
        limited.preparation.background = String(repeating: "字", count: 5000)
        check(limited.preparation.bounded.background.count == 4000, "会前内容长度上限")
        print("会中提问助手检查通过：\(checks) 项")
    }
}
