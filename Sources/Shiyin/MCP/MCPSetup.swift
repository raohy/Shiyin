import AppKit
import Foundation

/// 把本地 MCP 加到 AI 工具（design §44.3）：启动档、Claude Code、Codex、Claude Desktop、复制设置
enum MCPSetup {
    static let serverName = "shiyin"

    struct Outcome: Equatable {
        var ok: Bool
        var message: String
    }

    // MARK: 启动档（D148）

    /// AI 工具登记的都是这个档：拾音每次启动时改写成目前的路径，搬家、更新后不用重新设置
    static var launcherURL: URL { Paths.home.appendingPathComponent("bin/shiyin-mcp") }

    static func launcherScript(executable: String, home: String?) -> String {
        var lines = ["#!/bin/sh", "# 拾音的 MCP 服务器（design §44.3）。拾音每次启动时重写，指到目前这份拾音；不要手动改"]  // l10n-skip
        if let home { lines.append("export SHIYIN_HOME=\(shellQuote(home))") }
        lines.append("exec \(shellQuote(executable)) --mcp \"$@\"")
        return lines.joined(separator: "\n") + "\n"
    }

    enum SetupError: LocalizedError {
        case translocated
        var errorDescription: String? {
            switch self {
            case .translocated: return String(localized: "先把拾音拖进「应用程序」文件夹再打开，AI 工具才找得到它。")
            }
        }
    }

