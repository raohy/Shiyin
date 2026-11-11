import AVFoundation
import SwiftUI
import UserNotifications

/// 首次使用引导（design §33.4、R44.6）：欢迎使用拾音（含权限）→ 整理工具 → 准备好了，模型在背景下载。每一步都可以略过。
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasSeenGuide") private var hasSeenGuide = false
    @AppStorage(AppSettings.providerKey) private var storedProvider = ""
    @State private var step: Int
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var notificationsAllowed: Bool?
    @State private var speechInstalled: Bool?
    @State private var speechInstalling = false
    @State private var apiKey = ""
    @State private var keyError: String?
    /// 整理工具那一步的第一段「你平常用哪个 AI？」（R44.6、design §33.4）：claude、chatgpt、gemini、other、none；不存，只用来列第二段的选项
    @State private var usual: String?
    /// 第二段选的整理工具（R45.2、design §34.3）：选了不等于设置好，准备好（登录了、存了 key）才写进设置
    @State private var pending: LLMProvider?
    @State private var setup: ProviderSetup = .idle
    /// Claude Code 安装说明的「重新检查」：重新找 claude
    @State private var toolRecheck = 0

    private enum ProviderSetup: Equatable {
        case idle, checkingLogin, notLoggedIn, needsKey, needsCompat, testing
        case tested(ok: Bool, message: String)
    }

    /// startStep：DEBUG 的 preview 命令直接打开某一步（design §19.5）
    init(startStep: Int = 0) { _step = State(initialValue: startStep) }

    /// 三步（R44.6、design §33.4、D111）：权限（开头是原本欢迎页的三句话）、整理工具（先问平常用哪个 AI）、开始（模型在背景下载）
    private let titles = [String(localized: "欢迎使用拾音"), String(localized: "整理工具"), String(localized: "准备好了")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(titles.indices, id: \.self) { i in
                    Capsule().fill(i <= step ? Color.celadon : Color.secondary.opacity(0.25)).frame(height: 4)
                }
            }
            .padding(.bottom, 24)
            Text(titles[step]).font(.songti(28))
                .padding(.bottom, 12)
            Group {
                switch step {
                case 0: permissions
                case 1: providers
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if step > 0 && step < titles.count - 1 { Button("上一步") { step -= 1 } }
                Spacer()
                if step < titles.count - 1 {
                    Button("略过") { step += 1 }.buttonStyle(.borderless)
                    Button("下一步") { step += 1 }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button("开始使用") { finish() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(32)
        .frame(width: 600, height: 560)
        .tint(.celadon)
        .onAppear {
            // 模型从引导打开就在背景下载，不占一步（R44.6）；正式转录选了 macOS 内置就不用
            // 转录用企业服务器时不用下载（R50.7）
            if !AppSettings.useSystemTranscriber && !AppSettings.usesEnterpriseTranscription {
                model.models.autoStartTranscription(for: AppSettings.defaultMeetingLanguage)
            }
            if AppSettings.autoDetectLanguage { model.models.autoStart(.languageDetection) }
            if model.models.diarizerState == .missing { model.models.prepareDiarizer() }
        }
        .task {
            speechInstalled = await LiveTranscriber.isLocaleInstalled(AppSettings.defaultMeetingLanguage)
            // 已经允许或拒绝过通知的话直接显示，不要再显示「允许」
            switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: notificationsAllowed = true
            case .denied: notificationsAllowed = false
            default: break
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 原欢迎页的重点，三行（R44.6）
            VStack(alignment: .leading, spacing: 6) {
                Label("录下来：现场会议或在线会议，录音时就有实时逐字稿。", systemImage: "waveform")
                Label("转成逐字稿：在这台 Mac 上转录、分辨说话者，不会上传。", systemImage: "lock")
                Label("整理成记录：用你选的 AI 整理成摘要、决议和待办，只送逐字稿文字。", systemImage: "text.bubble")
            }
            .padding(.bottom, 4)
            permissionRow(icon: "mic", title: String(localized: "麦克风"), detail: String(localized: "录现场会议或你自己的声音。"),
                          status: micStatus == .authorized ? String(localized: "已允许") : micStatus == .denied ? String(localized: "被拒绝") : nil) {
                if micStatus == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        Task { @MainActor in micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
                    }
                } else {
                    Recorder.openPrivacySettings()
                }
            }
            permissionRow(icon: "bell", title: String(localized: "通知"), detail: String(localized: "转录完成、会议记录整理好时通知你。"),
                          status: notificationsAllowed.map { $0 ? String(localized: "已允许") : String(localized: "被拒绝") }) {
                if notificationsAllowed == false {
                    // 被拒绝之后再要权限不会有反应，要到系统设置打开
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                    return
                }
                Task {
                    let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                    notificationsAllowed = granted
                }
            }
            // 「录制系统音频」不放按钮（画面查看 O-2）：macOS 的清单要等拾音第一次录电脑声音之后才会出现拾音
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "speaker.wave.2").font(.title2).foregroundStyle(Color.celadon).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text("录制系统音频").font(.headline)
                    Text("录在线会议对方的声音用。第一次选「麦克风＋电脑声音」录音时 macOS 会询问，按允许就好。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func permissionRow(icon: String, title: String, detail: String, status: String?,
                               buttonTitle: String = String(localized: "允许"), action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.celadon).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let status, status == String(localized: "已允许") {
                Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(Color.celadon)
            } else {
                Button(status == String(localized: "被拒绝") ? String(localized: "打开系统设置") : buttonTitle, action: action)
            }
        }
    }

    private var primaryModel: ModelStore.Model { ModelStore.transcription(for: AppSettings.defaultMeetingLanguage) }

    /// 整理工具（R44.6、D111）：先问「你平常用哪个 AI？」，选了才列对应的一到两个选项，每个一行写要不要钱。
    /// 选了不等于设置好（R45.2）：准备好才写进设置，写进去时测一次
    private var providers: some View {
        _ = toolRecheck
        let claude = Paths.findTool("claude"), codex = Paths.findTool("codex")
        let usualValue = usual ?? guessedUsual(claude: claude, codex: codex)
        let list = options(for: usualValue, claude: claude, codex: codex)
        let shown = pending ?? shownProvider(in: list)
        return VStack(alignment: .leading, spacing: 14) {
            Text("会议记录要用哪个 AI 整理？之后可以在设置里更改。").foregroundStyle(.secondary)
            Picker("你平常用哪个 AI？", selection: Binding(get: { usualValue }, set: { pick($0, claude: claude, codex: codex) })) {
                Text("Claude").tag("claude")
                Text("ChatGPT").tag("chatgpt")
                Text("Gemini").tag("gemini")
                Text("其他").tag("other")
                Text("先不用").tag("none")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // 只有 Claude 桌面版：说明怎么装 Claude Code（R56.2）
            if usualValue == "claude" && claude == nil && DesktopApps.hasClaude {
                ClaudeCodeInstallHint {
                    DesktopApps.clearCache()
                    toolRecheck += 1
                }
            }
            Picker("整理工具", selection: Binding(get: { shown?.rawValue ?? "" }, set: { choose(LLMProvider(rawValue: $0)) })) {
                ForEach(list, id: \.provider) { option in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title)
                        Text(option.cost).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(option.provider.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if let shown { setupStatus(shown) }
        }
    }

    /// 选了第二段的选项之后的状态：登录、API key、测试结果
    @ViewBuilder
    private func setupStatus(_ provider: LLMProvider) -> some View {
        let state = pending == provider ? setup : .idle
        if provider == .openaiCompatible {
            // OpenAI 兼容 API 要填网址、模型，引导里只提示（design §19.4）
            Text("网址、API key 和模型请在完成引导后，到「设置 → 整理工具」填写。填好之前不会整理。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if provider.usesAPIKey {
            HStack {
                SecureField("粘贴 API key", text: $apiKey).textFieldStyle(.roundedBorder)
                Button("保存") { saveKey(provider) }
                    .disabled(apiKey.isEmpty)
            }
            if let keyError {
                Text(keyError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if Keychain.exists(provider.keychainAccount) {
                Label("已保存在钥匙串", systemImage: "checkmark.circle.fill").foregroundStyle(Color.celadon)
            } else if state == .needsKey {
                Text("粘贴 API key 并按「保存」后才会用 \(provider.shortLabel) 整理；没有 key 的话可以选「先不用」。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let url = provider.apiKeyURL { Link("取得 API key", destination: url) }
        } else if provider == .claude || provider == .codex {
            let name = provider == .codex ? "Codex" : "Claude Code"
            if state == .checkingLogin {
                Text("检查登录状态…").foregroundStyle(.secondary)
            } else if state == .notLoggedIn {
                Text("\(name) 还没登录，登录之后才会用它整理。").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack {
                    // 桌面版附的 codex：打开那个 app 登录（R55.3）
                    Button(CLILogin.desktopApp(provider).map { String(localized: "打开 \($0) 登录") } ?? String(localized: "登录 \(name)")) {
                        CLILogin.openLogin(provider)
                    }
                    Button("重新检查") { choose(provider) }
                }
            }
        }
        switch state {
        case .testing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("测试中…").foregroundStyle(.secondary)
            }
        case .tested(let ok, let message):
            Label(message, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.celadon : Color.red).fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private struct ProviderOption { var provider: LLMProvider; var title: String; var cost: String }

    /// 还没选第一段时：照目前的整理工具推回去（有 claude CLI 就是 Claude…），没有就「先不用」
    private func guessedUsual(claude: URL?, codex: URL?) -> String {
        switch LLMProvider(rawValue: storedProvider) ?? (claude != nil ? .claude : codex != nil ? .codex : .none) {
        case .claude, .anthropic: return "claude"
        case .codex, .openai: return "chatgpt"
        case .gemini: return "gemini"
        case .openaiCompatible, .enterprise: return "other"
        case .none: return "none"
        }
    }

    /// 还没选第二段时显示的选项：设置里的整理工具（没选过就是自动选到的 CLI）；没选过也没有 CLI 时不选（不是「不整理」）
    private func shownProvider(in list: [ProviderOption]) -> LLMProvider? {
        guard let current = LLMProvider(rawValue: storedProvider) ?? Optional(AppSettings.detectedProvider),
              current != .none || !storedProvider.isEmpty else { return nil }
        return list.contains { $0.provider == current } ? current : nil
    }

    /// 选了第一段：只筛第二段的选项，第一个选项当作选了（不直接写设置，R45.2）
    private func pick(_ value: String, claude: URL?, codex: URL?) {
        usual = value
        choose(options(for: value, claude: claude, codex: codex).first?.provider)
    }

    private func choose(_ provider: LLMProvider?) {
        guard let provider else { return }
        pending = provider
        setup = .idle
        keyError = nil
        Task { await evaluate(provider) }
    }

    /// 准备好了才写进设置（R45.2、design §34.3）
    private func evaluate(_ provider: LLMProvider) async {
        switch provider {
        case .none:
            storedProvider = LLMProvider.none.rawValue
        case .claude, .codex:
            setup = .checkingLogin
            let status = await CLILogin.refresh(provider)
            guard pending == provider else { return }
            if status?.loggedIn == false { setup = .notLoggedIn } else { await commit(provider) }
        case .anthropic, .openai, .gemini:
            if Keychain.exists(provider.keychainAccount) { await commit(provider) } else { setup = .needsKey }
        case .openaiCompatible:
            let url = UserDefaults.standard.string(forKey: OpenAICompatibleAPI.baseURLKey) ?? ""
            let model = UserDefaults.standard.string(forKey: provider.modelKey) ?? ""
            if OpenAICompatibleAPI.normalized(url) != nil && !model.isEmpty { await commit(provider) } else { setup = .needsCompat }
        case .enterprise:
            await commit(provider)
        }
    }

    /// 写进设置并测一次；失败是设置问题（key 错误、没登录…）就改回原本的设置（R45.2）
    private func commit(_ provider: LLMProvider) async {
        let previous = storedProvider
        storedProvider = provider.rawValue
        setup = .testing
        do {
            let seconds = try await SummarizerTest.run(provider: provider, model: SummarizerTest.model(for: provider))
            guard pending == provider else { return }
            setup = .tested(ok: true, message: String(localized: "可以使用（\(seconds) 秒）"))
        } catch {
            let setupProblem = (error as? LLMError)?.isSetupProblem == true
            if setupProblem && storedProvider == provider.rawValue { storedProvider = previous }
            guard pending == provider else { return }
            setup = .tested(ok: false, message: setupProblem
                ? String(localized: "\(error.localizedDescription)（还没改用 \(provider.shortLabel)）")
                : String(localized: "\(error.localizedDescription)（之后可以在设置 → 整理工具重新测试）"))
        }
    }

    private func saveKey(_ provider: LLMProvider) {
        do {
            try Keychain.set(provider.keychainAccount, apiKey)
            apiKey = ""
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
        model.refreshEnvironment()
        if keyError == nil && pending == provider { Task { await commit(provider) } }
        else if keyError == nil && pending == nil { choose(provider) }
    }

    private func options(for usual: String, claude: URL?, codex: URL?) -> [ProviderOption] {
        let subscription = String(localized: "用你的订阅，不另外收费")
        let api = String(localized: "要 API key，依用量计费，一小时的会议通常不到人民币 3 元（2026-10 估）")
        switch usual {
        case "claude":
            var list: [ProviderOption] = []
            if claude != nil { list.append(.init(provider: .claude, title: String(localized: "Claude Code（这台 Mac 已经装了 claude CLI）"), cost: subscription)) }
            list.append(.init(provider: .anthropic, title: String(localized: "Anthropic API"), cost: api))
            return list
        case "chatgpt":
            var list: [ProviderOption] = []
            if codex != nil {
                // 桌面版附的 codex（R55.3）
                let title = CLILogin.desktopApp(.codex).map { String(localized: "Codex（使用 \($0) 附的 codex）") }
                    ?? String(localized: "Codex（这台 Mac 已经装了 codex CLI）")
                list.append(.init(provider: .codex, title: title, cost: subscription))
            }
            list.append(.init(provider: .openai, title: String(localized: "OpenAI API"), cost: api))
            return list
        case "gemini":
            return [.init(provider: .gemini, title: String(localized: "Gemini API"), cost: api)]
        case "other":
            // 登录了企业服务器、服务器有提供整理：排第一个（R51.1）
            let enterprise: [ProviderOption] = EnterpriseServer.shared.account?.llm == true
                ? [.init(provider: .enterprise, title: String(localized: "企业服务器（\(EnterpriseServer.shared.account?.serverName ?? "")）"),
                         cost: String(localized: "公司提供，不用自己的 key"))] : []
            return enterprise + [.init(provider: .openaiCompatible, title: String(localized: "OpenAI 兼容 API"), cost: String(localized: "Groq、OpenRouter、Ollama、LM Studio；网址和 key 到设置填"))]
        default:
            return [.init(provider: .none, title: String(localized: "不整理，只要逐字稿"), cost: String(localized: "随时可以到设置选"))]
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("按「开始使用」后会打开使用说明，介绍录音、实时逐字稿、会议记录和导出的用法。")
                .fixedSize(horizontal: false, vertical: true)
            // 模型在背景下载的状态，一行（R44.6）
            if AppSettings.usesEnterpriseTranscription {
                Label("正式转录用企业服务器（\(EnterpriseServer.shared.account?.serverName ?? "")），这台 Mac 不用下载转录模型。", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.celadon).fixedSize(horizontal: false, vertical: true)
            } else if !AppSettings.useSystemTranscriber {
                let state = model.models.combinedState(primaryModel)
                switch state {
                case .installed:
                    Label("转录模型已经就绪。", systemImage: "checkmark.circle.fill").foregroundStyle(Color.celadon)
                case .downloading(let received, let total):
                    Label(String(localized: "转录模型下载中 \(total > 0 ? Int(Double(received) / Double(total) * 100) : 0)%，下载好之前先用 macOS 内置识别转录。"), systemImage: "arrow.down.circle")
                        .foregroundStyle(Color.signal).fixedSize(horizontal: false, vertical: true)
                default:
                    Label("转录模型还没下载好，会先用 macOS 内置识别转录；可以到「设置 → 录音与转录」下载，用模型转录比较准。", systemImage: "arrow.down.circle")
                        .foregroundStyle(Color.signal).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("之后可以在「设置 → 高级」重新显示这个引导。").foregroundStyle(.secondary)
        }
    }

    private func finish() {
        hasCompletedOnboarding = true
        hasSeenGuide = true
        model.refreshEnvironment()
        openWindow(id: "guide")
        dismiss()
    }
}
