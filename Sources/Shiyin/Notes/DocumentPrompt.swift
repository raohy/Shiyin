import Foundation

/// 送给整理工具的一份参考文档（design §39.3）：名称去掉扩展名，照加入的顺序
struct DocumentText: Equatable {
    var name: String
    var kind: DocumentKind
    var pages: [String]

    init(name: String, kind: DocumentKind, pages: [String]) {
        self.name = name
        self.kind = kind
        self.pages = pages
    }

    init(_ document: MeetingDocument) {
        let base = (document.name as NSString).deletingPathExtension
        self.init(name: base.isEmpty ? document.name : base, kind: document.documentKind, pages: document.pageTexts)
    }

    /// 字数：各页 Character 数的和（Windows 用字形集群）
    var length: Int { pages.reduce(0) { $0 + $1.count } }
}

/// 会议参考资料（design §39.3、R61.5～R61.7、D133、D135）：长度分配、提示词里的区块、整理和提问多的规则
enum DocumentPrompt {
    /// 一场会议的文档合计最多几个字（R61.7，同问所有会议）
    static let limit = 40_000

    struct Allocated: Equatable {
        var document: DocumentText
        /// 送出的页（最后一页可能被截）
        var pages: [String]
        var includedPages: Int
        var includedChars: Int
        var truncated: Bool

        /// 截掉的说明用「前 N 页」：有页码、而且后面还有整页没送；截在最后一页里时用字数
        var cutByPages: Bool { truncated && document.kind.isPaged && includedPages < document.pages.count }
    }

    /// 平均分配：由短到长，每份拿「剩下的额度 ÷ 还没分到的份数」和自己的长度取小的；短的整份送、长的截掉后面
    static func allocate(_ documents: [DocumentText], limit: Int = limit) -> [Allocated] {
        let lengths = documents.map(\.length)
        let order = documents.indices.sorted { (lengths[$0], $0) < (lengths[$1], $1) }
        var budgets = Array(repeating: 0, count: documents.count)
        var remaining = limit
        for (k, i) in order.enumerated() {
            budgets[i] = min(lengths[i], remaining / (documents.count - k))
            remaining -= budgets[i]
        }
        return documents.indices.map { truncate(documents[$0], to: budgets[$0]) }
    }

    /// 整页放进去，放不下的那一页取前面的字，后面的页不送
    static func truncate(_ document: DocumentText, to budget: Int) -> Allocated {
        var pages: [String] = []
        var used = 0
        for page in document.pages {
            let count = page.count
            if used + count <= budget {
                pages.append(page)
                used += count
                continue
            }
            let rest = budget - used
            if rest > 0 {
                pages.append(String(page.prefix(rest)))
                used += rest
            }
            break
        }
        return Allocated(document: document, pages: pages, includedPages: pages.count, includedChars: used,
                         truncated: used < document.length)
    }

    // MARK: 提示词里的区块（放在重点标记之后、逐字稿之前）

