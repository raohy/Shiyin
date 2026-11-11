import AppKit
import Foundation

/// Claude Code、Codex 的登录状态与重新登录（3.1.2，用户反馈：登录过期时只看到英文错误，不知道怎么办）
@MainActor
enum CLILogin {
    struct Status: Equatable {
        var loggedIn: Bool
        /// 已登录时的说明，例如「someone@example.com（Max 方案）」或「Logged in using ChatGPT」
        var detail: String
    }

    /// 查登录状态，不会送出请求、不消耗额度。找不到命令或看不懂输出时回传 nil。
    /// 注意：「登录过期、刷新失败」时这里可能还是显示已登录，要实际送出请求才知道（设置里的「测试整理工具」）
    static func status(_ provider: LLMProvider) async -> Status? {
        #if DEBUG
        // -debugCLILogin no：当成没登录，不执行 CLI（design §34.6）
        if UserDefaults.standard.string(forKey: "debugCLILogin") == "no", provider == .claude || provider == .codex {
            return Status(loggedIn: false, detail: "")
        }
        #endif
        switch provider {
        case .claude:
            guard let exe = Paths.findTool("claude"),
                  let output = await run(exe, ["auth", "status", "--json"]),
                  let object = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any],
                  let loggedIn = object["loggedIn"] as? Bool else { return nil }
            var detail = object["email"] as? String ?? (object["authMethod"] as? String ?? "")
            if let plan = object["subscriptionType"] as? String, !plan.isEmpty {
                detail += String(localized: "（\(plan.capitalized) 方案）")
            }
            return Status(loggedIn: loggedIn, detail: detail)
        case .codex:
            // 桌面版附的 codex 也一样问它自己（跟 CLI 共用 ~/.codex，拾音不读登录资料，R55.2）
            guard let tool = Paths.locateTool("codex"),
                  let output = await run(tool.url, ["login", "status"], environment: tool.environment) else { return nil }
            // codex 把状态印在 stdout 或 stderr，两个都看
            let line = (output.stdout + "\n" + output.stderr).split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(String.init) ?? ""
            let loggedIn = line.localizedCaseInsensitiveContains("logged in") && !line.localizedCaseInsensitiveContains("not logged in")
            return Status(loggedIn: loggedIn, detail: line)
        default:
            return nil
        }
    }

    /// 查登录状态并记进缓存（design §34.1）；看不出来时缓存是 nil，当作准备好
    @discardableResult
    static func refresh(_ provider: LLMProvider) async -> Status? {
        let status = await status(provider)
        CLILoginCache.store(provider, status?.loggedIn)
        return status
    }

    /// 目前的整理工具是 claude、codex 时，距离上次查超过 60 秒才再查（app 启动、回到前景）
    static func refreshIfStale() async {
        let provider = AppSettings.provider
        guard provider == .claude || provider == .codex, CLILoginCache.isStale(provider, after: 60) else { return }
        await refresh(provider)
    }

    /// 打开「终端」执行登录命令（会开浏览器登录页）。用 .command 文件打开，不需要自动化权限
    static func openLogin(_ provider: LLMProvider) {
        let tool = provider == .codex ? "codex" : "claude"
        guard let location = Paths.locateTool(tool) else { return }
        // 桌面版附的 codex：打开那个 app 登录（R55.3），不开终端
        if let app = location.appURL {
            NSWorkspace.shared.open(app)
            return
        }
        let exe = location.url
        let arguments = provider == .codex ? "login" : "auth login"
        let intro = String(localized: "拾音：正在打开浏览器登录 \(provider.shortLabel)。登录完成后，回到拾音按「重试」或「测试整理工具」。")
        let done = String(localized: "完成后可以关掉这个窗口。")
        let script = """
            #!/bin/zsh
            clear
            echo \(shellQuote(intro))
            echo
            \(shellQuote(exe.path)) \(arguments)
            echo
            echo \(shellQuote(done))
            """
        do {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("shiyin-\(tool)-login.command")
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            log.error("open login failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 用桌面版附的 codex 时是 app 的名称（例如 ChatGPT），用户自己装的是 nil（R55.3）
    nonisolated static func desktopApp(_ provider: LLMProvider) -> String? {
        provider == .codex ? Paths.locateTool("codex")?.desktopApp : nil
    }

    private static func run(_ exe: URL, _ arguments: [String],
                            environment: [String: String]? = nil) async -> (stdout: String, stderr: String)? {
        let process = Subprocess(exe, arguments, environment: environment, directory: FileManager.default.temporaryDirectory)
        guard let result = try? await process.run(timeout: 20) else { return nil }
        return (String(decoding: result.stdout, as: UTF8.self), result.stderrTail(500))
    }
}
