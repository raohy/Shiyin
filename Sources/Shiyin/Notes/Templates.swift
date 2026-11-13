import Foundation

/// 模板的内容（design §8.2）
struct TemplateDefinition: Codable, Hashable {
    struct CustomSpec: Codable, Hashable {
        var title: String
        var instruction: String
    }

    /// 内置段落：summary、decisions、actionItems、openQuestions、topics
    static let builtinSectionIDs = ["summary", "decisions", "actionItems", "openQuestions", "topics"]

    /// 段落名称：界面用界面语言，提示词用会议语言（design §16.5）
    /// prompt：提示词里用（一般语言不查字符串表，design §41.1）
    static func sectionLabel(_ id: String, language: MeetingLanguage, prompt: Bool = false) -> String {
        let pick = prompt ? language.prompt : language.text
        switch id {
        case "summary": return pick("摘要", "Summary", "要約")
        case "decisions": return pick("决议", "Decisions", "決定事項")
        case "actionItems": return pick("待办", "Action items", "ToDo")
        case "openQuestions": return pick("未决问题", "Open questions", "未決事項")
        default: return pick("议题详细", "Topics", "議題ごとの詳細")
        }
    }

    /// 设置画面用的段落清单（界面语言）
    static var builtinSections: [(id: String, label: String)] {
        builtinSectionIDs.map { ($0, MeetingLanguage.ui(zh: sectionLabel($0, language: .zh), en: sectionLabel($0, language: .en))) }
    }

    var description: String
    var sections: [String]
    var custom: [CustomSpec]
    var instruction: String

    func includes(_ section: String) -> Bool { sections.contains(section) }

    /// 每一段文字都套用 transform（简体界面显示内置模板用）
    func mappingText(_ r: (String) -> String) -> TemplateDefinition {
        TemplateDefinition(description: r(description), sections: sections,
                           custom: custom.map { CustomSpec(title: r($0.title), instruction: r($0.instruction)) }, instruction: r(instruction))
    }

    static func decode(_ json: String) -> TemplateDefinition {
        (try? JSONDecoder().decode(TemplateDefinition.self, from: Data(json.utf8)))
            ?? TemplateDefinition(description: "", sections: builtinSectionIDs, custom: [], instruction: "")
    }

    func jsonString() -> String {
        String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "{}"
    }
}

/// 内置模板（R6.2）。中文版启动时写进数据库，名称或内容改了就覆盖；英文版、日文版不存，依 id 取用（design §16.5、§18.4）。
enum BuiltinTemplates {
    static let all: [(id: String, name: String, definition: TemplateDefinition)] = [
        ("general", "一般会议", TemplateDefinition(
            description: "周会、项目会议、讨论会：摘要、决议、待办、未决问题、议题",
            sections: ["summary", "decisions", "actionItems", "openQuestions", "topics"], custom: [], instruction: "")),
        ("one-on-one", "一对一", TemplateDefinition(
            description: "主管与成员的一对一会谈",
            sections: ["summary", "actionItems", "openQuestions"],
            custom: [.init(title: "近况与进展", instruction: "对方最近在做的事、进度与卡关的地方"),
                     .init(title: "反馈", instruction: "双方给彼此的反馈，标明是谁给谁"),
                     .init(title: "需要的支持", instruction: "对方提出需要协助或资源的地方")],
            instruction: "这是一对一会谈，语气保持中性，不要评价个人。")),
        ("interview", "访谈", TemplateDefinition(
            description: "用户访谈、专家访谈、面试",
            sections: ["summary", "topics"],
            custom: [.init(title: "受访者背景", instruction: "受访者的角色、经历、使用情境"),
                     .init(title: "重点引述", instruction: "保留受访者的原话，每条一句，附时间点"),
                     .init(title: "洞察与机会", instruction: "从访谈内容归纳出的需求、痛点与机会")],
            instruction: "这是访谈，重点是受访者说了什么，不要把访谈者的推测写成受访者的意见。")),
        ("lecture", "课堂／演讲", TemplateDefinition(
            description: "课程、演讲、分享会、教育训练",
            sections: ["summary", "topics", "openQuestions"],
            custom: [.init(title: "重点概念", instruction: "提到的重要概念、名词与解释"),
                     .init(title: "问答", instruction: "听众的提问与讲者的回答")],
            instruction: "这是课堂或演讲，依讲者的段落整理大纲。")),
        ("brainstorm", "脑力激荡", TemplateDefinition(
            description: "发想会议、工作坊",
            sections: ["summary", "decisions", "actionItems"],
            custom: [.init(title: "点子清单", instruction: "每个点子一条，尽量标出是谁提出的"),
                     .init(title: "评估与取舍", instruction: "对点子的讨论、优缺点与取舍理由")],
            instruction: "这是脑力激荡，不要遗漏任何被提出的点子，即使没有被采纳。")),
    ]

