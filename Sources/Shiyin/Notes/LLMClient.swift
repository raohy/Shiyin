import Foundation

enum LLMProvider: String, CaseIterable, Identifiable {
    /// enterprise：公司的企业服务器（R51、design §36.3），菜单一直有（D124），模型由公司的后台设置
    case claude, codex, anthropic, openai, gemini, openaiCompatible, enterprise, none
    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: return String(localized: "Claude（claude CLI）")
        case .codex: return String(localized: "Codex（codex CLI）")
        case .anthropic: return "Anthropic API"
        case .openai: return "OpenAI API"
        case .gemini: return "Gemini API"
        case .openaiCompatible: return String(localized: "OpenAI 兼容 API")
        case .enterprise: return String(localized: "公司")
        case .none: return String(localized: "不整理")
        }
    }

    /// 「由 xx 整理」用的名称
    var shortLabel: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .anthropic: return "Anthropic API"
        case .openai: return "OpenAI API"
        case .gemini: return "Gemini API"
        case .openaiCompatible: return String(localized: "OpenAI 兼容 API")
        case .enterprise: return String(localized: "公司的模型")
        case .none: return String(localized: "不整理")
        }
    }

    var usesAPIKey: Bool { [.anthropic, .openai, .gemini, .openaiCompatible].contains(self) }
    /// 「取得 API key」的网页（R35.3）；OpenAI 兼容 API 各家不同，没有
    var apiKeyURL: URL? {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        default: return nil
        }
    }
    /// OpenAI 兼容 API 的 key 可以不填：本机的 Ollama、LM Studio 不需要（design §19.3）
    var keyOptional: Bool { self == .openaiCompatible }
    /// 钥匙串的 account（design §8.4）
    var keychainAccount: String { rawValue }

    /// 模型设置存在 UserDefaults 的 key；API 的默认模型
    var modelKey: String { "\(rawValue)Model" }
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5-5"
        case .openai: return "gpt-5"
        case .gemini: return "gemini-3.8-flash"
        default: return ""
        }
    }

    /// 结果格式不对时附加的说明：OpenAI 兼容 API 的模型不一定支持 JSON 输出（design §19.3）
    var badOutputHint: String {
        self == .openaiCompatible || self == .enterprise ? " " + String(localized: "这个模型可能不支持 JSON 输出，可以换一个模型试试。") : ""
    }
}

