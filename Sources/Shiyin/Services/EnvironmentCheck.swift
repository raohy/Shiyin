import AVFoundation
import Foundation

/// 环境检查（设置 → 模型与保存空间、首次使用引导）。第三版不需要 ffmpeg、Python。
struct EnvironmentStatus: Equatable {
    struct Item: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var ok: Bool
        var detail: String
        var fix: String
        var required: Bool
    }

    var items: [Item]

    @MainActor
    static func check(models: ModelStore) -> EnvironmentStatus {
        let claude = Paths.findTool("claude")
        let codexTool = Paths.locateTool("codex")
        let codex = codexTool?.url
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        // 正式转录用企业服务器：这台 Mac 不用转录模型（R50.7）
        let server = AppSettings.usesEnterpriseTranscription
        var items: [Item] = []
        if let account = EnterpriseServer.shared.account {
            let signedIn = EnterpriseServer.shared.isSignedIn
            items.append(Item(name: String(localized: "企业服务器"), ok: signedIn,
                              detail: String(localized: "已登录 \(account.email)（\(account.serverName)）"),
                              fix: String(localized: "登录已失效：到「高级 → 企业服务器」重新登录"), required: server))
        }
        // 第一项是默认会议语言的模型（Qwen3-ASR 或 Breeze，design §32.6、§41.3）；默认语言用 large-v3-turbo 时看中文的
        let defaultLanguage = AppSettings.defaultMeetingLanguage
        let main = defaultLanguage.usesTurbo ? MeetingLanguage.zh : defaultLanguage
        let qwen = ModelStore.transcription(for: main) == .qwen
        return EnvironmentStatus(items: items + [
            // 默认开日文会议的人不一定需要中文、英文的模型
            Item(name: !qwen ? String(localized: "转录模型 Breeze ASR 25") : String(localized: "转录模型 Qwen3-ASR 1.7B"),
                 ok: models.isInstalled(transcriptionFor: main) || AppSettings.useSystemTranscriber || server,
                 detail: server && !models.isInstalled(transcriptionFor: main) ? String(localized: "没有下载，正式转录用企业服务器") : models.isInstalled(transcriptionFor: main)
                     ? (!qwen ? String(localized: "已下载（1.66 GB）") : String(localized: "已下载（2.5 GB）")) : AppSettings.useSystemTranscriber ? String(localized: "没有下载，正式转录使用 macOS 内置识别") : String(localized: "还没下载"),
                 fix: String(localized: "到设置的「录音与转录」下载，或把正式转录改成 macOS 内置"),
                 required: !defaultLanguage.usesTurbo && !server),
            Item(name: String(localized: "\(MeetingLanguage.uiNames(model: "turbo"))转录模型"), ok: models.isInstalled(.japanese) || AppSettings.useSystemTranscriber || server,
                 detail: models.isInstalled(.japanese) ? String(localized: "已下载（574 MB）")
                     : server ? String(localized: "没有下载，正式转录用企业服务器")
                     : AppSettings.useSystemTranscriber ? String(localized: "没有下载，正式转录使用 macOS 内置识别")
                     : String(localized: "还没下载，第一次转录\(MeetingLanguage.uiNames(model: "turbo"))会议时会自动下载"),
                 fix: String(localized: "到设置的「录音与转录」下载"), required: defaultLanguage.usesTurbo && !AppSettings.useSystemTranscriber && !server),
            Item(name: String(localized: "语言检测模型"), ok: models.isInstalled(.languageDetection) || !AppSettings.autoDetectLanguage,
                 detail: models.isInstalled(.languageDetection) ? String(localized: "已下载（60 MB）")
                     : AppSettings.autoDetectLanguage ? String(localized: "还没下载，下载好之前录音不会自动检测语言") : String(localized: "没有开自动检测会议语言"),
                 fix: String(localized: "到设置的「录音与转录」下载"), required: false),
            Item(name: String(localized: "说话者识别模型"), ok: models.diarizerState == .installed,
                 detail: models.diarizerState == .installed ? String(localized: "已下载") : String(localized: "还没下载"), fix: String(localized: "到设置的「录音与转录」下载"), required: false),
            Item(name: String(localized: "麦克风权限"), ok: mic == .authorized,
                 detail: mic == .authorized ? String(localized: "已允许") : mic == .notDetermined ? String(localized: "还没询问") : String(localized: "被拒绝"),
                 fix: String(localized: "第一次录音时会询问；被拒绝的话到「系统设置 → 隐私与安全性 → 麦克风」打开拾音"), required: false),
            Item(name: "claude CLI", ok: claude != nil, detail: claude?.path ?? String(localized: "找不到"),
                 // 只有 Claude 桌面版：拾音不用桌面版里的那一份，要另外装（R56）
                 fix: claude == nil && DesktopApps.hasClaude
                     ? String(localized: "有 Claude 桌面版，但拾音要另外安装 Claude Code（命令行版）：在终端执行 \(ClaudeCodeInstallHint.command)，再执行 claude 登录")
                     : String(localized: "整理工具选 Claude 时需要：安装 Claude Code 并在终端执行 claude 登录"), required: false),
            // 桌面版附的 codex 写出是哪个 app 的（R55.3）
            Item(name: "codex CLI", ok: codex != nil,
                 detail: codexTool?.desktopApp.map { String(localized: "\($0) 附的 codex") } ?? codex?.path ?? String(localized: "找不到"),
                 fix: String(localized: "整理工具选 Codex 时需要：安装 Codex CLI 并执行 codex login"), required: false),
            Item(name: "Anthropic API key", ok: Keychain.exists("anthropic"),
                 detail: Keychain.exists("anthropic") ? String(localized: "已保存在钥匙串") : String(localized: "没有填"), fix: String(localized: "整理工具选 Anthropic API 时需要"), required: false),
            Item(name: "OpenAI API key", ok: Keychain.exists("openai"),
                 detail: Keychain.exists("openai") ? String(localized: "已保存在钥匙串") : String(localized: "没有填"), fix: String(localized: "整理工具选 OpenAI API 时需要"), required: false),
            Item(name: "Gemini API key", ok: Keychain.exists("gemini"),
                 detail: Keychain.exists("gemini") ? String(localized: "已保存在钥匙串") : String(localized: "没有填"), fix: String(localized: "整理工具选 Gemini API 时需要"), required: false),
            compatibleItem(),
        ])
    }

    /// OpenAI 兼容 API：有没有填网址和模型（design §19.4）
    @MainActor
    private static func compatibleItem() -> Item {
        let url = OpenAICompatibleAPI.normalized(OpenAICompatibleAPI.savedBaseURL)
        let model = UserDefaults.standard.string(forKey: LLMProvider.openaiCompatible.modelKey) ?? ""
        let ok = url != nil && !model.isEmpty
        return Item(name: String(localized: "OpenAI 兼容 API"), ok: ok,
                    detail: ok ? "\(url?.host(percentEncoded: false) ?? "")・\(model)" : String(localized: "没有填网址或模型"),   // l10n-skip
                    fix: String(localized: "整理工具选 OpenAI 兼容 API 时需要：到「设置 → 整理工具」填网址和模型"), required: false)
    }
}
