// 简体输出回归检查（design §45），不启动 app、不访问用户数据或模型。
// swiftc Sources/Shiyin/Transcribe/ChineseScript.swift Sources/Shiyin/Model/MeetingLanguage.swift \
//   Sources/Shiyin/Model/MeetingNotes.swift Sources/Shiyin/Services/ReleaseNotes.swift \
//   scripts/dev/simplified-check.swift -o /tmp/shiyin-simplified-check
// /tmp/shiyin-simplified-check
import Foundation

@main
enum SimplifiedCheck {
    static func main() throws {
        var checks = 0
        func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
            guard actual == expected else {
                fatalError("\(label)：实际 \(actual)，预期 \(expected)")
            }
            checks += 1
        }

        // 字形、台湾用词、已经是简体的台湾用词、容易误转的多音字。
        let cases = [
            ("軟體、資料庫、預設、網路、記憶體、投影片、複製、錄音、會議紀錄。",
             "软件、数据库、默认、网络、内存、幻灯片、复制、录音、会议记录。"),
            ("软体、资料库、预设、网路、记忆体、投影片、复制。",
             "软件、数据库、默认、网络、内存、幻灯片、复制。"),
            ("乾燥的頭髮，皇后在後台；開發 Redis API v2。",
             "干燥的头发，皇后在后台；开发 Redis API v2。"),
            ("[1:03:15] 確認 API v2：https://example.com/a?b=1", "[1:03:15] 确认 API v2：https://example.com/a?b=1"),
            ("", ""),
        ]
        for (input, expected) in cases {
            equal(MeetingLanguage.zh.outputScript(input), expected, "中文转换")
            equal(ChineseScript.toSimplified(expected), expected, "转换幂等")
        }
        let yue = MeetingLanguage(rawValue: "yue")!
        equal(yue.outputScript("廣東話嘅會議紀錄"), "广东话嘅会议记录", "粤语转换")
        for language in [MeetingLanguage.ja, .en, MeetingLanguage(rawValue: "ko")!] {
            let mixed = "会議の資料：開発の進捗、質疑応答。회의 자료 Redis API v2"
            equal(language.outputScript(mixed), mixed, "非中文逐字稿保持原文")
        }
        equal(MeetingLanguage.zh.speechLocale.identifier, "zh_CN", "中文识别区域")
        equal(MeetingLanguage.zh.profile.fonts.titleMac, "Songti SC", "中文标题字体")

        // 模型返回繁体时，所有记录字段都转简体；时间、期限、确认题型保留。
        let notes = MeetingNotes(
            title: "會議紀錄", summary: [.init(text: "軟體開發", time: "00:05")],
            decisions: [.init(text: "預設啟用", time: "00:10")],
            actionItems: [.init(owner: "陳經理", task: "確認資料庫", due: "2026-11-11", time: "00:15")],
            openQuestions: [.init(text: "還有問題", time: "00:20")],
            topics: [.init(title: "網路", start: "00:25", points: [.init(text: "記憶體", time: "00:30")])],
            custom: [.init(title: "回饋", items: [.init(text: "投影片", time: "00:35")])],
            reviewItems: [.init(time: "00:40", question: "確認時程？", yesNo: true)])
        let expected = MeetingNotes(
            title: "会议记录", summary: [.init(text: "软件开发", time: "00:05")],
            decisions: [.init(text: "默认启用", time: "00:10")],
            actionItems: [.init(owner: "陈经理", task: "确认数据库", due: "2026-11-11", time: "00:15")],
            openQuestions: [.init(text: "还有问题", time: "00:20")],
            topics: [.init(title: "网络", start: "00:25", points: [.init(text: "内存", time: "00:30")])],
            custom: [.init(title: "反馈", items: [.init(text: "幻灯片", time: "00:35")])],
            reviewItems: [.init(time: "00:40", question: "确认时程？", yesNo: true)])
        equal(notes.outputScript(.zh), expected, "记录字段和元数据")
        equal(notes.outputScript(yue), expected, "粤语记录")
        for language in [MeetingLanguage.ja, .en, MeetingLanguage(rawValue: "ko")!] {
            equal(notes.outputScript(language), notes, "非中文记录保持原文")
        }
        let release = "拾音 4.7\n- 軟體更新與會議紀錄\n\nShiyin 4.7\n- Software update and meeting notes"
        equal(ReleaseNotes.text(release, english: false), "• 软件更新与会议记录", "旧版更新说明显示简体")
        equal(ReleaseNotes.text(release, english: true), "• Software update and meeting notes", "英文更新说明保持原文")
        print("简体输出检查通过：\(checks) 项")
    }
}
