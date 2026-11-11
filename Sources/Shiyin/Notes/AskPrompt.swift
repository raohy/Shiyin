import Foundation

/// 对会议提问（design §21.8、R19.6、D32）：单场用会议记录和逐字稿回答；跨会议先抽搜索关键词，再用全文搜索找到的片段回答
enum AskPrompt {
    struct Citation: Codable, Hashable {
        /// 跨会议时是哪一场会议；单场时没有
        var meetingId: Int64?
        var time: String
        var quote: String

        init(meetingId: Int64? = nil, time: String, quote: String) {
            self.meetingId = meetingId
            self.time = time
            self.quote = quote
        }

        /// 模型不一定照 schema 填（design §21.8）：time、quote 没有或是 null 时当成空字符串，之后由 validate 丢掉用不到的
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            meetingId = try? c.decodeIfPresent(Int64.self, forKey: .meetingId)
            time = (try? c.decodeIfPresent(String.self, forKey: .time)) ?? ""
            quote = (try? c.decodeIfPresent(String.self, forKey: .quote)) ?? ""
        }

        private enum CodingKeys: String, CodingKey { case meetingId, time, quote }
    }

    struct Answer: Codable, Hashable {
        var answer: String
        /// 提供的内容里有没有提到
        var found: Bool
        var citations: [Citation]
        /// 跨会议：用了哪些关键词、送了哪些会议（存起来给画面显示「参考了 N 场会议」）
        var keywords: [String]?
        var meetingIds: [Int64]?

        init(answer: String, found: Bool, citations: [Citation], keywords: [String]? = nil, meetingIds: [Int64]? = nil) {
            self.answer = answer
            self.found = found
            self.citations = citations
            self.keywords = keywords
            self.meetingIds = meetingIds
        }

        /// 只有 answer 一定要有（design §21.8）：found 没有时看有没有出处，citations 没有是空的，不是对象的出处略过
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            answer = try c.decode(String.self, forKey: .answer)
            citations = ((try? c.decodeIfPresent([Lossy<Citation>].self, forKey: .citations)) ?? nil)?.compactMap(\.value) ?? []
            found = (try? c.decodeIfPresent(Bool.self, forKey: .found)) ?? !citations.isEmpty
            keywords = try? c.decodeIfPresent([String].self, forKey: .keywords)
            meetingIds = try? c.decodeIfPresent([Int64].self, forKey: .meetingIds)
        }

        private enum CodingKeys: String, CodingKey { case answer, found, citations, keywords, meetingIds }
    }

    /// 数组里解不了的项目变成 nil，不让整个数组失败
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    /// 跨会议时一场会议的资料：会议记录的摘要、决议，加上搜索命中的段落（前后各一段）
    struct MeetingBlock {
        var id: Int64
        var title: String
        var date: String
        var summary: [String]
        var lines: [String]      // [时间] 说话者：内容
    }

    // MARK: 输出格式

    private static let citationItems = #"{"type":"object","additionalProperties":false,"required":["time","quote"],"properties":{"time":{"type":"string"},"quote":{"type":"string"}}}"#
    private static let crossCitationItems = #"{"type":"object","additionalProperties":false,"required":["meetingId","time","quote"],"properties":{"meetingId":{"type":"integer"},"time":{"type":"string"},"quote":{"type":"string"}}}"#

    static let meetingSchema = #"{"type":"object","additionalProperties":false,"required":["answer","found","citations"],"properties":{"answer":{"type":"string"},"found":{"type":"boolean"},"citations":{"type":"array","items":"# + citationItems + "}}}"
    static let allSchema = #"{"type":"object","additionalProperties":false,"required":["answer","found","citations"],"properties":{"answer":{"type":"string"},"found":{"type":"boolean"},"citations":{"type":"array","items":"# + crossCitationItems + "}}}"
    static let keywordsSchema = #"{"type":"object","additionalProperties":false,"required":["keywords"],"properties":{"keywords":{"type":"array","items":{"type":"string"}}}}"#

    /// 工具说明是给模型看的，不是界面文字
    static let meetingFormat = LLMClient.OutputFormat(schema: meetingSchema, toolName: "save_answer", toolDescription: "Save the answer to the question")
    static let allFormat = LLMClient.OutputFormat(schema: allSchema, toolName: "save_answer", toolDescription: "Save the answer to the question")
    static let keywordsFormat = LLMClient.OutputFormat(schema: keywordsSchema, toolName: "save_search_keywords",
                                                      toolDescription: "Save the search keywords for the question")

    // MARK: 提示词（中文、英文、日文各一份）

    /// documents：有参考文档时加一条（design §39.3、R61.6）
    static func meetingSystem(_ l: MeetingLanguage, documents: Bool = false) -> String {
        let base = meetingSystemBase(l)
        return documents ? base + "\n" + DocumentPrompt.askRule(l) : base
    }

    private static func meetingSystemBase(_ l: MeetingLanguage) -> String {
        l.prompt(zh: """
        你是会议助理，只根据提供的这场会议的内容（会议记录和逐字稿）回答用户的问题。

        规则：
        1. 只用提供的内容回答，不要推测，也不要补充外部知识。内容里没有提到，就说这场会议没有提到，found 填 false。
        2. 简洁、直接回答问题；需要列点时每点用「- 」开头。
        3. 每个重点都要有依据，放在 citations：time 照逐字稿的 [mm:ss] 或 [h:mm:ss] 写，quote 是那一段的原文（节录，60 字以内）。
        4. 用提问的语言回答；中文回答一律用简体中文（大陆用语），citations 的 quote 保留原文。
        """, en: """
        You are a meeting assistant. Answer the user's question using only the content provided from this meeting (the meeting notes and transcript).

        Rules:
        1. Use only the provided content. Do not guess or add outside knowledge. If the content does not mention it, say the meeting did not cover it and set "found" to false.
        2. Be concise and answer the question directly. Use "- " at the start of each point when listing.
        3. Back every point with a citation: "time" as written in the transcript ([mm:ss] or [h:mm:ss]), "quote" the original words of that segment (an excerpt, at most 30 words).
        4. Answer in the language of the question.
        """, ja: """
        あなたは会議アシスタントです。提供されたこの会議の内容（議事録と文字起こし）だけに基づいて、ユーザーの質問に答えてください。

        ルール：
        1. 提供された内容だけで答える。推測や外部の知識の補足はしない。内容に出てこない場合は、この会議では触れられていないと答え、found を false にする。
        2. 簡潔に、質問に直接答える。箇条書きは各行を「- 」で始める。
        3. 要点ごとに根拠を citations に入れる：time は文字起こしの [mm:ss] または [h:mm:ss] のとおり、quote はその段落の原文（抜粋、60 字以内）。
        4. 質問と同じ言語で答える。
        """)
    }

    static func allSystem(_ l: MeetingLanguage) -> String {
        l.prompt(zh: """
        你是会议助理，只根据提供的几场会议的片段回答用户的问题。每场会议有编号、标题、日期、会议记录的摘要，以及跟问题有关的逐字稿片段。

        规则：
        1. 只用提供的内容回答，不要推测，也不要补充外部知识。都没有提到，就说找不到相关的内容，found 填 false。
        2. 简洁、直接回答问题；不同会议的内容要说清楚是哪一场（标题或日期）。需要列点时每点用「- 」开头。
        3. 每个重点都要有依据，放在 citations：meetingId 是那场会议的编号，time 照逐字稿片段的 [mm:ss] 或 [h:mm:ss] 写，quote 是原文（节录，60 字以内）。
        4. 用提问的语言回答；中文回答一律用简体中文（大陆用语），citations 的 quote 保留原文。
        """, en: """
        You are a meeting assistant. Answer the user's question using only the excerpts provided from several meetings. Each meeting has an ID, title, date, a summary from its notes, and transcript excerpts related to the question.

        Rules:
        1. Use only the provided content. Do not guess or add outside knowledge. If none of it is relevant, say nothing related was found and set "found" to false.
        2. Be concise and answer the question directly. Make clear which meeting each point comes from (title or date). Use "- " at the start of each point when listing.
        3. Back every point with a citation: "meetingId" is the meeting's ID, "time" as written in the excerpt ([mm:ss] or [h:mm:ss]), "quote" the original words (an excerpt, at most 30 words).
        4. Answer in the language of the question.
        """, ja: """
        あなたは会議アシスタントです。提供された複数の会議の抜粋だけに基づいて、ユーザーの質問に答えてください。各会議には番号、タイトル、日付、議事録の要約、質問に関係する文字起こしの抜粋があります。

        ルール：
        1. 提供された内容だけで答える。推測や外部の知識の補足はしない。関係する内容がなければ、見つからなかったと答え、found を false にする。
        2. 簡潔に、質問に直接答える。どの会議の内容か（タイトルか日付）をはっきりさせる。箇条書きは各行を「- 」で始める。
        3. 要点ごとに根拠を citations に入れる：meetingId はその会議の番号、time は抜粋の [mm:ss] または [h:mm:ss] のとおり、quote は原文（抜粋、60 字以内）。
        4. 質問と同じ言語で答える。
        """)
    }

    static func keywordsSystem(_ l: MeetingLanguage) -> String {
        l.prompt(zh: """
        把用户对会议的问题，转成用来全文搜索会议逐字稿的关键词。

        规则：
        1. 3～8 个关键词，最重要的放前面。
        2. 包含同义词、常见的说法、中英文写法、简称（例如「寄信」也列「邮件」「mail」「SendGrid」）。
        3. 每个关键词是一个词或短语，至少 2 个字，不要整句、不要「会议」「讨论」这种每场都有的词。
        """, en: """
        Turn the user's question about their meetings into keywords for a full-text search of meeting transcripts.

        Rules:
        1. 3 to 8 keywords, most important first.
        2. Include synonyms, common phrasings, spellings in other languages and abbreviations (for "email", also list "mail", "SendGrid").
        3. Each keyword is a word or short phrase of at least 2 characters. No full sentences, and no words every meeting has, like "meeting" or "discuss".
        """, ja: """
        会議についてのユーザーの質問を、会議の文字起こしを全文検索するためのキーワードに変換してください。

        ルール：
        1. キーワードは 3～8 個、重要なものから並べる。
        2. 同義語、よく使う言い方、英語・日本語の表記、略称も入れる（「メール送信」なら「メール」「mail」「SendGrid」も）。
        3. 各キーワードは語か短いフレーズで 2 文字以上。文全体や、「会議」「議論」のようにどの会議にもある語は入れない。
        """)
    }

    static func meetingPrompt(meeting: Meeting, notes: MeetingNotes?, lines: [String], history: [(question: String, answer: String)],
                              question: String, documents: [DocumentText] = []) -> String {
        let l = meeting.meetingLanguage
        let colon = l.prompt(zh: "：", en: ": ", ja: "：")
        var out: [String] = []
        out.append(l.prompt(zh: "会议标题", en: "Meeting title", ja: "会議タイトル") + colon + meeting.displayTitle)
        out.append(l.prompt(zh: "会议日期", en: "Meeting date", ja: "会議の日付") + colon + meeting.meetingDate)
        if !meeting.participantList.isEmpty {
            out.append(l.prompt(zh: "参加者", en: "Participants", ja: "参加者") + colon + meeting.participantList.joined(separator: l.prompt(zh: "、", en: ", ", ja: "、")))
        }
        if let notes {
            out.append("")
            out.append(l.prompt(zh: "会议记录（JSON）", en: "Meeting notes (JSON)", ja: "議事録（JSON）") + colon)
            out.append(notes.jsonString())
        }
        if !documents.isEmpty {
            out.append("")
            out.append(DocumentPrompt.block(documents, language: l))
        }
        out.append("")
        out.append(l.prompt(zh: "逐字稿（[时间] 说话者：内容）", en: "Transcript ([time] speaker: text)", ja: "文字起こし（[時刻] 話者：内容）") + colon)
        out += lines
        if !history.isEmpty {
            out.append("")
            out.append(l.prompt(zh: "之前的问答（追问时参考）", en: "Earlier questions and answers (for follow-ups)", ja: "これまでの質問と回答（追加の質問の参考）") + colon)
            for item in history {
                out.append("Q" + colon + item.question)
                out.append("A" + colon + item.answer)
            }
        }
        out.append("")
        out.append(l.prompt(zh: "问题", en: "Question", ja: "質問") + colon + question)
        return out.joined(separator: "\n")
    }

    static func allPrompt(_ l: MeetingLanguage, blocks: [MeetingBlock], question: String) -> String {
        let colon = l.prompt(zh: "：", en: ": ", ja: "：")
        var out: [String] = []
        for block in blocks {
            out.append(l.prompt(zh: "【会议 \(block.id)】", en: "[Meeting \(block.id)]", ja: "【会議 \(block.id)】") + " \(block.title)（\(block.date)）")
            if !block.summary.isEmpty {
                out.append(l.prompt(zh: "摘要与决议", en: "Summary and decisions", ja: "要約と決定事項") + colon)
                out += block.summary.map { "- " + $0 }
            }
            if !block.lines.isEmpty {
                out.append(l.prompt(zh: "逐字稿片段", en: "Transcript excerpts", ja: "文字起こしの抜粋") + colon)
                out += block.lines
            }
            out.append("")
        }
        out.append(l.prompt(zh: "问题", en: "Question", ja: "質問") + colon + question)
        return out.joined(separator: "\n")
    }

    static func keywordsPrompt(_ l: MeetingLanguage, question: String) -> String {
        l.prompt(zh: "问题：", en: "Question: ", ja: "質問：") + question
    }

    // MARK: 送出

    @MainActor
    static func generate<T: Decodable>(_ type: T.Type, provider: LLMProvider, model: String, system: String, prompt: String,
                                       format: LLMClient.OutputFormat, onStart: (Subprocess) -> Void) async throws -> T {
        let data = try await LLMClient.generateJSON(provider: provider, model: model, system: system, prompt: prompt, format: format, onStart: onStart)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw LLMError.badAnswer(error.localizedDescription + provider.badOutputHint) }
    }

    /// 丢掉不能用的出处：时间格式不对、跨会议时不是提供的会议
    /// documentCitations：这场会议有参考文档，time 是空的引用是文档的出处，留着（design §39.3）
    static func validate(_ answer: Answer, meetingIds: Set<Int64>?, documentCitations: Bool = false) -> Answer {
        var result = answer
        result.answer = answer.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        result.citations = answer.citations.compactMap { c in
            var c = c
            c.time = TimeFormat.clean(c.time)
            c.quote = c.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            let fromDocument = documentCitations && meetingIds == nil && c.time.isEmpty && !c.quote.isEmpty
            guard fromDocument || TimeFormat.seconds(c.time) != nil else { return nil }
            if let meetingIds {
                guard let id = c.meetingId, meetingIds.contains(id) else { return nil }
            } else {
                c.meetingId = nil
            }
            return c
        }
        return result
    }
}
