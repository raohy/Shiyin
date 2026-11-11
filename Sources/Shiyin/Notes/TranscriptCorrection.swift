import Foundation

/// 一则校正建议：把某一段里的 original 改成 suggestion（design §17.4、R14.4）
struct CorrectionSuggestion: Codable, Hashable {
    /// 段落在整份逐字稿里的位置（从 0 开始）
    var segment: Int
    var original: String
    var suggestion: String
    var reason: String
}

/// 逐字稿校正：请整理工具找出疑似听错的字，列成建议，用户接受才改（D17）
enum TranscriptCorrection {
    /// 每次送出的段落数：太多容易漏看，太少要送很多次
    static let chunkSize = 150

    struct Context {
        var language: MeetingLanguage
        var title: String
        var participants: [String]
        var speakerNames: [String]
        var glossary: [String]
        var segments: [(text: String, speaker: String?)]
    }

    static let jsonSchema = """
    {"type":"object","additionalProperties":false,"required":["corrections"],"properties":{"corrections":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["segment","original","suggestion","reason"],"properties":{"segment":{"type":"integer"},"original":{"type":"string"},"suggestion":{"type":"string"},"reason":{"type":"string"}}}}}}
    """

    /// 工具说明是给模型看的，不是界面文字
    static let format = LLMClient.OutputFormat(schema: jsonSchema, toolName: "save_corrections",
                                               toolDescription: "Save transcript correction suggestions")

    // MARK: 提示词（中文、英文、日文各一份，design §16.5、§18.4）

    /// 共用别的语言那份的精调语言（粤语）最后接一段逐字稿的说明（design §41.2）
    static func system(_ language: MeetingLanguage) -> String {
        let text = language.prompt(zh: systemChinese, en: systemEnglish, ja: systemJapanese)
        guard let note = language.profile.transcriptNote?.correction else { return text }
        return text + "\n\n" + note
    }

    private static let systemChinese = """
    你是会议逐字稿的校对员。逐字稿是语音识别自动产生的，会有听错的字。你的工作是找出「很可能是识别听错」的地方，提出更正建议。

    规则：
    1. 只改听错的字：同音或近音的错字、写错的专有名词（人名、产品名、系统名、英文术语）、上下文明显说不通的词。
    2. 不要改说话习惯：口语、赘字、语助词、重复、文法不通但听得懂的句子都保留原样。不要润饰、不要补字、不要删字、不要改标点，也不要把中文翻成英文或英文翻成中文。
    3. 专有名词的正确写法以词汇表、参加者、说话者名字、会议标题为准；不在这些资料里的，只有在上下文能确定时才改。
    4. original 必须是那一段原文里一字不差、连续出现的文字，只包含要改的词，越短越好；suggestion 是改正后的文字。
    5. 没有把握就不要建议，宁可漏掉也不要改错。没有要改的就回传空数组。
    6. reason 用一句简体中文（大陆用语）说明为什么，例如「词汇表里的产品名」「上下文在讲数据库缓存」；suggestion 的中文使用简体，专有名词保留参考资料中的写法，original 必须保留原文。
    """

    private static let systemEnglish = """
    You proofread meeting transcripts. The transcript was produced by speech recognition and contains misheard words. Find the places that were most likely misheard and suggest corrections.

    Rules:
    1. Only fix misheard words: words that sound alike, misspelled names (people, products, systems, technical terms), and words that clearly make no sense in context.
    2. Do not change how people speak: keep filler words, repetitions, false starts and informal grammar as they are. Do not polish, add or remove words, change punctuation, or translate between languages.
    3. Use the glossary, participants, speaker names and meeting title for the correct spelling of names. For names not listed, only correct them when the context makes it certain.
    4. "original" must be text that appears exactly and contiguously in that segment, containing only the words to fix, as short as possible; "suggestion" is the corrected text.
    5. If you are not sure, do not suggest anything. Missing a fix is better than making a wrong one. Return an empty array if nothing needs fixing.
    6. "reason" is one sentence, for example "product name from the glossary" or "the discussion is about database caching".
    """

    private static let systemJapanese = """
    あなたは会議の文字起こしの校正者です。文字起こしは音声認識で自動生成されたもので、聞き間違いが含まれています。「音声認識の聞き間違いである可能性が高い」箇所を見つけ、修正案を出してください。

    ルール：
    1. 聞き間違いだけを直す：同音や似た音の誤り、表記を誤った固有名詞（人名、製品名、システム名、英語の用語）、文脈上明らかに意味が通らない語。
    2. 話し方は直さない：話し言葉、言いよどみ、フィラー（えー、あのー など）、繰り返し、文法が崩れていても意味の通じる文はそのまま残す。言い換え、語の追加や削除、句読点の変更、日本語と英語の間の翻訳、漢字・ひらがな・カタカナの表記の統一はしない。
    3. 固有名詞の正しい表記は、用語集、参加者、話者名、会議タイトルに従う。これらにない語は、文脈から確実な場合だけ直す。
    4. original はその段落の原文に一字一句そのまま連続して出てくる文字列で、直したい語だけを含め、できるだけ短くする。suggestion は修正後の文字列。
    5. 自信がなければ提案しない。間違って直すより見逃すほうがよい。直す箇所がなければ空の配列を返す。
    6. reason は理由を一文で書く。例：「用語集にある製品名」「データベースのキャッシュについての話」。
    """

