import Foundation
import os

/// 本地 MCP 服务器（design §44.1、D147）：`Shiyin --mcp`，stdio 一行一个 JSON-RPC 2.0 消息。
/// 只做 initialize、ping、tools/list、tools/call；stdout 只写协定消息，log 不写参数和会议内容（N7）
enum MCPServer {
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let fallbackProtocolVersion = "2025-06-18"
    private static let mlog = Logger(subsystem: "com.weiwei.shiyin", category: "mcp")

    static func run() -> Never {
        // 客户端先关掉 stdout 的管线时，写入会收到 SIGPIPE；忽略之后写入失败，读到 stdin 结束就离开
        signal(SIGPIPE, SIG_IGN)
        mlog.info("mcp server started")
        while let line = readLine(strippingNewline: true) {
            if let reply = handle(line) { send(reply) }
        }
        mlog.info("mcp server stopped")
        exit(0)
    }

    /// 处理一行，回传要写出的回应；通知、客户端的回应不用回
    static func handle(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else {
            return failure(NSNull(), -32700, "Parse error")
        }
        guard let message = object as? [String: Any] else { return failure(NSNull(), -32600, "Invalid request") }
        guard let method = message["method"] as? String else { return nil }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return success(id, [
                "protocolVersion": protocolVersions.contains(asked) ? asked : fallbackProtocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "shiyin", "title": "Shiyin", "version": version],
                "instructions": MCPTools.instructions,
            ])
        case "ping":
            return success(id, [:])
        case "tools/list":
            return success(id, ["tools": MCPTools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            guard MCPTools.names.contains(name) else { return failure(id, -32602, "Unknown tool: \(name)") }
            let started = Date()
            let result = MCPTools.run(name, params["arguments"] as? [String: Any] ?? [:])
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            mlog.info("tool \(name, privacy: .public): \(result.isError ? "error" : "ok", privacy: .public), \(result.text.utf16.count) chars, \(ms) ms")
            return success(id, ["content": [["type": "text", "text": result.text]], "isError": result.isError])
        default:
            return failure(id, -32601, "Method not found: \(method)")
        }
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private static func success(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func failure(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func send(_ reply: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}
