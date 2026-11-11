import Foundation

/// 校稿时用户的一题回答
struct ReviewAnswer: Codable, Hashable {
    var time: String
    var question: String
    var answer: String
}

/// 整理需要的材料
struct NotesContext {
    var meeting: Meeting
    var segments: [Segment]
    var speakers: [Int: String]
    var bookmarks: [Bookmark]
    var glossary: [String]
    var template: TemplateDefinition
    /// 会议参考资料（design §39.3、R61.5）；没有文档时提示词跟以前一字不差
    var documents: [DocumentText] = []
    var assistance: String = ""
}

/// 整理与校稿的提示词（design §8.3），规则沿用第二版；依会议语言分成中文、英文、日文三份（design §16.5、§18.4）
enum NotesPrompt {
    /// documents：有参考文档时接上文档的规则（design §39.3、D133）。语言的两级（design §41.2、D140、D141）：
    /// 共用别的语言那份的精调语言（粤语）最后接一段逐字稿的说明；一般语言（韩文）用英文那份、改成用那个语言写
    static func system(_ language: MeetingLanguage, documents: Bool = false) -> String {
        var text = language.prompt(zh: systemChinese, en: systemEnglish, ja: systemJapanese)
        if language.profile.tier == .general, let name = language.profile.outputName {
            text = text.replacingOccurrences(of: "written entirely in English.", with: "written entirely in \(name).")
                .replacingOccurrences(of: "(translated into English if it is not in English)", with: "(translated into \(name) if it is not in \(name))")
        }
        if documents { text += "\n" + DocumentPrompt.notesRules(language) }
        if let note = language.profile.transcriptNote?.notes { text += "\n\n" + note }
        if language.profile.tier == .general, let name = language.profile.outputName {
            text += "\n\nOutput language: \(name). Every text value in the JSON (title, summary, decisions, action items, open questions, "
                + "topics, custom sections, review questions) must be in \(name); keep the JSON keys and the time format as they are."
        }
        return text
    }

    static let systemChinese = """
    你是会议记录整理者。根据用户提供的会议逐字稿，整理成结构化的会议记录，一律使用简体中文（大陆用语）。

    规则：
    1. 只根据逐字稿与用户笔记撰写，不要补充没有提到的信息。
    2. 逐字稿来自语音识别，英文术语、人名、缩写常被听错（同一个词可能出现好几种写法）。请依上下文和词汇表推断正确写法，但凡是推断出来的专有名词、人名，一定要列进 reviewItems 让用户确认。
    3. 每一条记录（summary、decisions、actionItems、openQuestions、topics 的 points、custom 的 items）都要填 time：该内容在逐字稿中出现的时间点，写成 mm:ss（例如 03:15，超过一小时写 1:03:15），不要加括号。综合多处的内容，填最主要的那一处。
    4. 逐字稿每行标有说话者。actionItems 的 owner 只填明确提到的负责人，优先使用说话者的名字；不明确就留空字符串并列进 reviewItems。
    5. actionItems 的 due 依提示中的「会议日期」换算成 yyyy-MM-dd（例如「下周三」要依会议日期和星期几推算，星期几要算对）；没提到期限就留空字符串，提到但不明确就留空并列进 reviewItems。
    6. reviewItems 最多 8 题，相近的问题要合并；只问会影响记录正确性的地方：专有名词、人名、负责人、期限、方案内容。每题的 time 填相关段落的时间点。能用「是」或「不是」回答的题目（例如「负责人是小田切吗？」）写成是非题，yesNo 填 true；要用户说出答案的（例如「这个系统的正确名称是什么？」）yesNo 填 false。
    7. 「用户笔记」与「重点标记」代表用户自己认为重要的内容，必须纳入记录；笔记里逐字稿没有的信息也可以写入，但不要改变原意。
    8. 依「模板」只产生指定的段落，没指定的段落给空数组。custom 依模板的自订段落顺序产生，title 用模板给的段落名称。
    9. topics 依议题分段，start 填该议题开始的时间点。
    10. title：提示中有「现有标题」就原样回传；没有就依内容取一个 20 字以内的标题。
    11. 时间点格式一律是 mm:ss，超过一小时用 h:mm:ss，与逐字稿相同。没有时间信息时填空字符串。
    """

