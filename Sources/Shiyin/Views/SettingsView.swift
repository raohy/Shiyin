import SwiftUI

/// 设置窗口（T-F2）：整理工具与密钥、模板、词汇表、录音、模型与保存空间、高级
struct SettingsView: View {
    #if DEBUG
    /// shiyinctl preview settings <标签页>：预览窗口一开始停在哪个标签页（0 整理工具、1 录音与转录、2 说话者与词汇、3 高级）
    nonisolated(unsafe) static var previewTab = 0
    #endif
    @State private var tab: Int = {
        #if DEBUG
        return SettingsView.previewTab
        #else
        return 0
        #endif
    }()

    var body: some View {
        // 四个标签页（R44.5，design §33.3、D110）：只搬位置、加分组，每个项目和存的键都没变
        TabView(selection: $tab) {
            ProviderSettings().tabItem { Label("整理工具", systemImage: "sparkles") }.tag(0)
            RecordingSettings().tabItem { Label("录音与转录", systemImage: "mic") }.tag(1)
            NamesSettings().tabItem { Label("说话者与词汇", systemImage: "person.text.rectangle") }.tag(2)
            AdvancedSettings().tabItem { Label("高级", systemImage: "gearshape.2") }.tag(3)
        }
        .frame(width: 640, height: 520)
        .tint(.celadon)
    }
}

// MARK: 整理工具与密钥（R6.1）

