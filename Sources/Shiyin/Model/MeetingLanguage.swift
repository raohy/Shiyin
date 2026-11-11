import Foundation

/// 手写、调过的提示词和标签有三份（design §41.2、D140）：每种会议语言用其中一份（粤语用中文、韩文用英文）
enum PromptBase: String, Decodable {
    case zh, en, ja
}

/// 语言档里的一笔（design §41.1、D139）：一种会议语言的所有做法
struct LanguageProfile: Decodable {
    enum Tier: String, Decodable { case tuned, general }

    struct Names: Decodable { let zh: String; let en: String }
    struct Live: Decodable { let mac: String; let windows: String; let windowsConvert: String? }
    struct Transcription: Decodable {
        /// 默认的正式转录模型：breeze、turbo（Whisper large-v3-turbo）、qwen
        let model: String
        /// 跟着设置的「Breeze／Qwen3-ASR」
        let engineSetting: Bool
        /// whisper.cpp 的 language、Qwen3-ASR 的语言名称；nil 是那个引擎不能用
        let whisper: String?
        let qwen: String?
        /// 粤语：Qwen3-ASR 的输出先转台湾繁体套 scriptFixes（design §32.5），最后跟其他中文一样转简体（§45）
        let traditional: Bool
        /// 最后的结果转大陆简体（design §45、D151）：中文、粤语
        let simplified: Bool?
    }
    struct WhisperPrompt: Decodable {
        let base: String
        /// %@ 是用 separator 接起来的词汇
        let glossary: String
        let separator: String
        let limit: Int
        /// 评估用的口语写法（design §17.1）；没有就用一般的写法
        let natural: String?
        let naturalList: String?
    }
    struct OCR: Decodable { let mac: [String]; let windows: [String]; let windowsUserProfile: Bool }
    struct HTMLFonts: Decodable { let body: String; let heading: String }
    struct Fonts: Decodable {
        let typesetting: String
        let lang: String
        let titleMac: String
        let titleWindows: String
        let contentWindows: String
        let htmlMac: HTMLFonts
        let htmlWindows: HTMLFonts
    }
    struct Notes: Decodable { let notes: String; let correction: String }
    /// 简转繁之后的修正：from 换成 to，除非那个字在 keep 的词里（design §41.3）
    struct ScriptFix: Decodable { let from: String; let to: String; let keep: [String] }

    let code: String
    let name: String
    let uiName: Names
    let tier: Tier
    let base: PromptBase
    /// 一般语言：通用提示词里「用 … 写」的语言名称（英文）
    let outputName: String?
    /// 精调语言共用别的语言的提示词时，整理、逐字稿校正的 system 最后补的说明（粤语）
    let transcriptNote: Notes?
    let locale: String
    let live: Live
    let transcription: Transcription
    /// 粤语：Qwen3-ASR 的简体输出转繁体后，「系」「繫」多半是「係」、「曬」多半是「晒」
    let scriptFixes: [ScriptFix]?
    /// 用空格分词（英文类）：词汇表的分隔、上限、幻觉防线的字数算法
    let spaced: Bool
    let whisperPrompt: WhisperPrompt
    /// 自动检测时 Whisper base 的语言代码；nil 是不能检测
    let detect: String?
    /// 语系：同一个语系的语言自动检测时不互相切换（design §41.4）
    let family: String
    let ocr: OCR
    let fonts: Fonts
    /// 默认的说话者名称，%lld 是编号
    let speaker: String
    /// 一般语言的字符串表：键是英文那一份的字（含 %@、%lld）
    let strings: [String: String]?

    /// 套用 scriptFixes：一个字一个字看，落在 keep 的词里就不换
    func fixScript(_ text: String) -> String {
        guard let scriptFixes, !scriptFixes.isEmpty else { return text }
        var chars = Array(text)
        for fix in scriptFixes {
            guard let from = fix.from.first, let to = fix.to.first else { continue }
            let keeps = fix.keep.map(Array.init)
            for i in chars.indices where chars[i] == from {
                let kept = keeps.contains { word in
                    word.indices.contains { j in
                        word[j] == from && i - j >= 0 && i - j + word.count <= chars.count && Array(chars[(i - j)..<(i - j + word.count)]) == word
                    }
                }
                if !kept { chars[i] = to }
            }
        }
        return String(chars)
    }
}

/// 语言档（`Resources/languages.json`）：app 的 bundle 里一份；直接跑建置输出（没有 bundle）时读源代码树的那份
enum LanguageProfiles {
    private struct File: Decodable { let languages: [LanguageProfile] }

    static let all: [LanguageProfile] = {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/languages.json")
        let url = Bundle.main.url(forResource: "languages", withExtension: "json") ?? source
        do {
            return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).languages
        } catch {
            fatalError("languages.json: \(error)")  // l10n-skip
        }
    }()

    static let byCode: [String: LanguageProfile] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })
}

/// 会议语言（design §16.3、§18.1、§41、R12.4、R15.1、R63）：决定实时逐字稿、正式转录、会议记录和导出用的语言。
/// 跟界面语言无关：英文界面也可以有中文会议，反之亦然。做法写在语言档（D139），这里只问它；不要再写 `language == .ja`
struct MeetingLanguage: RawRepresentable, Hashable, Codable, Identifiable, CaseIterable {
    let rawValue: String