    static let systemEnglish = """
    You write meeting notes. Based on the meeting transcript the user provides, produce structured meeting notes, written entirely in English.

    Rules:
    1. Write only from the transcript and the user's notes. Do not add information that was not mentioned.
    2. The transcript comes from speech recognition, so technical terms, names and abbreviations are often misheard (the same word may appear spelled several ways). Infer the correct spelling from context and the glossary, but every proper noun or name you inferred must be listed in reviewItems for the user to confirm.
    3. Every item (summary, decisions, actionItems, openQuestions, the points in topics, the items in custom) must have a time: when that content appears in the transcript, written as mm:ss (for example 03:15; over an hour, 1:03:15), without brackets. If it combines several places, use the main one.
    4. Each transcript line is labeled with a speaker. For actionItems, owner is only someone explicitly named as responsible, preferring the speaker's name; if it is unclear, leave an empty string and add it to reviewItems.
    5. For actionItems, convert due to yyyy-MM-dd based on the "Meeting date" in the prompt (for example, "next Wednesday" must be worked out from the meeting date and its weekday, and the weekday must be right). If no deadline is mentioned, leave an empty string; if one is mentioned but unclear, leave it empty and add it to reviewItems.
    6. At most 8 reviewItems; merge similar questions. Only ask about things that affect accuracy: proper nouns, names, owners, deadlines, details of a proposal. Each item's time is the related part of the transcript. If a question can be answered with yes or no (for example, "Is Odagiri the owner?"), write it as a yes/no question and set yesNo to true; if the user has to supply the answer (for example, "What is the correct name of this system?"), set yesNo to false.
    7. "User notes" and "Bookmarks" mark what the user considers important and must be included. Information in the notes that is not in the transcript may be included, without changing its meaning.
    8. Produce only the sections specified by the "Template"; give empty arrays for the others. Produce custom in the order of the template's custom sections, with title as given by the template (translated into English if it is not in English).
    9. Split topics by subject; start is the time the topic begins.
    10. title: if the prompt gives an "Existing title", return it unchanged; otherwise write a title of at most 10 words.
    11. Times are always mm:ss, or h:mm:ss over an hour, the same as the transcript. Use an empty string when there is no time information.
    """

    static let systemJapanese = """
    あなたは議事録の作成者です。ユーザーが提供する会議の文字起こしをもとに、構造化された議事録を作成します。すべて日本語で書いてください。

    ルール：
    1. 文字起こしとユーザーのメモだけをもとに書き、言及されていない情報を補わないこと。
    2. 文字起こしは音声認識によるもので、専門用語、人名、略語がよく聞き間違えられている（同じ語が何通りもの表記で出てくることがある）。文脈と用語集から正しい表記を推測すること。ただし、推測した固有名詞や人名は必ず reviewItems に入れ、ユーザーに確認してもらうこと。
    3. すべての項目（summary、decisions、actionItems、openQuestions、topics の points、custom の items）に time を入れること。その内容が文字起こしに出てくる時刻を mm:ss（例：03:15。1 時間を超える場合は 1:03:15）で書き、括弧は付けない。複数の箇所をまとめた内容は、主な箇所の時刻にする。
    4. 文字起こしの各行には話者が付いている。actionItems の owner は担当者として明示された人だけを入れ、話者の名前を優先する。はっきりしない場合は空文字列にして reviewItems に入れる。
    5. actionItems の due は、プロンプトの「会議日」をもとに yyyy-MM-dd に換算する（例：「来週の水曜」は会議日とその曜日から計算し、曜日を正しく数えること）。期限の言及がなければ空文字列、言及があっても曖昧なら空文字列にして reviewItems に入れる。
    6. reviewItems は最大 8 問。似た質問はまとめる。記録の正確さに関わる点（固有名詞、人名、担当者、期限、案の内容）だけを質問する。各問の time は関連する箇所の時刻。「はい」か「いいえ」で答えられる質問（例：「担当者は小田切さんですか？」）はその形で書いて yesNo を true にする。答えを書いてもらう必要がある質問（例：「このシステムの正しい名前は？」）は yesNo を false にする。
    7. 「ユーザーのメモ」と「ブックマーク」はユーザーが重要だと考えた内容なので、必ず記録に含める。メモにあって文字起こしにない情報も書いてよいが、意味を変えないこと。
    8. 「テンプレート」で指定されたセクションだけを作成し、指定のないセクションは空配列にする。custom はテンプレートのカスタムセクションの順に作成し、title はテンプレートのセクション名を使う（日本語でなければ日本語に訳す）。
    9. topics は議題ごとに分け、start に議題が始まる時刻を入れる。
    10. title：プロンプトに「既存のタイトル」があればそのまま返す。なければ内容から 30 文字以内のタイトルを付ける。
    11. 時刻の形式は常に mm:ss、1 時間を超える場合は h:mm:ss で、文字起こしと同じにする。時刻の情報がない場合は空文字列にする。
    12. 文体は簡潔な常体（である調）か体言止めにする。
    """