struct ProviderSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.providerKey) private var storedProvider = ""
    @AppStorage(AppSettings.autoSummarizeKey) private var autoSummarize = true
    @AppStorage(AppSettings.correctTranscriptKey) private var correctTranscript = true
    @State private var modelName = ""
    @State private var baseURL = ""
    @State private var key = ""
    @State private var keySaved = false
    @State private var keyError: String?
    @State private var availableModels: [String] = []
    // 「选择」的模型清单：按了才取（取的时候要读 key，可能跳出钥匙串的确认，design §22.1）
    @State private var pickingModel = false
    @State private var loadingModels = false
    @State private var modelListError: String?
    @State private var testing = false
    @State private var testResult: (ok: Bool, message: String)?
    @State private var login: CLILogin.Status?
    @State private var checkingLogin = false
    @State private var recheckCount = 0
    /// 公司提供的模型（R51.1）：nil 是还没取到或取不到
    @State private var companyModels: [EnterpriseAPI.Model]?

    /// 菜单显示的值：没选过时显示自动选到的那一个，找不到 CLI 时是「之后再设置」（空字符串）；改了才写进设置（R35.3）
    private var provider: String {
        if LLMProvider(rawValue: storedProvider) != nil { return storedProvider }
        let detected = AppSettings.detectedProvider
        return detected == .none ? "" : detected.rawValue
    }
    private var current: LLMProvider { LLMProvider(rawValue: provider) ?? .none }

    var body: some View {
        Form {
            Picker("整理工具", selection: Binding(get: { provider }, set: { storedProvider = $0 })) {
                // 这台 Mac 没有 claude、codex 时才有：选它等于清掉设置，回到「还没设置」
                if AppSettings.detectedProvider == .none { Text("之后再设置（先不整理）").tag("") }
                // 没安装的 claude、codex 不能选（R45.3）；目前选的就是它时照样显示
                // 公司：登录了企业服务器、公司有提供整理才出现（R51.1、D124；登录在高级）
                ForEach(LLMProvider.allCases.filter { $0 != .enterprise || EnterpriseServer.shared.account?.llm == true || $0 == current }) { item in
                    let missing = (item == .claude || item == .codex) && Paths.findTool(item == .claude ? "claude" : "codex") == nil
                    Text(missing ? String(localized: "\(item.label)（没有安装）") : item == .enterprise ? companyLabel : item.label).tag(item.rawValue)
                        .selectionDisabled(missing && item != current)
                }
            }
            // 还没准备好：说原因，设置好之前不会自动整理（R45.3、design §34.3）
            if current != .none, let notice = problemNotice {
                Text(notice).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if current == .claude || current == .codex {
                LabeledContent("状态") {
                    HStack(spacing: 8) {
                        if Paths.findTool(current == .claude ? "claude" : "codex") == nil {
                            Text(current == .codex ? "这台 Mac 没有安装 codex：没有在用 Codex 的话，请改选 API"
                                 : showClaudeHint ? "这台 Mac 没有安装 Claude Code（命令行版），安装方法在下面"
                                 : "这台 Mac 没有安装 claude：没有在用 Claude Code 的话，请改选 API")
                                .foregroundStyle(.secondary)
                        } else if checkingLogin {
                            Text("检查登录状态…").foregroundStyle(.secondary)
                        } else if let login {
                            Text(login.loggedIn ? String(localized: "已登录 \(login.detail)") : String(localized: "没有登录"))
                                .foregroundStyle(login.loggedIn ? Color.celadon : Color.red)
                            if !login.loggedIn {
                                // 桌面版附的 codex：打开那个 app 登录（R55.3）
                                Button(desktopApp.map { String(localized: "打开 \($0) 登录") } ?? String(localized: "登录 \(current.shortLabel)")) {
                                    CLILogin.openLogin(current)
                                }
                            }
                        } else {
                            Text("已安装，看不出登录状态").foregroundStyle(.secondary)
                        }
                        Button { recheck() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("重新检查登录状态")
                            .disabled(checkingLogin)
                    }
                }
                // 用的是桌面版附的 codex：写出来，用户才知道没有另外装 CLI（R55.3）
                if let desktopApp {
                    Text("使用 \(desktopApp) 附的 codex（这台 Mac 没有另外安装 Codex CLI）")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if showClaudeHint {
                ClaudeCodeInstallHint { recheck() }
            }
            // OpenAI 兼容 API 的网址（design §19.3、§19.4）
            if current == .openaiCompatible {
                HStack {
                    TextField("网址", text: $baseURL, prompt: Text(verbatim: "https://api.groq.com/openai/v1"))
                    Menu("常用") {
                        ForEach(OpenAICompatibleAPI.presets, id: \.url) { preset in
                            Button { baseURL = preset.url } label: { Text(verbatim: "\(preset.name)  \(preset.url)") }
                        }
                    }
                    .fixedSize()
                }
                .onChange(of: baseURL) { _, value in
                    UserDefaults.standard.set(value, forKey: OpenAICompatibleAPI.baseURLKey)
                    availableModels = []
                    modelListError = nil
                }
                if !baseURL.trimmingCharacters(in: .whitespaces).isEmpty && OpenAICompatibleAPI.normalized(baseURL) == nil {
                    Text("网址要以 http:// 或 https:// 开头").font(.caption).foregroundStyle(.red)
                }
            }
            // 公司：模型由公司的后台决定，这里只显示（R51.1）
            if current == .enterprise && EnterpriseServer.shared.isSignedIn && EnterpriseServer.shared.account?.llm == true {
                companyModelRow
            }
            if current.usesAPIKey {
                SecureField("API key", text: $key, prompt: Text(keySaved ? "已保存在钥匙串（输入新的会取代）"
                                                                 : current.keyOptional ? "可以不填（本机的 Ollama、LM Studio 不需要）" : "粘贴 API key"))
                HStack {
                    Button("保存 key", action: saveKey)
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if keySaved {
                        Button("删除 key", role: .destructive) {
                            Keychain.delete(current.keychainAccount)
                            keySaved = false
                            availableModels = []
                            model.refreshEnvironment()
                        }
                    }
                }
                if let keyError {
                    Text(keyError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if let url = current.apiKeyURL { Link("取得 API key", destination: url) }
            }
            if current != .none && current != .enterprise {
                HStack {
                    TextField("模型", text: $modelName, prompt: Text(current == .openaiCompatible ? "必填"
                                                                    : current == .enterprise ? "留空使用公司设置的默认模型"
                                                                    : current.defaultModel.isEmpty ? "留空使用默认模型" : "默认：\(current.defaultModel)"))
                    if canListModels {
                        Button("选择", action: openModelPicker)
                            .popover(isPresented: $pickingModel, arrowEdge: .bottom) { modelList }
                    }
                }
                .onChange(of: modelName) { _, value in UserDefaults.standard.set(value, forKey: current.modelKey) }
            }
            // 测试：送一个很短的请求，确认登录、key、模型都能用（用户反馈：开完会才发现登录过期）
            if current != .none && (current != .enterprise || EnterpriseServer.shared.isSignedIn) {
                LabeledContent("测试") {
                    HStack(spacing: 8) {
                        if let testResult {
                            Text(testResult.message)
                                .foregroundStyle(testResult.ok ? Color.celadon : Color.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(testing ? "测试中…" : "测试整理工具") { Task { await test() } }
                            .disabled(testing)
                    }
                }
            }
            Toggle("转录完成后自动整理成会议记录", isOn: $autoSummarize)
                .disabled(current == .none)
            // 逐字稿校正（design §17.4）
            Toggle("转录完成后检查可能听错的字", isOn: $correctTranscript)
                .disabled(current == .none)
            Text("依词汇表和上下文找出可能听错的字，标在逐字稿里，你决定要不要改。不会自动改掉原文。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Section {
                Text(privacyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 模板是整理的一部分（R44.5、D110）：原本自己一个标签页
            Section(MeetingLanguage.ui(zh: "模板", en: "Templates")) {
                TemplateSettings().frame(height: 420)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: storedProvider) { _, _ in load() }
        // 在这页登录、重新登录之后取公司的模型
        .onChange(of: EnterpriseServer.shared.account) { _, account in
            guard current == .enterprise, account != nil else { return }
            Task {
                let models = await EnterpriseAPI.models()
                if current == .enterprise { companyModels = models }
            }
        }
        #if DEBUG
        .onChange(of: model.debugSettingsAction) { _, action in
            guard let action else { return }
            model.debugSettingsAction = nil
            if action.first == "pickmodel" { openModelPicker() }
            if action.first == "savekey", action.count > 1 { key = action[1]; saveKey() }
        }
        #endif
    }

    private func saveKey() {
        do {
            try Keychain.set(current.keychainAccount, key)
            key = ""
            keyError = nil
            // 刚存的 key 已经记在内存，取模型清单不会再问钥匙串
            refreshModels()
        } catch {
            keyError = error.localizedDescription
        }
        keySaved = Keychain.exists(current.keychainAccount)
        model.refreshEnvironment()
        // 存好 key 就测一次（R45.3）
        if keyError == nil && AppSettings.summarizerReady { Task { await test() } }
    }

    private func openModelPicker() {
        pickingModel = true
        if availableModels.isEmpty && !loadingModels { refreshModels() }
    }

    private func test() async {
        testing = true
        testResult = nil
        let tested = current
        let result: (Bool, String)
        do {
            let seconds = try await SummarizerTest.run(provider: tested, model: modelName)
            result = (true, String(localized: "可以使用（\(seconds) 秒）"))
        } catch {
            result = (false, error.localizedDescription)
        }
        // 测试期间换了整理工具：结果是旧工具的，不显示（换工具时 load() 已经重置状态）
        guard tested == current else { return }
        testResult = result
        testing = false
    }

    /// 用桌面版附的 codex 时是那个 app 的名称（R55.3）
    private var desktopApp: String? { current == .codex ? CLILogin.desktopApp(.codex) : nil }

    /// 只有 Claude 桌面版：说明怎么装 Claude Code（R56.2、R56.3）；已经在用别的整理工具的人不显示
    private var showClaudeHint: Bool {
        _ = recheckCount   // 按了「重新检查」要重新算
        return (current == .claude || AppSettings.needsProviderSetup) && ClaudeCodeInstallHint.applies
    }

    /// 「重新检查」：刚装好、刚移除的 CLI 和桌面版马上看得到，再查一次登录
    private func recheck() {
        DesktopApps.clearCache()
        recheckCount += 1
        model.refreshSummarizerProblem()
        Task { await checkLogin(userInitiated: true) }
    }

    /// userInitiated：用户按了「重新检查」，查到已登录就测一次（R45.3）；打开设置页时的自动检查不测（不花额度）
    private func checkLogin(userInitiated: Bool = false) async {
        guard current == .claude || current == .codex else { login = nil; return }
        checkingLogin = true
        let checked = current
        let status = await CLILogin.refresh(checked)
        guard checked == current else { return }   // 查的时候换了整理工具
        login = status
        checkingLogin = false
        if userInitiated && status?.loggedIn == true { await test() }
    }

    /// 菜单下面的红字（design §34.3）：没安装、没登录在「状态」那一列已经写了原因
    private var problemNotice: String? {
        switch model.summarizerProblem {
        case nil, .notChosen?, .off?: return nil
        case .notInstalled?, .notLoggedIn?: return String(localized: "设置好之前不会自动整理。")
        case .missingKey?: return String(localized: "还没有存 API key：粘贴之后按「保存 key」。设置好之前不会自动整理。")
        case .incomplete?: return String(localized: "还没有填网址或模型。设置好之前不会自动整理。")
        case .enterpriseSignedOut?: return String(localized: "公司的服务器还没登录或登录已失效：到「高级 → 企业服务器」登录。设置好之前不会自动整理。")
        case .enterpriseNoModels?: return String(localized: "公司的服务器还没有提供整理用的模型：请管理者在服务器后台的「整理模型」加上模型。")
        case .paused(_, let detail)?:
            let reason = MeetingLanguage.uiStored(detail.trimmingCharacters(in: CharacterSet(charactersIn: "。. ")))   // l10n-skip
            return String(localized: "上次整理失败：\(reason)。改好设置，或按「测试整理工具」成功之后，才会再自动整理。")
        }
    }

    private func load() {
        testResult = nil
        testing = false
        login = nil
        Task { await checkLogin() }
        modelName = UserDefaults.standard.string(forKey: current.modelKey) ?? ""
        companyModels = nil
        Task { await refreshCompany() }
        baseURL = UserDefaults.standard.string(forKey: OpenAICompatibleAPI.baseURLKey) ?? ""
        // 只看有没有存，不读出 key：打开设置页不能跳出钥匙串的确认（R18.7、R21.1）
        keySaved = current.usesAPIKey && Keychain.exists(current.keychainAccount)
        keyError = nil
        availableModels = []
        modelListError = nil
        loadingModels = false
    }

    /// 菜单上的「公司（示例公司）」
    private var companyLabel: String {
        let name = EnterpriseServer.shared.account?.serverName ?? ""
        return name.isEmpty ? LLMProvider.enterprise.label : String(localized: "公司（\(name)）")
    }

    /// 重新读服务器的信息（R51.5）：公司后来才提供整理，菜单就多「公司」；选的是公司时再取模型
    private func refreshCompany() async {
        guard EnterpriseServer.shared.isSignedIn else { return }
        await EnterpriseServer.shared.refreshInfo()
        guard current == .enterprise else { return }
        let models = await EnterpriseAPI.models()
        guard current == .enterprise else { return }
        companyModels = models
    }

    /// 公司提供的模型（R51.1、design §36.3）：「公司的默认」存空字符串；选过的不在清单里了就当成默认，设置不清掉
    @ViewBuilder private var companyModelRow: some View {
        if let models = companyModels, !models.isEmpty {
            let fallback = models.first { $0.isDefault } ?? models[0]
            if models.count == 1 {
                LabeledContent("模型") { Text(fallback.name) }
            } else {
                Picker("模型", selection: Binding(
                    get: { models.contains { $0.id == modelName } ? modelName : "" },
                    set: { modelName = $0; UserDefaults.standard.set($0, forKey: current.modelKey) })) {
                    Text("公司的默认（\(fallback.name)）").tag("")
                    ForEach(models) { item in Text(item.name).tag(item.id) }
                }
            }
        } else {
            LabeledContent("模型") {
                Text(companyModels == nil ? "正在取得公司的模型…" : "公司的默认").foregroundStyle(.secondary)
            }
        }
        Text("模型和 API key 由公司在服务器的后台设置。").font(.caption).foregroundStyle(.secondary)
    }

    /// 可以从清单选模型：API 要有存 key，OpenAI 兼容 API 要有网址
    private var canListModels: Bool {
        current == .openaiCompatible ? OpenAICompatibleAPI.normalized(baseURL) != nil
            : current == .enterprise ? EnterpriseServer.shared.isSignedIn : current.usesAPIKey && keySaved
    }

    /// 「选择」用的模型清单；取的时候换了整理工具就不用。
    /// 先读 key：macOS 没允许就显示原因，不再调用 listModels（不然会再问一次，design §22.1）
    private func refreshModels() {
        let checked = current
        loadingModels = true
        modelListError = nil
        Task {
            let result = await Task.detached { () -> Result<[String], Error> in
                do {
                    _ = try Keychain.read(checked.keychainAccount)
                    return .success(await LLMClient.listModels(checked))
                } catch {
                    return .failure(error)
                }
            }.value
            guard checked == current else { return }
            loadingModels = false
            switch result {
            case .success(let models): availableModels = models
            case .failure(let error): modelListError = error.localizedDescription
            }
        }
    }

    private var modelList: some View {
        Group {
            if loadingModels {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在取得模型清单…").foregroundStyle(.secondary)
                }
                .padding(14)
            } else if availableModels.isEmpty {
                Text(modelListError ?? String(localized: "取得不到模型清单，可以直接输入模型名称。"))
                    .foregroundStyle(modelListError == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 300, alignment: .leading)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(availableModels, id: \.self) { name in
                            Button {
                                modelName = name
                                pickingModel = false
                            } label: {
                                Text(name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(name == modelName ? Color.celadon.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    .padding(6)
                }
                .frame(width: 300, height: min(320, CGFloat(availableModels.count) * 24 + 16))
            }
        }
    }

    private var privacyText: String {
        switch current {
        case .none:
            return provider.isEmpty
                ? String(localized: "还没设置整理工具：录音、转录、逐字稿全部留在这台 Mac。选好整理工具之后，才会整理成会议记录。")
                : String(localized: "目前不整理：录音、转录、逐字稿全部留在这台 Mac。")
        case .claude, .anthropic:
            return String(localized: "整理、提问、猜说话者时会把逐字稿文字、你的笔记、词汇表和会议基本资料送到 Anthropic（Claude）。录音档不会送出。")
        case .codex, .openai:
            return String(localized: "整理、提问、猜说话者时会把逐字稿文字、你的笔记、词汇表和会议基本资料送到 OpenAI。录音档不会送出。")
        case .gemini:
            return String(localized: "整理、提问、猜说话者时会把逐字稿文字、你的笔记、词汇表和会议基本资料送到 Google（Gemini）。录音档不会送出。")
        case .enterprise:
            // 送到公司的服务器，再由公司设置的模型整理（R51.4、design §36.5）
            let host = EnterpriseServer.shared.host
            return host.isEmpty
                ? String(localized: "整理、提问、猜说话者时会把逐字稿文字、你的笔记、词汇表和会议基本资料送到公司的服务器，再由公司设置的模型整理。录音档不会因为整理而送出。")
                : String(localized: "整理、提问、猜说话者时会把逐字稿文字、你的笔记、词汇表和会议基本资料送到 \(host)（公司的服务器），再由公司设置的模型整理。录音档不会因为整理而送出。")
        case .openaiCompatible:
            // 说清楚送到哪一台主机；本机的服务不会离开电脑（design §19.3、R17.5）
            guard let url = OpenAICompatibleAPI.normalized(baseURL), let host = url.host(percentEncoded: false) else {
                return String(localized: "整理、提问、猜说话者时会把逐字稿文字、你的笔记、词汇表和会议基本资料送到你填的网址。录音档不会送出。")
            }
            if OpenAICompatibleAPI.isLocal(url) {
                return String(localized: "整理、提问、猜说话者时会把逐字稿文字、你的笔记、词汇表和会议基本资料送到这台 Mac 上的服务（\(host)），不会离开电脑。录音档不会送出。")
            }
            return url.scheme?.lowercased() == "http"
                ? String(localized: "整理、提问、猜说话者时会把逐字稿文字、你的笔记、词汇表和会议基本资料送到 \(host)。录音档不会送出。用 http 发送没有加密，建议改用 https。")
                : String(localized: "整理、提问、猜说话者时会把逐字稿文字、你的笔记、词汇表和会议基本资料送到 \(host)。录音档不会送出。")
        }
    }
}

// MARK: 模板（R6.2）

struct TemplateSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.defaultTemplateKey) private var defaultTemplate = "general"
    @State private var selection: String?
    @State private var draft: TemplateDefinition?
    @State private var draftName = ""

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                List(selection: $selection) {
                    ForEach(model.templates) { template in
                        HStack {
                            Text(template.displayName)
                            Spacer()
                            if template.id == defaultTemplate { Text("默认").font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(template.id)
                    }
                }
                HStack {
                    Button("添加", systemImage: "plus") { create(from: nil) }
                    Button("复制", systemImage: "plus.square.on.square") {
                        // 复制正在编辑的内容（包括还没存的修改）
                        create(from: model.templates.first { $0.id == selection }, definition: draft)
                    }
                    .disabled(selection == nil)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 170, maxWidth: 200)
            editor
                .frame(minWidth: 380)
        }
        // 换模板或关掉设置时，没按「保存」的修改也存起来，不要无声丢掉
        .onChange(of: selection) { old, id in
            saveIfChanged(old)
            load(id)
        }
        .onAppear { if selection == nil { selection = model.templates.first?.id } }
        .onDisappear { saveIfChanged(selection) }
    }

    @ViewBuilder
    private var editor: some View {
        if let template = model.templates.first(where: { $0.id == selection }), let binding = Binding($draft) {
            Form {
                TextField("名称", text: $draftName).disabled(template.builtin)
                TextField("用途说明", text: binding.description, axis: .vertical).disabled(template.builtin)
                Section("要产生的段落") {
                    ForEach(TemplateDefinition.builtinSections, id: \.id) { section in
                        Toggle(section.label, isOn: Binding(
                            get: { binding.wrappedValue.sections.contains(section.id) },
                            set: { on in
                                if on { binding.wrappedValue.sections.append(section.id) }
                                else { binding.wrappedValue.sections.removeAll { $0 == section.id } }
                            }))
                    }
                }
                .disabled(template.builtin)
                Section("自订段落") {
                    ForEach(binding.wrappedValue.custom.indices, id: \.self) { i in
                        let custom = binding.custom.safe(i, fallback: .init(title: "", instruction: ""))
                        HStack(alignment: .top) {
                            VStack {
                                TextField("段落名称", text: custom.title)
                                TextField("要写什么", text: custom.instruction, axis: .vertical)
                            }
                            Button { binding.custom.remove(i) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("添加自订段落", systemImage: "plus") { binding.wrappedValue.custom.append(.init(title: "", instruction: "")) }
                }
                .disabled(template.builtin)
                TextField("额外指示（选填）", text: binding.instruction, axis: .vertical).disabled(template.builtin)
                HStack {
                    if template.builtin {
                        Text("内置模板不能修改，可以按「复制」做一份自己的。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("设为默认模板") { defaultTemplate = template.id }.disabled(defaultTemplate == template.id)
                    if !template.builtin {
                        Button("删除", role: .destructive) {
                            // 删掉的是默认模板的话，默认改回一般会议，不然新会议会指到不存在的模板
                            if defaultTemplate == template.id { defaultTemplate = "general" }
                            model.deleteTemplate(template.id)
                            selection = model.templates.first?.id
                        }
                        Button("保存") {
                            model.saveTemplate(TemplateRecord(id: template.id, name: draftName.isEmpty ? String(localized: "未命名模板") : draftName,
                                                              builtin: false, definition: binding.wrappedValue.jsonString()))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            Text("选一个模板").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load(_ id: String?) {
        guard let template = model.templates.first(where: { $0.id == id }) else { draft = nil; return }
        draft = template.definition(for: .interface)
        // 内置模板不能改、不会存档：简体界面显示简体（design §48.2）
        if template.builtin, MeetingLanguage.simplifiedInterface { draft = draft?.mappingText(ChineseScript.toSimplifiedUI) }
        draftName = template.displayName
    }

    /// 自订模板有改过就存档
    private func saveIfChanged(_ id: String?) {
        guard let template = model.templates.first(where: { $0.id == id }), !template.builtin, let draft else { return }
        let name = draftName.isEmpty ? String(localized: "未命名模板") : draftName
        guard draft != template.definition(for: .interface) || name != template.displayName else { return }
        model.saveTemplate(TemplateRecord(id: template.id, name: name, builtin: false, definition: draft.jsonString()))
    }

    private func create(from source: TemplateRecord?, definition edited: TemplateDefinition? = nil) {
        let id = "custom-\(UUID().uuidString.prefix(8))"
        let definition = edited ?? source.map { $0.definition(for: .interface) }
            ?? TemplateDefinition(description: "", sections: ["summary", "decisions", "actionItems"], custom: [], instruction: "")
        model.saveTemplate(TemplateRecord(id: id, name: source.map { String(localized: "\($0.displayName)（副本）") } ?? String(localized: "新模板"), builtin: false,
                                          definition: definition.jsonString()))
        selection = id
    }
}

// MARK: 词汇表（沿用第二版）

/// 说话者与词汇（R44.5，design §33.3）：原本的「说话者」和「词汇表」两个标签页合成一页，各一个 Section
struct NamesSettings: View {
    var body: some View {
        Form {
            Section(MeetingLanguage.ui(zh: "说话者", en: "Speakers")) { SpeakerSettings() }
            Section("词汇表") { GlossarySettings() }
        }
        .formStyle(.grouped)
    }
}

/// 说话者（design §21.4、R19.3）：记住说话者的声音，之后的会议自动带入名字；认识的人可以改名、删除。
/// 是 Form 的一个 Section 的内容（R44.5）：认识的人一人一列，不用 List
struct SpeakerSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.voiceprintsKey) private var voiceprints = true
    @State private var renaming: Int64?
    @State private var renameText = ""
    @State private var confirmDeleteAll = false

    var body: some View {
        Toggle("记住说话者的声音，之后的会议自动带入名字", isOn: $voiceprints)
        Text("替说话者取名时，拾音会记下这个人的声音特征。之后的会议认出同一个人，就自动带入名字并标「自动」，不对可以改。声音特征只存在这台 Mac 的数据库，不会上传，也不会放进导出的 .shiyin 封包。")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Text("认识的人").font(.headline)
            Spacer()
            Button("全部删除…") { confirmDeleteAll = true }
                .disabled(model.people.isEmpty)
        }
        if model.people.isEmpty {
            Text("还没有认识的人。在逐字稿点「说话者 1」改成名字，拾音就会记住这个人。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(model.people) { person in
            HStack(spacing: 10) {
                if renaming == person.id {
                    TextField("名字", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.renamePerson(person.id, to: renameText); renaming = nil }
                    Button("取消") { renaming = nil }.buttonStyle(.link)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name)
                        Text(detailLine(person)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("改名") { renameText = person.name; renaming = person.id }.buttonStyle(.link)
                    Button { model.deletePerson(person.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("删除「\(person.name)」的声音特征（已经带入的名字留着）")
                }
            }
        }
        .onAppear { model.reloadPeople() }
        .confirmationDialog("删除所有认识的人的声音特征？", isPresented: $confirmDeleteAll) {
            Button("全部删除", role: .destructive) { model.deleteAllPeople() }
        } message: {
            Text("已经带入的名字会留着，之后的会议不会再自动带入。")
        }
    }

    private func detailLine(_ person: PersonSummary) -> String {
        let prints = String(localized: "\(person.voiceprintCount) 份声音特征")
        guard let title = person.lastMeetingTitle, let date = person.lastMeetingDate else { return prints }
        return String(localized: "\(prints)・最近：\(date) \(title)")
    }
}

/// 词汇表（沿用第二版）。是 Form 的一个 Section 的内容（R44.5）：词汇一条一列，不用 List
struct GlossarySettings: View {
    @Environment(AppModel.self) private var model
    @State private var newTerm = ""

    var body: some View {
        Text("系统名、产品名、人名的正确写法。转录时会当成提示（最多约 150 字），整理时也会参考。实验显示，有没有词汇提示，专有名词的正确率差很多。")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            TextField("添加词汇，例如产品名或人名", text: $newTerm).textFieldStyle(.roundedBorder).onSubmit(add)
            Button("添加", action: add).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        // 词汇表建议（design §17.5）：最多 12 个
        if !model.glossarySuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("建议加入：从参加者、说话者名字、校正过的字、会议标题找到的").font(.caption).foregroundStyle(.secondary)
                ForEach(model.glossarySuggestions) { suggestion in
                    HStack(spacing: 8) {
                        Text(suggestion.term)
                        Text(suggestion.sourceLabel).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("忽略") { model.dismissGlossarySuggestion(suggestion.term) }.buttonStyle(.link)
                        Button("加入") { model.addTerm(suggestion.term) }.buttonStyle(.link)
                    }
                }
            }
            .padding(10)
            .background(Color.signal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        if model.glossary.isEmpty {
            Text("还没有词汇。用词修正时勾选「加进词汇表」也会加到这里。").font(.callout).foregroundStyle(.secondary)
        }
        ForEach(model.glossary) { term in
            HStack {
                Text(term.term)
                Spacer()
                Button { model.deleteTerm(term.id!) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("删除「\(term.term)」")
            }
        }
        // 公司词汇表（R53.3）：唯读，接在自己的词后面
        if !model.companyGlossary.isEmpty {
            DisclosureGroup {
                Text(model.companyGlossary.joined(separator: MeetingLanguage.ui(zh: "、", en: ", ")))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("公司的词汇（\(model.companyGlossary.count) 个）")
                    Text("由\(EnterpriseServer.shared.account?.serverName ?? String(localized: "公司"))的管理者维护，接在你的词后面一起用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Text(String(localized: "目前的转录提示：\(WhisperEngine.prompt(glossary: CompanyGlossary.merge(model.glossary.map(\.term), model.companyGlossary), language: AppSettings.defaultMeetingLanguage))"))
            .font(.caption).foregroundStyle(.tertiary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            // 打开这页时更新公司词汇表（R53.1）
            .task { await EnterpriseServer.shared.refreshGlossary() }
    }

    private func add() {
        model.addTerm(newTerm)
        newTerm = ""
    }
}

// MARK: 录音与转录（R1、R4、R10.3；R44.5 分成四组）

struct RecordingSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.transcriptionEngineKey) private var engine = "breeze"

    /// 正式转录引擎的说明；Breeze、Qwen3-ASR 后面接不跟着这个设置的语言
    private var engineDescription: String {
        switch engine {
        case "server":
            return String(localized: "录音会送到 \(EnterpriseServer.shared.host)（公司的服务器）转录，转完就删；说话者识别和声纹在这台 Mac 上做，声纹不会送出。会参考词汇表。连不上时会等，也可以改在这台 Mac 转录。")
        case "system":
            return String(localized: "不用下载模型，速度快很多；但不参考词汇表，英文专有名词、人名比较容易错。")
        case "qwen":
            return String(localized: "会参考词汇表，多人会议的漏字和同音字比 Breeze 少、速度快三成；阿里巴巴开源的模型，全程在这台 Mac 上跑、不连网，输出是简体中文；需要下载约 2.5 GB 的模型。")
                + Self.otherEngines
        default:
            return String(localized: "会参考词汇表，中英夹杂、专有名词比较准；联发科开源的台湾模型，需要下载约 1.7 GB。") + Self.otherEngines
        }
    }

    /// 不跟着这个设置的语言（design §41.3）：「日文和韩文会议改用 Whisper large-v3-turbo（574 MB）。广东话会议一律用 Qwen3-ASR。」
    static var otherEngines: String {
        let space = MeetingLanguage.ui(zh: "", en: " ")
        var text = space + String(localized: "\(MeetingLanguage.uiNames(model: "turbo"))会议改用 Whisper large-v3-turbo（574 MB）。")
        let qwen = MeetingLanguage.uiNames(model: "qwen")
        if !qwen.isEmpty { text += space + String(localized: "\(qwen)会议一律用 Qwen3-ASR。") }
        return text
    }
    @AppStorage(AppSettings.defaultMeetingLanguageKey) private var meetingLanguage: MeetingLanguage = .systemDefault
    @AppStorage(AppSettings.recordSourceKey) private var source = "mic"
    @AppStorage(AppSettings.inputDeviceKey) private var device = ""
    @AppStorage(AppSettings.liveTranscriptionKey) private var live = true
    @AppStorage(AppSettings.autoDetectLanguageKey) private var autoDetect = true
    @AppStorage(AppSettings.diarizeKey) private var diarize = true
    @AppStorage(AppSettings.globalHotKeyKey) private var hotKey = true
    @AppStorage(AppSettings.meetingDetectionKey) private var meetingDetection = true
    @AppStorage(AppSettings.idleStopKey) private var idleStop = true
    @AppStorage(AppSettings.bookmarkHotKeyKey) private var bookmarkHotKey = true
    @State private var mutedApps: [String] = []
    @State private var hotKeyFailed = false

    var body: some View {
        Form {
            Section("录音来源") {
                Picker("录音来源", selection: $source) {
                    Text("只录麦克风").tag("mic")
                    Text("麦克风＋电脑声音（在线会议）").tag("both")
                    Text("只录电脑声音").tag("system")
                }
                Picker("麦克风", selection: $device) {
                    MicrophoneOptions(saved: device)
                }
                .disabled(source == "system")
                // R58.6：其他换麦克风的地方、蓝牙耳机会把系统默认换掉
                Text("录音按钮旁的箭头、录音画面也可以换麦克风。蓝牙耳机连着时，系统默认可能会自动变成耳机的麦克风，现场会议请选这台 Mac 的麦克风。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("录在线会议时选「麦克风＋电脑声音」：你的声音和对方的声音会分别录在左右声道。第一次录电脑声音时，macOS 会询问「录制系统音频」的权限。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("麦克风权限设置") { Recorder.openPrivacySettings() }
                    Button("系统录音权限设置") { Recorder.openPrivacySettings("Privacy_AudioCapture") }
                }
            }
            Section("语言") {
                // 会议语言（R12.4、design §16.3）
                Picker("默认会议语言", selection: $meetingLanguage) {
                    ForEach(MeetingLanguage.allCases) { Text($0.name).tag($0) }
                }
                Text("新的录音和导入默认用这个语言转录、整理会议记录；录音菜单、导入时和会议页都可以改。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("自动检测会议语言", isOn: $autoDetect)
                    .onChange(of: autoDetect) { _, on in if on { model.models.autoStart(.languageDetection) } }
                if autoDetect && !model.models.isInstalled(.languageDetection) {
                    // 模型没下载好（下载失败、暂停）就不会检测，要让人知道
                    HStack {
                        Text(model.models.state(.languageDetection).isBusy ? "正在下载语言检测模型…" : "语言检测模型还没下载，下载好之前录音不会自动检测")
                            .font(.caption).foregroundStyle(Color.signal)
                        Spacer()
                        if !model.models.state(.languageDetection).isBusy {
                            Button("下载") { model.models.start(.languageDetection) }.controlSize(.small)
                        }
                    }
                }
                Text("开始录音后听约 10 秒，判断是哪一种语言（\(MeetingLanguage.uiNames(MeetingLanguage.detectable))）；跟会议语言不同而且有把握时会自动切换，录音画面可以改回来。需要 60 MB 的语言检测模型。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("转录") {
                // 正式转录引擎（R4.1、design §6.2.1、D11；Qwen3-ASR 见 §32.6）
                Picker("正式转录", selection: $engine) {
                    // 企业服务器（R50.1）：登录过才有
                    if let account = EnterpriseServer.shared.account {
                        Text("企业服务器（\(account.serverName)）").tag("server")
                    }
                    Text("Breeze ASR 25（联发科，建议）").tag("breeze")
                    Text("Qwen3-ASR 1.7B（阿里巴巴）").tag("qwen")
                    Text("macOS 内置").tag("system")
                }
                .onChange(of: engine) { _, _ in
                    model.runner.wake()
                    model.refreshEnvironment()
                }
                Text(verbatim: engineDescription)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("转录时识别说话者", isOn: $diarize)
                Toggle("录音中显示实时逐字稿", isOn: $live)
                // 模型清单（原「模型与保存空间」标签页，R44.5）
                ModelRows()
            }
            Section("提醒与快捷键") {
                // 检测在线会议（design §21.7、R19.4）
                Toggle("检测到在线会议时提醒录音", isOn: $meetingDetection)
                Text("Zoom、Teams、Webex、Google Meet（浏览器）等开始用麦克风、拾音没在录音时提醒你；会议结束时提醒停止。只提醒，不会自动录音。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(mutedApps, id: \.self) { bundle in
                    HStack {
                        Text("不提醒：\(MeetingDetector.displayName(bundle))").font(.callout)
                        Spacer()
                        Button("恢复提醒") {
                            MeetingDetector.unmute(bundle)
                            mutedApps = MeetingDetector.muted
                        }
                        .buttonStyle(.link)
                    }
                }
                // 忘了停止录音（design §35、R48.5）
                Toggle("很久没人说话时提醒，30 分钟后自动停止", isOn: $idleStop)
                Text("录音中 15 分钟没人说话时提醒你；再 15 分钟还是没人说话就自动停止，只转录到最后有人说话的地方，录音档完整保留。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("全域快捷键 \(GlobalHotKey.display)：在其他 app 里也能开始或停止录音", isOn: $hotKey)
                    .onChange(of: hotKey) { _, enabled in
                        GlobalHotKey.shared.setEnabled(enabled)
                        hotKeyFailed = enabled && !GlobalHotKey.shared.isRegistered
                    }
                if hotKeyFailed {
                    Text("没办法注册 \(GlobalHotKey.display)，可能已经被其他 app 使用。")
                        .font(.caption).foregroundStyle(.red)
                }
                Toggle("录音中按 \(GlobalHotKey.bookmarkDisplay) 标记重点（在其他 app 里也能用）", isOn: $bookmarkHotKey)
                    .onChange(of: bookmarkHotKey) { _, enabled in
                        GlobalHotKey.shared.setBookmarkEnabled(enabled && model.recorder.isRecording)
                    }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hotKeyFailed = hotKey && !GlobalHotKey.shared.isRegistered
            mutedApps = MeetingDetector.muted
        }
    }
}

/// 模型清单（R10.3；R44.5 从「模型与保存空间」搬到「录音与转录 → 转录」）
struct ModelRows: View {
    @Environment(AppModel.self) private var model

    private var transcribing: Bool { model.runner.running[.transcribe] != nil }

    var body: some View {
        ModelRow(title: ModelStore.breeze.name, state: model.models.state,
                 start: { model.models.start() }, pause: { model.models.pause() },
                 delete: { model.models.delete(); model.refreshEnvironment() }, deleteDisabled: transcribing)
        Text("中文、英文会议用，1.66 GB。").font(.caption).foregroundStyle(.secondary)
        ModelRow(title: String(localized: "Qwen3-ASR 1.7B（q8_0，含音频编码器）"), state: model.models.combinedState(.qwen),
                 start: { model.models.startAll(.qwen) }, pause: { model.models.pauseAll(.qwen) },
                 delete: { model.models.deleteAll(.qwen); model.refreshEnvironment() }, deleteDisabled: transcribing)
        Text(MeetingLanguage.uiNames(model: "qwen").isEmpty ? String(localized: "正式转录选「Qwen3-ASR」时用，2.5 GB。")
             : String(localized: "正式转录选「Qwen3-ASR」时用；\(MeetingLanguage.uiNames(model: "qwen"))会议一律用。2.5 GB。"))
            .font(.caption).foregroundStyle(.secondary)
        ModelRow(title: ModelStore.japanese.name, state: model.models.state(.japanese),
                 start: { model.models.start(.japanese) }, pause: { model.models.pause(.japanese) },
                 delete: { model.models.delete(.japanese); model.refreshEnvironment() }, deleteDisabled: transcribing)
        Text("\(MeetingLanguage.uiNames(model: "turbo"))会议用，574 MB。第一次转录这些语言的会议时会自动下载。").font(.caption).foregroundStyle(.secondary)
        ModelRow(title: ModelStore.languageDetection.name, state: model.models.state(.languageDetection),
                 start: { model.models.start(.languageDetection) }, pause: { model.models.pause(.languageDetection) },
                 delete: { model.models.delete(.languageDetection); model.refreshEnvironment() }, deleteDisabled: model.recorder.isRecording)
        Text("自动检测会议语言用，60 MB。").font(.caption).foregroundStyle(.secondary)
        ModelRow(title: String(localized: "说话者识别模型（FluidAudio）"), state: model.models.diarizerState,
                 start: model.models.prepareDiarizer, pause: nil, delete: nil)
    }
}

/// 保存空间（R9.4；R44.5 从「模型与保存空间」搬到「高级」）：是 Form 的 Section 的内容
struct StorageSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.compressAudioKey) private var compress = true
    @State private var audioBytes: Int64 = 0
    @State private var modelBytes: Int64 = 0

    var body: some View {
        LabeledContent(MeetingLanguage.ui(zh: "录音", en: "Recordings"), value: ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file))
        LabeledContent("模型", value: ByteCountFormatter.string(fromByteCount: modelBytes, countStyle: .file))
        Toggle("转录完成后把录音压缩成 m4a（约每小时 10～30 MB）", isOn: $compress)
        LabeledContent("资料位置") {
            Button(Paths.home.path) { NSWorkspace.shared.activateFileViewerSelecting([Paths.home]) }
                .buttonStyle(.link)
        }
        .onAppear(perform: measure)
    }

    private func measure() {
        audioBytes = AppModel.directorySize(Paths.audioDir)
        modelBytes = AppModel.directorySize(Paths.modelsDir)
    }
}

struct ModelRow: View {
    let title: String
    let state: ModelStore.State
    let start: () -> Void
    let pause: (() -> Void)?
    let delete: (() -> Void)?
    /// 正在转录时不能删：用到一半的模型被删掉，那场转录会失败
    var deleteDisabled = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                switch state {
                case .downloading(let received, let total):
                    if total > 0 {
                        ProgressView(value: Double(received), total: Double(total))
                        Text("\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))／\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                case .paused(let received, _):
                    Text(received > 0 ? "已暂停（\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file))）" : "已暂停，可以接着下载")
                        .font(.caption).foregroundStyle(.secondary)
                case .verifying: Text("正在验证文件…").font(.caption).foregroundStyle(.secondary)
                case .installed: Text("已下载").font(.caption).foregroundStyle(Color.celadon)
                case .missing: Text("还没下载").font(.caption).foregroundStyle(.secondary)
                case .failed(let message): Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            switch state {
            case .downloading: if let pause { Button("暂停", action: pause) }
            case .verifying: EmptyView()
            case .installed:
                if let delete {
                    Button("删除", role: .destructive) { confirmDelete = true }
                        .disabled(deleteDisabled)
                        .help(deleteDisabled ? "正在转录，完成后才能删除模型" : "")
                        .confirmationDialog("删除「\(title)」？", isPresented: $confirmDelete) {
                            Button("删除", role: .destructive, action: delete)
                        } message: {
                            Text("之后要用的时候需要重新下载。")
                        }
                }
            case .paused, .failed: Button("继续下载", action: start)
            case .missing: Button("下载", action: start).buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: 高级：环境检查

struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.textSizeKey) private var textSize = 0
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(Updater.urlKey) private var updateURL = ""
    @State private var showingUsageStats = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            // 企业服务器（R49、design §36.3）：放在最上面，公司的人照「高级 → 企业服务器」找得到
            Section("企业服务器") { EnterpriseServerSettings() }
            // 会议内容的文字大小（design §38.5、R59）
            Section("显示") {
                Picker("会议内容的文字大小", selection: $textSize) {
                    ForEach(TextSize.levels, id: \.self) { Text(TextSize.label($0)).tag($0) }
                }
                Text("记录、逐字稿、提问、实时逐字稿和我的笔记的文字。也可以用 ⌘＋、⌘－ 调整，⌘0 回到标准大小。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // 让 AI 工具读取会议（本地 MCP，design §44.4、R69）
            Section("AI 工具（MCP）") { MCPSettings() }
            // app 内更新（R10.6）
            Section("更新") {
                LabeledContent("目前版本", value: Updater.currentVersion)
                TextField("更新网址", text: $updateURL,
                          prompt: Text(Bundle.main.object(forInfoDictionaryKey: "ShiyinUpdateURL") as? String ?? "https://…/shiyin-update.json"))
                Text("发布拾音的人会给你这个网址（shiyin-update.json）。留空就用安装版本内置的网址；都没有的话不会检查更新。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("检查更新") { Task { await model.updater.check(userInitiated: true) } }
                        .disabled(model.updater.state == .checking || model.updater.state == .downloading || model.updater.state == .installing)
                    if case .available(let manifest) = model.updater.state {
                        Button("下载并更新到 \(manifest.version)") { Task { await model.updater.install(manifest, model: model) } }
                            .buttonStyle(.borderedProminent)
                    }
                    Text(model.updater.progress?.text ?? model.updater.state.label)
                        .font(.callout)
                        .foregroundStyle(isFailure ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 下载的进度（design §12，4.7.1）
                if let progress = model.updater.progress {
                    if let fraction = progress.fraction { ProgressView(value: fraction).tint(.signal) } else { ProgressView().progressViewStyle(.linear) }
                }
            }
            Section("环境检查") {
                ForEach(model.environment.items) { item in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: item.ok ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(item.ok ? Color.celadon : .secondary)
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text(item.ok ? item.detail : item.fix).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Button("重新检查") { model.refreshEnvironment() }
            }
            Section("保存空间") { StorageSection() }
            if model.legacyBytes > 0 {
                Section("第二版留下的文件") {
                    Text("第二版用的 Python 环境和旧模型已经用不到了，占用 \(ByteCountFormatter.string(fromByteCount: model.legacyBytes, countStyle: .file))。")
                        .fixedSize(horizontal: false, vertical: true)
                    Button("删除第二版的 Python 环境和旧模型", role: .destructive) { model.deleteLegacyItems() }
                }
            }
            Section {
                Button("重新显示首次使用引导") {
                    hasCompletedOnboarding = false
                    openWindow(id: "onboarding")
                }
                Button("重建搜索索引") {
                    model.perform { try model.db.rebuildSearchIndex() }
                    model.noticeMessage = String(localized: "搜索索引已重建")
                }
            }
            // 匿名使用统计（design §30.5、R40.4）：有统计网址的版本才有。放在最下面、只留一行，开关收在「详细…」里
            if UsageStats.isOffered {
                Section {
                    LabeledContent("匿名使用统计") {
                        Button("详细…") { showingUsageStats = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshEnvironment() }
        .sheet(isPresented: $showingUsageStats) {
            UsageStatsSheet { showingUsageStats = false }
        }
    }

    private var isFailure: Bool {
        if case .failed = model.updater.state { return true }
        return false
    }
}

/// 「匿名使用统计」的「详细…」（design §30.5、R40.4）：开关、说明、重置匿名 ID。不显示送出的 JSON（用户决定）
private struct UsageStatsSheet: View {
    let done: () -> Void
    @AppStorage(UsageStats.enabledKey) private var usageStats = true
    @State private var didReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("匿名使用统计").font(.headline)
            Toggle("分享匿名使用统计", isOn: $usageStats)
                .onChange(of: usageStats) { _, on in
                    // 关掉时清掉还没送的资料（R40.4），打开时创建今天的汇总
                    if on { UsageStats.shared.touch() } else { UsageStats.shared.clearPending() }
                }
            Text("每天送一份匿名的使用统计给拾音的开发者：版本、系统、录音和转录了几分钟、用了哪些功能、失败几次和哪一种失败。不会送会议标题、逐字稿、会议记录、人名、声纹或任何文件。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("重置匿名 ID") {
                    UsageStats.shared.resetInstallId()
                    didReset = true
                }
                if didReset { Text("已重置匿名 ID").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("完成", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
