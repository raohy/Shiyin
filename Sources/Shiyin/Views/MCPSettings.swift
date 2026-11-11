import SwiftUI

/// 设置「高级」的「AI 工具（MCP）」（design §44.4）：开关、加到 Claude Code、Codex、Claude Desktop、复制设置
struct MCPSettings: View {
    @AppStorage(AppSettings.mcpEnabledKey) private var enabled = false
    @State private var hasClaude = false
    @State private var hasCodex = false
    @State private var hasDesktop = false
    @State private var outcome: MCPSetup.Outcome?
    @State private var busy = false

    /// 公司的企业服务器关掉了（R69.6）
    private var blocked: Bool { EnterpriseServer.shared.account?.mcp == false }

    var body: some View {
        Toggle("让 AI 工具读取会议", isOn: blocked ? .constant(false) : $enabled)
            .disabled(blocked)
            .onChange(of: enabled) { _, on in
                outcome = nil
                guard on else { return }
                do { try MCPSetup.installLauncher() } catch let error as MCPSetup.SetupError {
                    outcome = MCPSetup.Outcome(ok: false, message: error.localizedDescription)
                } catch {}
            }
            // 进到设置页时找一次（找 claude、codex 会读文件系统，不在每次重画时做）
            .task {
                hasClaude = Paths.locateTool("claude") != nil
                hasCodex = Paths.locateTool("codex") != nil
                hasDesktop = MCPSetup.claudeDesktopInstalled
            }
        Group {
            if blocked {
                Text("公司的企业服务器关掉了这个功能。")
            } else {
                Text("Claude Code、Claude Desktop、Codex 等支持 MCP 的 AI 工具可以搜索、读你的会议记录和逐字稿（只能读、不能改），拾音不用开着。读到的内容会交给那个 AI 工具处理，跟整理会议记录一样会离开这台电脑。")
            }
        }
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if enabled && !blocked {
            HStack {
                Button("加到 Claude Code") { run { await MCPSetup.addToClaudeCode() } }
                    .disabled(busy || !hasClaude)
                Button("加到 Codex") { run { await MCPSetup.addToCodex() } }
                    .disabled(busy || !hasCodex)
                Button("加到 Claude Desktop") { run { MCPSetup.addToClaudeDesktop() } }
                    .disabled(busy || !hasDesktop)
                // 「复制」在翻译表是 Duplicate（复制一份模板），这里是 Copy
                Menu(MeetingLanguage.ui(zh: "复制", en: "Copy")) {
                    Button("复制 Claude Code 命令") { copy(.claudeCodeCommand) }
                    Button("复制设置（JSON）") { copy(.configJSON) }
                }
                .fixedSize()
                if busy { ProgressView().controlSize(.small) }
            }
            if let missing { Text(missing).font(.caption).foregroundStyle(.secondary) }
            if let outcome {
                Text(outcome.message)
                    .font(.callout)
                    .foregroundStyle(outcome.ok ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// 这台 Mac 上找不到的工具
    private var missing: String? {
        var names: [String] = []
        if !hasClaude { names.append("claude") }
        if !hasCodex { names.append("codex") }
        if !hasDesktop { names.append("Claude Desktop") }
        guard !names.isEmpty else { return nil }
        return String(localized: "这台 Mac 上找不到 \(ListFormatter.localizedString(byJoining: names))；其他支持 MCP 的工具可以用「复制」自己粘贴设置。")
    }

    private func run(_ action: @escaping () async -> MCPSetup.Outcome) {
        busy = true
        outcome = nil
        Task {
            let result = await action()
            outcome = result
            busy = false
        }
    }

    private func copy(_ item: MCPSetup.CopyItem) {
        guard !MCPSetup.isTranslocated else {
            outcome = MCPSetup.Outcome(ok: false, message: MCPSetup.SetupError.translocated.localizedDescription)
            return
        }
        MCPSetup.copy(item)
        outcome = MCPSetup.Outcome(ok: true, message: String(localized: "已复制"))
    }
}