    /// 英文版：英文会议整理时用，英文界面也显示这里的名称和说明
    static let english: [String: (name: String, definition: TemplateDefinition)] = [
        "general": ("General meeting", TemplateDefinition(
            description: "Team meetings, project meetings, discussions: summary, decisions, action items, open questions, topics",
            sections: ["summary", "decisions", "actionItems", "openQuestions", "topics"], custom: [], instruction: "")),
        "one-on-one": ("One-on-one", TemplateDefinition(
            description: "A one-on-one between a manager and a team member",
            sections: ["summary", "actionItems", "openQuestions"],
            custom: [.init(title: "Updates and progress", instruction: "What they have been working on, progress and blockers"),
                     .init(title: "Feedback", instruction: "Feedback both ways, noting who gave it to whom"),
                     .init(title: "Support needed", instruction: "Where they asked for help or resources")],
            instruction: "This is a one-on-one. Keep a neutral tone and do not judge the person.")),
        "interview": ("Interview", TemplateDefinition(
            description: "User interviews, expert interviews, job interviews",
            sections: ["summary", "topics"],
            custom: [.init(title: "Interviewee background", instruction: "The interviewee's role, experience and context"),
                     .init(title: "Key quotes", instruction: "Keep the interviewee's own words, one quote per item, with its time"),
                     .init(title: "Insights and opportunities", instruction: "Needs, pain points and opportunities drawn from the interview")],
            instruction: "This is an interview. Focus on what the interviewee said; do not present the interviewer's assumptions as the interviewee's opinions.")),
        "lecture": ("Lecture / talk", TemplateDefinition(
            description: "Courses, talks, sharing sessions, training",
            sections: ["summary", "topics", "openQuestions"],
            custom: [.init(title: "Key concepts", instruction: "Important concepts, terms and explanations that came up"),
                     .init(title: "Q&A", instruction: "Questions from the audience and the speaker's answers")],
            instruction: "This is a lecture or talk. Outline it following the speaker's sections.")),
        "brainstorm": ("Brainstorm", TemplateDefinition(
            description: "Ideation meetings, workshops",
            sections: ["summary", "decisions", "actionItems"],
            custom: [.init(title: "Ideas", instruction: "One idea per item, noting who proposed it where possible"),
                     .init(title: "Evaluation and trade-offs", instruction: "Discussion of the ideas, pros and cons, and the reasons for each choice")],
            instruction: "This is a brainstorm. Do not leave out any idea that was raised, even if it was not adopted.")),
    ]