enum LLMError: LocalizedError {
    case notInstalled(String)
    /// claude / codex 没登录或登录过期（用户反馈：只看到英文的 OAuth 错误，不知道要做什么）
    case notLoggedIn(String)
    case missingKey(String)
    /// key 错误或没有权限：HTTP 401、403、Gemini 的「API key not valid」400（design §34.4）
    case rejected(String)
    /// 额度或用量上限：HTTP 429、claude／codex 的 usage limit
    case limited(String)
    /// 连不到服务（网络）
    case unreachable(String)
    /// OpenAI 兼容 API 没填网址或模型、网址不对；整理工具是「不整理」
    case notConfigured(String)
    case failed(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name):
            // 一般用户不知道什么是命令：说清楚是给已经在用 Claude Code（Codex）的人，没有的话改用 API（R35.4）
            if name == "claude" && DesktopApps.hasClaude {
                // 只有 Claude 桌面版：说明要另外装 Claude Code（R56.3）
                return String(localized: "这台 Mac 找不到 Claude Code（命令行版）。Claude 桌面版不能直接用，请到设置 → 整理工具照说明安装 Claude Code；或改用 API（填 API key）、选「不整理」")
            }
            return name == "codex"
                ? String(localized: "这台 Mac 找不到 codex。没有在用 Codex 的话，请到设置 → 整理工具改用 API（填 API key）或选「不整理」")
                : String(localized: "这台 Mac 找不到 claude。没有在用 Claude Code 的话，请到设置 → 整理工具改用 API（填 API key）或选「不整理」")
        case .notLoggedIn(let name):
            // 用桌面版附的 codex：到那个 app 登录（R55.3）
            if name == "codex", let app = CLILogin.desktopApp(.codex) {
                return String(localized: "Codex 还没登录或登录已过期，请打开 \(app) 重新登录后再试一次。")
            }
            return name == "codex"
                ? String(localized: "Codex 还没登录或登录已过期，请重新登录后再试一次（终端命令：codex login）。")
                : String(localized: "Claude Code 还没登录或登录已过期，请重新登录后再试一次（终端命令：claude auth login）。")
        case .missingKey(let name): return String(localized: "还没有填 \(name) 的 API key，请到设置 → 整理工具填写")
        case .rejected(let detail), .limited(let detail), .unreachable(let detail), .notConfigured(let detail), .failed(let detail): return detail
        case .badOutput(let detail): return String(localized: "回传的会议记录格式不正确：\(detail)")
        }
    }

    /// 设置问题（R46.1）：重试也不会好，要改设置或登录
    var isSetupProblem: Bool {
        switch self {
        case .notInstalled, .notLoggedIn, .missingKey, .rejected, .notConfigured: return true
        case .limited, .unreachable, .failed, .badOutput: return false
        }
    }

    /// 工作记录的 error_kind（`logSummary`）是不是设置问题（design §34.4）
    static func isSetupProblem(errorKind: String?) -> Bool {
        guard let errorKind else { return false }
        return ["LLMError.notInstalled", "LLMError.notLoggedIn", "LLMError.missingKey", "LLMError.rejected", "LLMError.notConfigured"]
            .contains { errorKind.hasPrefix($0) }
    }

    /// claude、codex 的输出是不是用量上限（R62.1、design §40.1）：「Claude AI usage limit reached」「You've hit your usage limit」
    /// 「You've hit your weekly limit · resets Nov 2 at 9pm」「Credit balance is too low」「429 Too Many Requests」
    static func isLimitProblem(_ text: String) -> Bool {
        let t = text.lowercased()
        let markers = ["usage limit", "rate limit", "limit reached", "rate_limit",
                       "credit balance is too low", "insufficient_quota", "exceeded your current quota", "too many requests"]
        if markers.contains(where: { t.contains($0) }) { return true }
        // 「hit your limit」「hit your weekly limit」「hit your Opus limit」；「… limit · resets 3pm」
        return t.contains(#/hit your[^.\n]{0,30}limit/#) || t.contains(#/limit\W{1,5}resets/#)
    }

    /// claude、codex 的额度用完（R62.2、design §40.2）：说是哪个工具、怎么办，下一行附上 CLI 的原文（里面有什么时候恢复，D137）
    static func cliLimited(_ provider: LLMProvider, output: String) -> LLMError {
        let advice = provider == .codex
            ? String(localized: "Codex 的用量额度用完了，等恢复后再试，或到设置 → 整理工具先换成 Claude Code 或 API。")
            : String(localized: "Claude Code 的用量额度用完了，等恢复后再试，或到设置 → 整理工具先换成 Codex 或 API。")
        // 最后一行符合的：codex 的 stderr 前面可能有别的 log，错误在最后
        guard let line = output.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { isLimitProblem($0) }) else { return .limited(advice) }
        let original = String(line.prefix(300))
        let source = provider == .codex
            ? String(localized: "Codex 的消息：\(original)")
            : String(localized: "Claude Code 的消息：\(original)")
        return .limited(advice + "\n" + source)
    }

    /// 工作记录的失败消息是不是登录问题：CLI 的消息（isLoginProblem），加上桌面版附的 codex 的「打开 ChatGPT 重新登录」（没有终端命令，R55.3）
    static func isLoginMessage(_ text: String) -> Bool {
        isLoginProblem(text) || (CLILogin.desktopApp(.codex) != nil && text.contains(LLMError.notLoggedIn("codex").localizedDescription))
    }

    /// CLI 的错误消息是不是登录问题，例如「Not logged in · Please run /login」「Failed to authenticate: OAuth session expired」
    static func isLoginProblem(_ text: String) -> Bool {
        let t = text.lowercased()
        // 自己的说明文字里有「claude auth login」「codex login」，存在工作记录的失败消息也要认得
        return ["not logged in", "/login", "auth login", "codex login", "failed to authenticate", "oauth", "login required",
                "invalid api key", "unauthorized", "401"].contains { t.contains($0) }
    }
}