    /// 提示词里的字段名称
    private struct Labels {
        var meetingDate, existingTitle, participants, notProvided, glossary, none, template, sections, custom, extra: String
        var userNotes, bookmarks, transcript, currentNotes, answers, answer, reviseInstructions, listSeparator, colon: String
        var section: (String, String) -> String

        static let zh = Labels(
            meetingDate: "会议日期", existingTitle: "现有标题", participants: "与会者", notProvided: "未提供",
            glossary: "词汇表（正确写法）", none: "无", template: "模板", sections: "要产生的段落",
            custom: "自订段落（放在 custom，依序）", extra: "额外指示",
            userNotes: "用户笔记（[时间] 是做笔记时的录音时间）", bookmarks: "重点标记",
            transcript: "逐字稿（[时间] 说话者：内容，标 (?) 的是识别信心低的段落）",
            currentNotes: "目前的会议记录（JSON）", answers: "用户对待确认题目的回答", answer: "回答",
            reviseInstructions: """

            请依用户的回答修正会议记录后，回传完整的会议记录：
            - 依回答修正所有相关内容（摘要、决议、待办、未决问题、议题、自订段落、标题都要一并检查），时间点维持不变。
            - 已回答的题目从 reviewItems 移除；目前会议记录里没被回答的题目原样保留。
            - 除非回答本身带出新的疑点，否则不要添加题目。
            """,
            listSeparator: "、", colon: "：",
            section: { id, label in "\(id)（\(label)）" })

        static let en = Labels(
            meetingDate: "Meeting date", existingTitle: "Existing title", participants: "Participants", notProvided: "not provided",
            glossary: "Glossary (correct spellings)", none: "none", template: "Template", sections: "Sections to produce",
            custom: "Custom sections (in custom, in this order)", extra: "Additional instructions",
            userNotes: "User notes ([time] is the recording time when the note was taken)", bookmarks: "Bookmarks",
            transcript: "Transcript ([time] speaker: text; (?) marks low-confidence segments)",
            currentNotes: "Current meeting notes (JSON)", answers: "The user's answers to the review questions", answer: "Answer",
            reviseInstructions: """

            Revise the meeting notes according to the user's answers and return the complete notes:
            - Fix everything related to each answer (check the summary, decisions, action items, open questions, topics, custom sections and title), keeping the times unchanged.
            - Remove answered questions from reviewItems; keep unanswered questions from the current notes as they are.
            - Do not add new questions unless an answer raises a new doubt.
            """,
            listSeparator: ", ", colon: ": ",
            section: { id, label in "\(id) (\(label))" })