    static func block(_ documents: [DocumentText], language: MeetingLanguage, limit: Int = limit) -> String {
        var lines = [language.prompt(zh: "会议参考资料（用户加入的文档，[第 N 页] 是页码）：",
                                   en: "Reference documents (added by the user; [Page N] marks page numbers):",
                                   ja: "会議の参考資料（ユーザーが追加した文書。[N ページ] はページ番号）：")]  // l10n-skip
        for (index, item) in allocate(documents, limit: limit).enumerated() {
            if index > 0 { lines.append("") }
            lines.append(title(item.document.name, language) + (item.truncated ? truncationNote(item, language) : ""))
            for (page, text) in item.pages.enumerated() where !text.isEmpty {
                if item.document.kind.isPaged { lines.append(marker(page + 1, item.document.kind, language)) }
                lines.append(text)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func title(_ name: String, _ language: MeetingLanguage) -> String {
        language.prompt(zh: "《\(name)》", en: "Document: \(name)", ja: "『\(name)』")
    }

    static func marker(_ page: Int, _ kind: DocumentKind, _ language: MeetingLanguage) -> String {
        kind == .pptx
            ? language.prompt(zh: "[第 \(page) 张幻灯片]", en: "[Slide \(page)]", ja: "[スライド \(page)]")
            : language.prompt(zh: "[第 \(page) 页]", en: "[Page \(page)]", ja: "[\(page) ページ]")
    }

    static func truncationNote(_ item: Allocated, _ language: MeetingLanguage) -> String {
        let n = item.includedPages, m = item.document.pages.count
        switch item.cutByPages ? item.document.kind : .text {
        case .pdf:
            return language.prompt(zh: "（文档太长，只附上前 \(n) 页，共 \(m) 页）",
                                 en: " (too long; only the first \(n) of \(m) pages are included)",
                                 ja: "（長すぎるため、全 \(m) ページのうち最初の \(n) ページのみ）")  // l10n-skip
        case .pptx:
            return language.prompt(zh: "（文档太长，只附上前 \(n) 张幻灯片，共 \(m) 张）",
                                 en: " (too long; only the first \(n) of \(m) slides are included)",
                                 ja: "（長すぎるため、全 \(m) 枚のスライドのうち最初の \(n) 枚のみ）")  // l10n-skip
        case .docx, .text, .image:
            let x = item.includedChars, y = item.document.length
            return language.prompt(zh: "（文档太长，只附上前 \(x) 字，共 \(y) 字）",
                                 en: " (too long; only the first \(x) of \(y) characters are included)",
                                 ja: "（長すぎるため、全 \(y) 文字のうち最初の \(x) 文字のみ）")  // l10n-skip
        }
    }

    // MARK: 规则（有文档时才接在原本的规则后面）

    /// 整理：中文、英文 12～16，日文 13～17
    static func notesRules(_ language: MeetingLanguage) -> String {
        language.prompt(zh: """
        12. 「会议参考资料」是用户加入、会议中一起讨论的文档（演示文稿、规格书、报价单等）。用它来看懂逐字稿：讨论指的是哪一页、哪个方案，以及数字、名称、专有名词的正确写法。
        13. 记录以会议中实际讨论的内容为准。文档里有、但会议中没有讨论的内容，不要写进记录。
        14. 记录用到文档里的信息（数字、规格、日期、条文）时，在该条的句尾注明出处，例如「（《报价单》第 3 页）」；幻灯片写「（《演示文稿》第 3 张幻灯片）」，没有页码的文档只写「（《议程》）」。time 仍填逐字稿里讨论到它的时间点。
        15. 会议中的说法跟文档不一致时（例如数字、日期、名称不同），照会议中的说法写，并列进 reviewItems 请用户确认。
        16. 专有名词、人名在文档里找得到正确写法时，照文档写，不必列进 reviewItems（这是规则 2 的例外）。
        """, en: """
        12. "Reference documents" are documents the user added that were discussed in the meeting (slides, specifications, quotes, etc.). Use them to understand the transcript: which page or option the discussion refers to, and the correct numbers, names and spellings of terms.
        13. The notes follow what was actually discussed in the meeting. Do not include content that is only in the documents and was not discussed.
        14. When an item uses information from a document (numbers, specifications, dates, clauses), cite the source at the end of that item, for example "(Quote, p. 3)"; for slides write "(Deck, slide 3)", and for a document without page numbers just its name, "(Agenda)". time is still when it was discussed in the transcript.
        15. If what was said in the meeting differs from a document (for example a different number, date or name), write what was said in the meeting and add it to reviewItems for the user to confirm.
        16. If the correct spelling of a proper noun or name can be found in the documents, use it; it does not need to go in reviewItems (an exception to rule 2).
        """, ja: """
        13. 「会議の参考資料」は、ユーザーが追加した、会議で一緒に検討された文書（スライド、仕様書、見積書など）である。文字起こしを理解するために使う：議論がどのページ・どの案を指しているか、数字・名前・専門用語の正しい表記。
        14. 議事録は会議で実際に議論された内容を基準とする。文書にあっても会議で議論されなかった内容は書かない。
        15. 文書の情報（数字、仕様、日付、条文）を使った項目には、文末に出典を書く。例：「（『見積書』3 ページ）」。スライドは「（『提案資料』スライド 3）」、ページ番号のない文書は「（『議題』）」とする。time は引き続き文字起こしで議論された時刻を入れる。
        16. 会議での発言と文書の内容が食い違う場合（数字、日付、名前など）は、会議での発言どおりに書き、reviewItems に入れてユーザーに確認してもらう。
        17. 固有名詞や人名の正しい表記が文書で確認できる場合はそれに従い、reviewItems に入れなくてよい（ルール 2 の例外）。
        """)
    }

    /// 对一场会议提问：第 5 条
    static func askRule(_ language: MeetingLanguage) -> String {
        language.prompt(zh: """
        5. 「会议参考资料」是会议中一起讨论的文档，也可以用来回答，但要说清楚是会议中说的，还是只有文档里写的。根据文档的重点放进 citations 时，time 填空字符串，quote 开头写出处，例如「《报价单》第 3 页：…」。
        """, en: """
        5. The "Reference documents" were discussed in the meeting and can also be used to answer, but make clear whether something was said in the meeting or is only written in a document. For a point based on a document, add a citation with "time" as an empty string and "quote" starting with the source, for example "Quote, p. 3: …".
        """, ja: """
        5. 「会議の参考資料」は会議で一緒に検討された文書で、回答に使ってもよいが、会議で話されたことか、文書に書いてあるだけのことかを区別すること。文書にもとづく要点を citations に入れるときは、time を空文字列にし、quote の先頭に出典を書く（例：「『見積書』3 ページ：…」）。
        """)
    }
}