extension Error {
    /// 写进 log 用的错误摘要：只有种类，不含消息。整理工具回传的错误消息可能带有逐字稿或会议记录（design §20.8、R18.8）
    var logSummary: String {
        if let error = self as? LLMError {
            switch error {
            case .notInstalled(let name): return "LLMError.notInstalled(\(name))"
            case .notLoggedIn(let name): return "LLMError.notLoggedIn(\(name))"
            case .missingKey(let name): return "LLMError.missingKey(\(name))"
            case .rejected: return "LLMError.rejected"
            case .limited: return "LLMError.limited"
            case .unreachable: return "LLMError.unreachable"
            case .notConfigured: return "LLMError.notConfigured"
            case .failed: return "LLMError.failed"
            case .badOutput: return "LLMError.badOutput"
            }
        }
        let error = self as NSError
        return "\(error.domain) \(error.code)"
    }
}

/// 一种整理工具的调用方式（design §19.1、D22）。每种整理工具一个实作，放在 Notes/Backends/
@MainActor
protocol LLMBackend {
    /// 回传符合 format.schema 的 JSON
    func generateJSON(system: String, prompt: String, format: LLMClient.OutputFormat,
                      onStart: (Subprocess) -> Void) async throws -> Data
    /// 可用的模型，给设置页选；不支持或失败回空数组
    func listModels() async -> [String]
}

extension LLMProvider {
    /// 这个整理工具的实作；「不整理」没有
    @MainActor
    func backend(model: String) -> (any LLMBackend)? {
        switch self {
        case .claude: return ClaudeCLI(model: model)
        case .codex: return CodexCLI(model: model)
        case .anthropic: return AnthropicAPI(model: model.isEmpty ? defaultModel : model)
        case .openai: return OpenAIAPI(model: model.isEmpty ? defaultModel : model)
        case .gemini: return GeminiAPI(model: model.isEmpty ? defaultModel : model)
        case .openaiCompatible: return OpenAICompatibleAPI(model: model, baseURL: OpenAICompatibleAPI.savedBaseURL)
        case .enterprise: return EnterpriseAPI(model: model)
        case .none: return nil
        }
    }
}

/// 产生会议记录的入口（design §8.4、§19）。
/// 输出一律用 JSON schema 限制；逐字稿校正（design §17.4）用同一套调用方式，只是格式不同
@MainActor
enum LLMClient {
    static let timeout: TimeInterval = 20 * 60

    #if DEBUG
    /// shiyinctl llmurl：把 API 的网址改到本机的假服务器（design §19.5）
    static var debugBaseURLs: [LLMProvider: String] = [:]
    #endif

    /// API 的网址（不含路径）；DEBUG 建置可以用 llmurl 改掉
    static func apiBase(_ provider: LLMProvider, _ standard: String) -> String {
        #if DEBUG
        if let url = debugBaseURLs[provider] { return url }
        #endif
        return standard
    }

    /// 要模型输出的格式：JSON schema，以及 Anthropic API 用的工具名称和说明
    struct OutputFormat {
        let schema: String
        let toolName: String
        let toolDescription: String

        static var meetingNotes: OutputFormat {
            OutputFormat(schema: MeetingNotes.jsonSchema, toolName: "save_meeting_notes",
                         toolDescription: String(localized: "保存整理好的会议记录"))
        }
    }

    static func generate(provider: LLMProvider, model: String, system: String, prompt: String,
                         onStart: (Subprocess) -> Void) async throws -> MeetingNotes {
        let data = try await generateJSON(provider: provider, model: model, system: system, prompt: prompt,
                                          format: .meetingNotes, onStart: onStart)
        do { return try JSONDecoder().decode(MeetingNotes.self, from: data) }
        catch { throw LLMError.badOutput(error.localizedDescription + provider.badOutputHint) }
    }

    /// 回传符合 format.schema 的 JSON
    static func generateJSON(provider: LLMProvider, model: String, system: String, prompt: String,
                             format: OutputFormat, onStart: (Subprocess) -> Void) async throws -> Data {
        guard let backend = provider.backend(model: model) else {
            throw LLMError.failed(String(localized: "整理工具设置为「不整理」"))
        }
        return try await backend.generateJSON(system: system, prompt: prompt, format: format, onStart: onStart)
    }

    /// 列出可用的模型，给设置页选（失败就回空数组）
    static func listModels(_ provider: LLMProvider) async -> [String] {
        await provider.backend(model: "")?.listModels() ?? []
    }
}
