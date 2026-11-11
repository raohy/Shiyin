import Foundation

// 进入点（design §44.1）：`Shiyin --mcp` 是给 AI 工具用的本地 MCP 服务器，在 SwiftUI、AppModel 启动之前分流，
// 不跑 app 的启动流程（复原录音、工作队列、自动整理、检查更新）、不出现在 Dock
if CommandLine.arguments.dropFirst().contains("--mcp") {
    MCPServer.run()
}
MainActor.assumeIsolated { ShiyinApp.main() }