    /// 日文版：日文会议整理时用（没有日文界面，名称不会显示）
    static let japanese: [String: TemplateDefinition] = [
        "general": TemplateDefinition(
            description: "定例会議、プロジェクト会議、打ち合わせ：要約、決定事項、ToDo、未決事項、議題",
            sections: ["summary", "decisions", "actionItems", "openQuestions", "topics"], custom: [], instruction: ""),
        "one-on-one": TemplateDefinition(
            description: "上司とメンバーの1on1",
            sections: ["summary", "actionItems", "openQuestions"],
            custom: [.init(title: "近況と進捗", instruction: "相手が最近取り組んでいること、進捗、困っていること"),
                     .init(title: "フィードバック", instruction: "双方からのフィードバック。誰から誰へのものかを明記する"),
                     .init(title: "必要なサポート", instruction: "相手が求めた支援やリソース")],
            instruction: "これは1on1です。中立的な書き方にし、個人を評価しないこと。"),
        "interview": TemplateDefinition(
            description: "ユーザーインタビュー、専門家インタビュー、面接",
            sections: ["summary", "topics"],
            custom: [.init(title: "回答者の背景", instruction: "回答者の役割、経歴、利用状況"),
                     .init(title: "主な発言", instruction: "回答者の言葉をそのまま残す。1項目に1つの発言、時刻付き"),
                     .init(title: "気づきと機会", instruction: "インタビューから読み取れるニーズ、課題、機会")],
            instruction: "これはインタビューです。回答者が何を言ったかを中心にし、聞き手の推測を回答者の意見として書かないこと。"),
        "lecture": TemplateDefinition(
            description: "授業、講演、勉強会、研修",
            sections: ["summary", "topics", "openQuestions"],
            custom: [.init(title: "重要な概念", instruction: "出てきた重要な概念、用語とその説明"),
                     .init(title: "質疑応答", instruction: "聴衆からの質問と講師の回答")],
            instruction: "これは授業または講演です。講師の話の流れに沿って要点をまとめること。"),
        "brainstorm": TemplateDefinition(
            description: "アイデア出しの会議、ワークショップ",
            sections: ["summary", "decisions", "actionItems"],
            custom: [.init(title: "アイデア一覧", instruction: "1項目に1つのアイデア。できるだけ誰が出したかを書く"),
                     .init(title: "評価と取捨選択", instruction: "アイデアについての議論、長所と短所、選んだ理由")],
            instruction: "これはブレインストーミングです。採用されなかったものも含め、出たアイデアを漏らさないこと。"),
    ]

    static func seed(_ db: AppDatabase) {
        let existing = Dictionary(uniqueKeysWithValues: ((try? db.templates()) ?? []).map { ($0.id, $0) })
        for template in all {
            let json = template.definition.jsonString()
            if let current = existing[template.id], current.name == template.name, current.definition == json { continue }
            try? db.saveTemplate(TemplateRecord(id: template.id, name: template.name, builtin: true, definition: json))
        }
    }
}

extension TemplateRecord {
    /// 界面上显示的名称：内置模板跟着界面语言（简体界面执行时转，design §48.2），自订模板照用户取的名字
    var displayName: String {
        guard builtin else { return name }
        if MeetingLanguage.interface == .en, let english = BuiltinTemplates.english[id] { return english.name }
        return MeetingLanguage.simplifiedInterface ? ChineseScript.toSimplifiedUI(name) : name
    }

    /// 界面上显示的说明
    var displayDescription: String {
        if builtin, MeetingLanguage.interface == .en, let english = BuiltinTemplates.english[id] { return english.definition.description }
        let description = TemplateDefinition.decode(definition).description
        return builtin && MeetingLanguage.simplifiedInterface ? ChineseScript.toSimplifiedUI(description) : description
    }

    /// 整理时用的内容：内置模板跟着会议语言，自订模板照用户写的
    func definition(for language: MeetingLanguage) -> TemplateDefinition {
        // 依语言用哪一份（design §41.2）：一般语言用英文版，粤语用中文版
        if builtin, language.base == .en, let english = BuiltinTemplates.english[id] { return english.definition }
        if builtin, language.base == .ja, let japanese = BuiltinTemplates.japanese[id] { return japanese }
        return TemplateDefinition.decode(definition)
    }
}