    /// 语言档里没有的代码回 nil
    init?(rawValue: String) {
        guard LanguageProfiles.byCode[rawValue] != nil else { return nil }
        self.rawValue = rawValue
    }

    private init(code: String) { rawValue = code }

    static let zh = MeetingLanguage(code: "zh")
    static let en = MeetingLanguage(code: "en")
    static let ja = MeetingLanguage(code: "ja")

    /// 语言档的顺序（菜单的顺序）
    static var allCases: [MeetingLanguage] { LanguageProfiles.all.map { MeetingLanguage(code: $0.code) } }

    var id: String { rawValue }

    var profile: LanguageProfile { LanguageProfiles.byCode[rawValue] ?? LanguageProfiles.byCode["zh"]! }

    /// 菜单上的名称：用各自语言的写法，两种界面都一样；一般语言接「（实验性）」（design §41.2）
    var name: String {
        profile.tier == .general ? profile.name + MeetingLanguage.ui(zh: "（实验性）", en: " (Experimental)") : profile.name  // l10n-skip
    }

    /// 界面上提到这个语言时的名称（跟着界面语言），例如「已切换成日文」
    var uiName: String { MeetingLanguage.interface == .en ? profile.uiName.en : profile.uiName.zh }

    /// SpeechAnalyzer（实时逐字稿、macOS 内置识别）用的语言
    var speechLocale: Locale { Locale(identifier: profile.live.mac) }

    /// 给人看的转录文字（正式转录、实时逐字稿）转成这个语言要的字形：中文、粤语转大陆简体（design §45）
    func outputScript(_ text: String) -> String {
        profile.transcription.simplified == true ? ChineseScript.toSimplified(text) : text
    }

    /// whisper.cpp 的 language 参数（语言档的 transcription.whisper）
    var whisperCode: String { profile.transcription.whisper ?? rawValue }

    /// 用哪一份手写的提示词、标签
    var base: PromptBase { profile.base }

    /// 跟着会议语言（不是界面语言）、给人看的文字，例如导出的标题、待确认的是非题（design §41.1）：
    /// 中文、日文那一份照用；英文那一份在一般语言查字符串表，查不到用英文
    func text(zh: String, en: String, ja: String) -> String {
        switch profile.base {
        case .zh: return zh
        case .ja: return ja
        case .en: return profile.strings?[en] ?? en
        }
    }

    /// 提示词里的文字：只看用哪一份，不查字符串表（一般语言的提示词维持英文，D140）
    func prompt(zh: String, en: String, ja: String) -> String {
        switch profile.base {
        case .zh: return zh
        case .en: return en
        case .ja: return ja
        }
    }

    /// 有插值的文字：三份都是格式字符串（%@、%lld），一般语言查字符串表的格式
    func format(zh: String, en: String, ja: String, _ arguments: CVarArg...) -> String {
        String(format: text(zh: zh, en: en, ja: ja), arguments: arguments)
    }

    /// 默认的说话者名称：「说话者 1」「Speaker 1」「话者 1」
    func defaultSpeaker(_ idx: Int) -> String { String(format: profile.speaker, idx) }

    /// 日期、星期的格式
    var locale: Locale { Locale(identifier: profile.locale) }

    /// 正式转录的 whisper 用 large-v3-turbo（日文、粤语、韩文…）还是 Breeze（design §41.3）
    var usesTurbo: Bool { profile.transcription.model == "turbo" }

    /// 界面上列出用某个转录模型的语言，例如「日文和韩文」（设置的模型名称、环境检查）
    static func uiNames(model: String) -> String { uiNames(allCases.filter { $0.profile.transcription.model == model }) }

    /// 自动检测认得的语言（语言档的 detect 不是 null，design §41.4）
    static var detectable: [MeetingLanguage] { allCases.filter { $0.profile.detect != nil } }

    /// 界面上列出几种语言：「中文、英文、日文和韩文」「Chinese, English, Japanese, and Korean」
    static func uiNames(_ languages: [MeetingLanguage]) -> String {
        let formatter = ListFormatter()
        formatter.locale = Locale(identifier: interface == .en ? "en" : "zh-Hans")  // l10n-skip
        return formatter.string(from: languages.map(\.uiName)) ?? ""
    }

    /// 同一个中文词在英文要用不同说法的少数地方（例如「录音」：按钮是 Record、标签页是 Recording），
    /// 直接依界面语言给两种写法，不经过翻译表
    static func ui(zh: String, en: String) -> String { interface == .en ? en : zh }

    /// 目前的界面语言（跟着 macOS 的语言设置），只会是中文或英文
    static var interface: MeetingLanguage {
        Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? .zh : .en
    }

    /// 新会议没有设置时的默认会议语言：跟着界面语言；macOS 的第一个语言是语言档里中文、英文以外的语言
    /// （日文、韩文）时用那个语言（界面是英文）。香港的中文（zh-HK）仍然默认中文，粤语要自己选（design §41.6）
    static var systemDefault: MeetingLanguage {
        guard interface == .en, let first = Locale.preferredLanguages.first else { return interface }
        let other = allCases.first { $0 != .en && $0.profile.family != "zh" && first.hasPrefix($0.rawValue) }
        return other ?? interface
    }
}