    /// 没拖进「应用程序」就从 DMG、下载文件夹打开时，macOS 把拾音搬到暂时的路径（App Translocation），启动档不能指过去（design §44.3）
    static var isTranslocated: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SHIYIN_FAKE_TRANSLOCATED"] == "1" { return true }
        #endif
        return Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    /// 写启动档，内容一样就不写。DEBUG 版没有指定 SHIYIN_HOME 时不写：不然用户的 AI 工具会被指到 DEBUG 版
    @discardableResult
    static func installLauncher() throws -> URL {
        let customHome = ProcessInfo.processInfo.environment["SHIYIN_HOME"].flatMap { $0.isEmpty ? nil : Paths.home.path }
        #if DEBUG
        guard customHome != nil else { throw CocoaError(.featureUnsupported) }
        #endif
        guard !isTranslocated else { throw SetupError.translocated }
        guard let executable = Bundle.main.executableURL?.path else { throw CocoaError(.fileNoSuchFile) }
        removeQuarantine(in: Bundle.main.bundleURL)
        let url = launcherURL
        let script = launcherScript(executable: executable, home: customHome)
        if (try? String(contentsOf: url, encoding: .utf8)) != script {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(script.utf8).write(to: url, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// 拿掉 bundle 的隔离属性（D150）：从网络下载的拾音每个文件都有 com.apple.quarantine，AI 工具直接执行里面的可执行文件时
    /// Gatekeeper 会跳出提示、程序卡住。拾音跑得起来就代表用户放行过。主可执行文件没有隔离属性就不走整个 bundle（每次启动都会叫）
    @discardableResult
    static func removeQuarantine(in bundle: URL) -> Int {
        let name = "com.apple.quarantine"
        let executable = Bundle(url: bundle)?.executableURL ?? bundle
        guard getxattr(executable.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 else { return 0 }
        var urls = [bundle]
        if let items = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil) {
            for case let url as URL in items { urls.append(url) }
        }
        var removed = 0, failed = 0
        for url in urls where getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 {
            if removexattr(url.path, name, XATTR_NOFOLLOW) == 0 { removed += 1 } else { failed += 1 }
        }
        log.info("mcp: removed quarantine from \(removed) file(s), \(failed) failed")
        return removed
    }

    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: 复制

    static var claudeCodeCommand: String { "claude mcp add --scope user \(serverName) -- \(shellQuote(launcherURL.path))" }

    static var configJSON: String {
        let object: [String: Any] = ["mcpServers": [serverName: ["command": launcherURL.path]]]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    enum CopyItem { case claudeCodeCommand, configJSON }

    /// 设置页「复制」菜单的两项：先确定启动档在，再放进剪贴板
    static func copy(_ item: CopyItem) {
        _ = try? installLauncher()
        let text = item == .claudeCodeCommand ? claudeCodeCommand : configJSON
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Claude Code、Codex

    static func addToClaudeCode() async -> Outcome {
        guard let tool = Paths.locateTool("claude") else { return Outcome(ok: false, message: String(localized: "找不到 claude")) }
        return await register(tool, remove: ["mcp", "remove", "--scope", "user", serverName],
                              add: { ["mcp", "add", "--scope", "user", serverName, "--", $0] },
                              done: String(localized: "已加到 Claude Code，开新的对话就能用。"),
                              failed: { String(localized: "没有加到 Claude Code：\($0)") })
    }

    static func addToCodex() async -> Outcome {
        guard let tool = Paths.locateTool("codex") else { return Outcome(ok: false, message: String(localized: "找不到 codex")) }
        return await register(tool, remove: ["mcp", "remove", serverName],
                              add: { ["mcp", "add", serverName, "--", $0] },
                              done: String(localized: "已加到 Codex，开新的对话就能用。"),
                              failed: { String(localized: "没有加到 Codex：\($0)") })
    }

    /// 先移除同名的（不在也没关系）再加，按两次不会重复
    private static func register(_ tool: Paths.ToolLocation, remove: [String], add: (String) -> [String],
                                 done: String, failed: (String) -> String) async -> Outcome {
        do {
            let launcher = try installLauncher()
            _ = try? await Subprocess(tool.url, remove, environment: tool.environment).run(timeout: 20)
            let result = try await Subprocess(tool.url, add(launcher.path), environment: tool.environment).run(timeout: 20)
            guard result.succeeded else {
                let stdout = String(decoding: result.stdout, as: UTF8.self)
                return Outcome(ok: false, message: failed(firstLine(result.stderr.isEmpty ? stdout : result.stderr)))
            }
            return Outcome(ok: true, message: done)
        } catch {
            return Outcome(ok: false, message: failed(error.localizedDescription))
        }
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.isEmpty ? String(localized: "没有错误消息") : String(line.prefix(200))
    }

    // MARK: Claude Desktop

    static var claudeDesktopConfigURL: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SHIYIN_CLAUDE_DESKTOP_CONFIG"], !path.isEmpty { return URL(fileURLWithPath: path) }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static var claudeDesktopInstalled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SHIYIN_CLAUDE_DESKTOP_CONFIG"] != nil { return true }
        #endif
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/Claude.app", home + "/Applications/Claude.app"].contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// 只改 mcpServers.shiyin，其他设置保留（键的顺序会变）；原档先复制成 .bak。不是 JSON 对象就不动
    static func addToClaudeDesktop() -> Outcome {
        let url = claudeDesktopConfigURL
        let fm = FileManager.default
        do {
            let launcher = try installLauncher()
            var root: [String: Any] = [:]
            if fm.fileExists(atPath: url.path) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                      object["mcpServers"] == nil || object["mcpServers"] is [String: Any] else {
                    return Outcome(ok: false, message: String(localized: "Claude Desktop 的设置档不是拾音看得懂的格式，没有改动：\(url.path)"))
                }
                root = object
                let backup = url.appendingPathExtension("bak")
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: url, to: backup)
            }
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers[serverName] = ["command": launcher.path]
            root["mcpServers"] = servers
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            return Outcome(ok: true, message: String(localized: "已加到 Claude Desktop，重新打开 Claude Desktop 后就能用。"))
        } catch {
            return Outcome(ok: false, message: String(localized: "没有加到 Claude Desktop：\(error.localizedDescription)"))
        }
    }
}

/// 会议链接（design §44.5）：shiyin://open?meeting=<id>&t=<秒数>
enum MeetingLink {
    static func parse(_ url: URL) -> (meetingId: Int64, seconds: Double?)? {
        guard url.scheme == "shiyin", url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "meeting" })?.value.flatMap({ Int64($0) }) else { return nil }
        return (id, items.first { $0.name == "t" }?.value.flatMap { Double($0) }.map { max(0, $0) })
    }
}
