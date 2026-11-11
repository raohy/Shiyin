import AppKit
import Foundation

/// Codex、Claude 的桌面版（R55、R56，design §37）。
/// Codex 桌面版（现在叫 ChatGPT）附一份 codex，找不到用户自己装的 CLI 时用它；Claude 桌面版只看有没有装，用来提示怎么安装 Claude Code
enum DesktopApps {
    struct Codex: Equatable {
        /// 桌面版 app 的位置（「打开 ChatGPT 登录」用）
        let app: URL
        /// app 自己的名称，例如「ChatGPT」
        let name: String
        /// 说明档的 entrypoint
        let executable: URL
        /// 说明档的 pathDir（有 rg），接在子程序的 PATH 前面
        let pathDir: URL?
    }

    static let codexBundleID = "com.openai.codex"
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// 问 LaunchServices 比看文件慢，设置页每次重画都会找工具：结果留 30 秒（同 Windows）
    private static let cacheSeconds: TimeInterval = 30
    private static let lock = NSLock()
    nonisolated(unsafe) private static var codexCache: (at: Date, value: Codex?)?
    nonisolated(unsafe) private static var claudeCache: (at: Date, value: Bool)?
    nonisolated(unsafe) private static var lastProblem: String?

    /// Codex 桌面版附的 codex；没有桌面版、说明档看不懂时是 nil
    static func codex() -> Codex? {
        lock.lock()
        if let cached = codexCache, Date().timeIntervalSince(cached.at) < cacheSeconds {
            lock.unlock()
            return cached.value
        }
        lock.unlock()
        let value = findCodex()
        lock.lock()
        codexCache = (Date(), value)
        lock.unlock()
        return value
    }

    /// 这台 Mac 有没有 Claude 桌面版（R56.2）
    static var hasClaude: Bool {
        #if DEBUG
        // -debugClaudeDesktop yes|no：假装有、没有 Claude 桌面版（design §37.4）
        switch UserDefaults.standard.string(forKey: "debugClaudeDesktop")?.lowercased() {
        case "yes": return true
        case "no": return false
        default: break
        }
        #endif
        lock.lock()
        if let cached = claudeCache, Date().timeIntervalSince(cached.at) < cacheSeconds {
            lock.unlock()
            return cached.value
        }
        lock.unlock()
        let value = !NSWorkspace.shared.urlsForApplications(withBundleIdentifier: claudeBundleID).isEmpty
        lock.lock()
        claudeCache = (Date(), value)
        lock.unlock()
        return value
    }

    /// 「重新检查」：刚装好、刚移除时马上看得到
    static func clearCache() {
        lock.lock()
        codexCache = nil
        claudeCache = nil
        lock.unlock()
    }

    private static func findCodex() -> Codex? {
        var apps = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: codexBundleID)
        #if DEBUG
        // -debugCodexApp <路径>：不问 LaunchServices，把这个文件夹当成 Codex 桌面版（测说明档不对的情况，design §37.4）
        if let path = UserDefaults.standard.string(forKey: "debugCodexApp"), !path.isEmpty {
            apps = [URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)]
        }
        #endif
        var problems: [String] = []
        for app in apps {
            switch readCodex(app: app) {
            case .success(let codex):
                report(nil)
                return codex
            case .failure(let problem):
                problems.append(problem.reason)
            }
        }
        report(problems.isEmpty ? nil : problems.joined(separator: ", "))
        return nil
    }

    /// 说明档不对只记原因，同一个原因不重复记（每 30 秒会重新找一次）
    private static func report(_ problem: String?) {
        lock.lock()
        let changed = problem != lastProblem
        lastProblem = problem
        lock.unlock()
        if changed, let problem { log.notice("codex desktop app skipped: \(problem, privacy: .public)") }
    }

    struct Problem: Error { let reason: String }

    /// 照桌面版的说明档 `Contents/Resources/codex-cli/codex-package.json` 找 codex（design §37.1）
    static func readCodex(app: URL) -> Result<Codex, Problem> {
        let root = app.appendingPathComponent("Contents/Resources/codex-cli", isDirectory: true)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("codex-package.json")) else {
            return .failure(Problem(reason: "no codex-package.json"))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(Problem(reason: "unreadable codex-package.json"))
        }
        guard (object["layoutVersion"] as? Int) == 1 else { return .failure(Problem(reason: "layoutVersion is not 1")) }
        guard let entry = object["entrypoint"] as? String, let executable = inside(root, entry) else {
            return .failure(Problem(reason: "bad entrypoint"))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: executable.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .failure(Problem(reason: "entrypoint is not executable"))
        }
        // pathDir 只是补 rg，不对就不加，不影响整理
        var pathDir: URL?
        if let path = object["pathDir"] as? String, let dir = inside(root, path),
           FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue {
            pathDir = dir
        }
        let info = Bundle(url: app)?.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (info?["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? app.deletingPathExtension().lastPathComponent
        return .success(Codex(app: app, name: name, executable: executable, pathDir: pathDir))
    }

    /// 说明档里的相对路径：不接受绝对路径、`..`，解开链接之后也要在 codex-cli 里面
    private static func inside(_ root: URL, _ relative: String) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("~"),
              !relative.split(separator: "/").contains("..") else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let url = root.appendingPathComponent(relative)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(base + "/") else { return nil }
        return url
    }
}