    static func prompt(_ c: Context, range: Range<Int>) -> String {
        let l = c.language
        let separator = l.prompt(zh: "、", en: ", ", ja: "、"), colon = l.prompt(zh: "：", en: ": ", ja: "：")
        let none = l.prompt(zh: "（无）", en: "(none)", ja: "（なし）")
        var lines: [String] = []
        lines.append(l.prompt(zh: "会议标题", en: "Meeting title", ja: "会議タイトル") + colon + (c.title.isEmpty ? none : c.title))
        if !c.participants.isEmpty {
            lines.append(l.prompt(zh: "参加者", en: "Participants", ja: "参加者") + colon + c.participants.joined(separator: separator))
        }
        if !c.speakerNames.isEmpty {
            lines.append(l.prompt(zh: "说话者", en: "Speakers", ja: "話者") + colon + c.speakerNames.joined(separator: separator))
        }
        let glossary = c.glossary.isEmpty ? none : c.glossary.joined(separator: separator)
        lines.append(l.prompt(zh: "词汇表（正确写法）", en: "Glossary (correct spellings)", ja: "用語集（正しい表記）") + colon + glossary)
        lines.append("")
        lines.append(l.prompt(zh: "逐字稿（每行开头的数字是段落编号，segment 字段填这个数字）：",
                            en: "Transcript (the number at the start of each line is the segment number; put it in the \"segment\" field):",
                            ja: "文字起こし（各行の先頭の数字は段落番号。segment 欄にこの数字を入れる）："))
        for i in range {
            let segment = c.segments[i]
            let speaker = segment.speaker.map { $0 + colon } ?? ""
            lines.append("[\(i)] \(speaker)\(segment.text)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 送出与验证

    /// 分段送出，回传验证过的建议；onProgress 反馈 0～1
    @MainActor
    static func suggest(_ context: Context, provider: LLMProvider, model: String,
                        onStart: (Subprocess) -> Void, onProgress: (Double) -> Void) async throws -> [CorrectionSuggestion] {
        var result: [CorrectionSuggestion] = []
        let count = context.segments.count
        var start = 0
        while start < count {
            let range = start..<min(start + chunkSize, count)
            let data = try await LLMClient.generateJSON(provider: provider, model: model, system: system(context.language),
                                                        prompt: prompt(context, range: range), format: format, onStart: onStart)
            struct Output: Decodable { var corrections: [CorrectionSuggestion] }
            let output: Output
            do { output = try JSONDecoder().decode(Output.self, from: data) }
            catch { throw LLMError.badOutput(error.localizedDescription + provider.badOutputHint) }
            result += validate(output.corrections, context: context, range: range)
            start = range.upperBound
            onProgress(Double(start) / Double(count))
        }
        return result
    }

    /// 丢掉不能用的建议：段落编号不在这一批、original 不在那一段的文字里、改了跟没改一样、同一处重复
    static func validate(_ raw: [CorrectionSuggestion], context: Context, range: Range<Int>) -> [CorrectionSuggestion] {
        var seen = Set<String>()
        return raw.compactMap { item in
            var s = item
            s.original = s.original.trimmingCharacters(in: .whitespaces)
            s.suggestion = s.suggestion.trimmingCharacters(in: .whitespaces)
            guard range.contains(s.segment), !s.original.isEmpty, s.original != s.suggestion,
                  context.segments[s.segment].text.contains(s.original),
                  seen.insert("\(s.segment)\u{1F}\(s.original)").inserted else { return nil }
            return s
        }
    }

    /// 套用一则建议：把那一段里第一个 original 换成 suggestion；找不到（之后被改过）就回传 nil
    static func apply(_ s: CorrectionSuggestion, to text: String) -> String? {
        guard let range = text.range(of: s.original) else { return nil }
        return text.replacingCharacters(in: range, with: s.suggestion)
    }

    /// 还原：把 suggestion 换回 original
    static func revert(_ s: CorrectionSuggestion, in text: String) -> String? {
        guard let range = text.range(of: s.suggestion) else { return nil }
        return text.replacingCharacters(in: range, with: s.original)
    }
}
