import Foundation

/// 整理工具还没准备好的原因（R45.1、design §34.1、D112）。判断不送请求、不花额度、不读钥匙串的内容
enum SummarizerProblem: Equatable {
    /// 没选过、也没有 claude、codex（R35）
    case notChosen
    /// 用户选了「不整理」
    case off
    case notInstalled(LLMProvider)
    case notLoggedIn(LLMProvider)
    case missingKey(LLMProvider)
    /// OpenAI 兼容 API 没填网址或模型
    case incomplete
    /// 整理工具选「公司」，但还没登录企业服务器或登录失效（R51.3）
    case enterpriseSignedOut
    /// 整理工具选「公司」，已登录但服务器还没有整理用的模型（R51.3）
    case enterpriseNoModels
    /// 设置问题的失败之后暂停自动整理（R46.3、§34.4）；String 是那次失败的说明
    case paused(LLMProvider, String)

    enum Action: Equatable { case openSettings, login(LLMProvider) }

    /// 原因和怎么修，一句
    var message: String {
        switch self {
        case .notChosen: return String(localized: "还没设置整理工具，请到设置选择 Claude、Codex 或 API")
        case .off: return String(localized: "整理工具设置为「不整理」，请到设置改成 Claude、Codex 或 API")
        case .notInstalled(let provider): return LLMError.notInstalled(provider == .codex ? "codex" : "claude").localizedDescription
        case .notLoggedIn(let provider):
            // 用桌面版附的 codex：到那个 app 登录（R55.3）
            if let app = CLILogin.desktopApp(provider) { return String(localized: "Codex 还没登录，请打开 \(app) 登录之后再整理。") }
            return provider == .codex
                ? String(localized: "Codex 还没登录，登录之后才能整理（终端命令：codex login）。")
                : String(localized: "Claude Code 还没登录，登录之后才能整理（终端命令：claude auth login）。")
        case .missingKey(let provider): return String(localized: "还没有填 \(provider.shortLabel) 的 API key，请到设置 → 整理工具填写")
        case .incomplete: return String(localized: "还没有填 OpenAI 兼容 API 的网址或模型，请到设置 → 整理工具填写")
        case .enterpriseSignedOut: return String(localized: "公司的服务器还没登录或登录已失效，请到设置 → 高级 → 企业服务器登录")
        case .enterpriseNoModels: return String(localized: "公司的服务器还没有提供整理用的模型，请通知管理者")
        case .paused(_, let detail): return detail
        }
    }

    var action: Action {
        switch self {
        case .notLoggedIn(let provider): return .login(provider)
        case .paused(let provider, let detail) where (provider == .claude || provider == .codex) && LLMError.isLoginMessage(detail):
            return .login(provider)
        default: return .openSettings
        }
    }

    var actionTitle: String {
        switch action {
        case .openSettings: return String(localized: "打开设置")
        case .login(let provider):
            if let app = CLILogin.desktopApp(provider) { return String(localized: "打开 \(app) 登录") }
            return String(localized: "登录 \(provider == .codex ? "Codex" : "Claude Code")")
        }
    }
}

extension AppSettings {
    /// 整理工具准备好了没；nil 是准备好了（§34.1）
    @MainActor static var summarizerProblem: SummarizerProblem? {
        if needsProviderSetup { return .notChosen }
        let provider = self.provider
        switch provider {
        case .none: return .off
        case .claude, .codex:
            if Paths.findTool(provider == .claude ? "claude" : "codex") == nil { return .notInstalled(provider) }
            if CLILoginCache.loggedIn(provider) == false { return .notLoggedIn(provider) }
        case .anthropic, .openai, .gemini:
            if !Keychain.exists(provider.keychainAccount) { return .missingKey(provider) }
        case .openaiCompatible:
            if OpenAICompatibleAPI.normalized(OpenAICompatibleAPI.savedBaseURL) == nil || model.isEmpty { return .incomplete }
        case .enterprise:
            if !EnterpriseServer.shared.isSignedIn { return .enterpriseSignedOut }
            if EnterpriseServer.shared.account?.llm != true { return .enterpriseNoModels }
        }
        if let pause = SummarizerPause.current(for: provider) { return .paused(provider, pause.message) }
        return nil
    }

