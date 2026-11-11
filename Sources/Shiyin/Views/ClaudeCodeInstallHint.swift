import AppKit
import SwiftUI

/// 只有 Claude 桌面版、没有 Claude Code 时的说明（R56.2、design §37.3）：拾音不用桌面版里的那一份，请用户另外装命令行版
struct ClaudeCodeInstallHint: View {
    static let command = "curl -fsSL https://claude.ai/install.sh | bash"
    static let guide = URL(string: "https://code.claude.com/docs/en/setup")!

    /// 「重新检查」：装好之后让画面重新找 claude、查登录
    var onRecheck: () -> Void
    @State private var copied = false

    /// 设置页、引导要不要显示：claude 找不到、有 Claude 桌面版
    static var applies: Bool { Paths.findTool("claude") == nil && DesktopApps.hasClaude }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("你有 Claude 桌面版：另外安装 Claude Code（命令行版）之后，拾音就能用你的 Claude 订阅（Pro 以上）整理。")
                .fixedSize(horizontal: false, vertical: true)
            Text("打开「终端」，粘贴这一行安装：").foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(verbatim: Self.command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                // 「复制」的英文在别处是 Duplicate（复制会议），这里是复制到剪贴板
                Button(copied ? String(localized: "已复制") : MeetingLanguage.ui(zh: "复制", en: "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.command, forType: .string)
                    copied = true
                }
            }
            HStack(spacing: 12) {
                Link("安装说明", destination: Self.guide)
                Button("重新检查") {
                    copied = false
                    onRecheck()
                }
            }
            Text("装好之后在终端执行 claude 登录，再按「重新检查」。").font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