        static let ja = Labels(
            meetingDate: "会議日", existingTitle: "既存のタイトル", participants: "参加者", notProvided: "未記入",
            glossary: "用語集（正しい表記）", none: "なし", template: "テンプレート", sections: "作成するセクション",
            custom: "カスタムセクション（custom に順番どおり）", extra: "追加の指示",
            userNotes: "ユーザーのメモ（[時刻] はメモを取ったときの録音時刻）", bookmarks: "ブックマーク",
            transcript: "文字起こし（[時刻] 話者：内容。(?) は認識の信頼度が低い部分）",
            currentNotes: "現在の議事録（JSON）", answers: "確認事項へのユーザーの回答", answer: "回答",
            reviseInstructions: """

            ユーザーの回答にもとづいて議事録を修正し、議事録全体を返してください：
            - 回答に関係する内容をすべて修正する（要約、決定事項、ToDo、未決事項、議題、カスタムセクション、タイトルをすべて確認する）。時刻は変えない。
            - 回答済みの質問は reviewItems から削除し、現在の議事録にある未回答の質問はそのまま残す。
            - 回答そのものが新しい疑問を生まない限り、質問を追加しない。
            """,
            listSeparator: "、", colon: "：",
            section: { id, label in "\(id)（\(label)）" })

        static func of(_ language: MeetingLanguage) -> Labels {
            switch language.base {
            case .zh: return zh
            case .en: return en
            case .ja: return ja
            }
        }
    }

    static func summarize(_ c: NotesContext) -> String {
        let m = c.meeting
        let language = m.meetingLanguage
        let l = Labels.of(language)
        var lines: [String] = []
        let weekday = DateText.weekday(m.meetingDate, language: language)
        lines.append("\(l.meetingDate)\(l.colon)\(m.meetingDate)" + (language.base == .en ? " (\(weekday))" : "（\(weekday)）"))
        lines.append("\(l.existingTitle)\(l.colon)\(m.titleLocked ? m.title : "")")
        let participants = m.participantList
        lines.append("\(l.participants)\(l.colon)\(participants.isEmpty ? l.notProvided : participants.joined(separator: l.listSeparator))")
        lines.append("\(l.glossary)\(l.colon)\(c.glossary.isEmpty ? l.none : c.glossary.joined(separator: l.listSeparator))")
        lines.append("")
        lines.append("\(l.template)\(l.colon)\(c.template.description)")
        let sectionNames = TemplateDefinition.builtinSectionIDs.filter { c.template.includes($0) }
            .map { l.section($0, TemplateDefinition.sectionLabel($0, language: language, prompt: true)) }
        lines.append("\(l.sections)\(l.colon)\(sectionNames.joined(separator: l.listSeparator))")
        if !c.template.custom.isEmpty {
            lines.append("\(l.custom)\(l.colon)")
            for spec in c.template.custom { lines.append("- \(spec.title)\(l.colon)\(spec.instruction)") }
        }
        if !c.template.instruction.isEmpty { lines.append("\(l.extra)\(l.colon)\(c.template.instruction)") }
        let notes = m.userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            lines.append("")
            lines.append("\(l.userNotes)\(l.colon)")
            lines.append(notes)
        }
        if !c.assistance.isEmpty {
            lines.append("")
            lines.append(c.assistance)
        }
        if !c.bookmarks.isEmpty {
            lines.append("")
            lines.append("\(l.bookmarks)\(l.colon)" + c.bookmarks.map { TimeFormat.string($0.time) + ($0.label.isEmpty ? "" : " \($0.label)") }
                .joined(separator: l.listSeparator))
        }
        if !c.documents.isEmpty {
            lines.append("")
            lines.append(DocumentPrompt.block(c.documents, language: language))
        }
        lines.append("")
        lines.append("\(l.transcript)\(l.colon)")
        for s in c.segments {
            let speaker = s.speaker.map { (c.speakers[$0] ?? language.defaultSpeaker($0)) + l.colon } ?? ""
            lines.append("[\(TimeFormat.string(s.start))] \(speaker)\(s.lowConfidence ? "(?) " : "")\(s.text)")
        }
        return lines.joined(separator: "\n")
    }

    static func revise(_ c: NotesContext, notes: MeetingNotes, answers: [ReviewAnswer]) -> String {
        let l = Labels.of(c.meeting.meetingLanguage)
        var text = summarize(c)
        text += "\n\n\(l.currentNotes)\(l.colon)\n" + notes.jsonString()
        text += "\n\n\(l.answers)\(l.colon)\n"
        for (i, a) in answers.enumerated() {
            text += "\(i + 1). [\(a.time)] \(a.question)\n   \(l.answer)\(l.colon)\(a.answer)\n"
        }
        text += l.reviseInstructions
        return text
    }
}