    /// 自动调度（整理、校正、猜说话者、草稿）只在准备好时排（R45.4）
    @MainActor static var summarizerReady: Bool { summarizerProblem == nil }
}

/// claude、codex 登录状态的缓存（§34.1）。只有明确查到「没有登录」才算没准备好；还没查或看不出来是 nil
@MainActor
enum CLILoginCache {
    private static var values: [LLMProvider: Bool] = [:]
    private static var checkedAt: [LLMProvider: Date] = [:]

    static func loggedIn(_ provider: LLMProvider) -> Bool? {
        #if DEBUG
        // -debugCLILogin no：当成没登录（在登录了的电脑上测，design §34.6）
        if UserDefaults.standard.string(forKey: "debugCLILogin") == "no" { return false }
        #endif
        return values[provider]
    }

    static func store(_ provider: LLMProvider, _ loggedIn: Bool?) {
        values[provider] = loggedIn
        checkedAt[provider] = Date()
        if loggedIn == true { SummarizerPause.clear() }
        NotificationCenter.default.post(name: .summarizerStateChanged, object: nil)
    }

    static func isStale(_ provider: LLMProvider, after seconds: TimeInterval) -> Bool {
        checkedAt[provider].map { Date().timeIntervalSince($0) > seconds } ?? true
    }
}

/// 设置问题的失败之后暂停自动整理（R46.3、§34.4、D113）：只在内存，整理工具设置的指纹变了就不算
@MainActor
enum SummarizerPause {
    struct Value { var provider: LLMProvider; var message: String; var signature: String }
    private static var value: Value?

    static func current(for provider: LLMProvider) -> Value? {
        guard let value, value.provider == provider, value.signature == signature(provider) else { return nil }
        return value
    }

    static func pause(_ provider: LLMProvider, message: String) {
        let value = Value(provider: provider, message: message, signature: signature(provider))
        self.value = value
        NotificationCenter.default.post(name: .summarizerStateChanged, object: nil)
    }

    static func clear() {
        guard value != nil else { return }
        value = nil
        NotificationCenter.default.post(name: .summarizerStateChanged, object: nil)
    }

    /// 整理工具设置的指纹：换工具、改模型或网址、存或删 key 都会变
    static func signature(_ provider: LLMProvider) -> String {
        let url = provider == .openaiCompatible ? OpenAICompatibleAPI.savedBaseURL : ""
        return [provider.rawValue, AppSettings.model, url, String(Keychain.generation)].joined(separator: "|")
    }
}

/// 设置好整理工具时送一次的测试（design §34.3）：引导和设置页的「测试整理工具」共用
@MainActor
enum SummarizerTest {
    /// 成功回传花了几秒，失败丢出整理工具的错误；成功时解除暂停（R46.3）
    static func run(provider: LLMProvider, model: String) async throws -> Int {
        let started = Date()
        let language = AppSettings.defaultMeetingLanguage
        let prompt = language.prompt(zh: "这是连接测试。逐字稿：\n[00:00] 说话者 1：大家好，今天只是测试一下。",
                                   en: "This is a connection test. Transcript:\n[00:00] Speaker 1: Hi everyone, this is just a test.",
                                   ja: "これは接続テストです。文字起こし：\n[00:00] 話者 1：皆さん、今日はテストだけです。")  // l10n-skip
        _ = try await LLMClient.generate(provider: provider, model: model, system: NotesPrompt.system(language),
                                         prompt: prompt, onStart: { _ in })
        SummarizerPause.clear()
        return Int(Date().timeIntervalSince(started).rounded())
    }

    /// 这个整理工具在设置里的模型（引导里选的不一定是目前的整理工具）
    static func model(for provider: LLMProvider) -> String {
        provider == AppSettings.provider ? AppSettings.model : UserDefaults.standard.string(forKey: provider.modelKey) ?? ""
    }
}
