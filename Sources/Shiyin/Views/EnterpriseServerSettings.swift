import AuthenticationServices
import SwiftUI

/// 设置 → 高级 → 企业服务器（R49、design §36.3）：输入网址、到服务器的登录页用公司账号登录；
/// 登录后显示账号、转录和整理要不要用企业服务器（R49.3）、退出登录
struct EnterpriseServerSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @AppStorage(AppSettings.transcriptionEngineKey) private var engine = "breeze"
    @AppStorage(AppSettings.providerKey) private var storedProvider = ""
    @State private var url = ""
    @State private var busy = false
    @State private var error: String?
    /// 登录前的设置：取消勾选时改回去（R49.3）
    @State private var previousEngine: String?
    @State private var previousProvider: String?

    private var server: EnterpriseServer { .shared }

    var body: some View {
        if let account = server.account {
            LabeledContent("服务器") {
                Text("\(account.serverName)（\(server.host)）").textSelection(.enabled)
            }
            LabeledContent("账号") {
                HStack(spacing: 8) {
                    Text(account.email).textSelection(.enabled)
                    if server.isSignedIn {
                        Text("已登录").foregroundStyle(Color.celadon)
                    } else {
                        Text("登录已失效").foregroundStyle(.red)
                    }
                }
            }
            if case .expired(let message) = server.status {
                Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                Button(busy ? "登录中…" : "重新登录") { Task { await signIn(server.savedURL?.absoluteString ?? "") } }
                    .disabled(busy)
            }
            Toggle("用企业服务器转录", isOn: Binding(
                get: { engine == "server" },
                set: { on in
                    if on { previousEngine = engine == "server" ? previousEngine : engine; engine = "server" }
                    else { engine = previousEngine.flatMap { $0 == "server" ? nil : $0 } ?? "breeze" }
                    model.runner.wake()
                    model.refreshEnvironment()
                }))
            if account.llm {
                Toggle("用企业服务器整理会议记录", isOn: Binding(
                    get: { storedProvider == LLMProvider.enterprise.rawValue },
                    set: { on in
                        if on { previousProvider = storedProvider; storedProvider = LLMProvider.enterprise.rawValue }
                        else { storedProvider = previousProvider.flatMap { $0 == LLMProvider.enterprise.rawValue ? nil : $0 } ?? "" }
                        NotificationCenter.default.post(name: .summarizerStateChanged, object: nil)
                    }))
            }
            Text("转录：录音会送到 \(server.host)（公司的服务器），转完就删。说话者识别和声纹在这台 Mac 上做，声纹、笔记、会议记录不会因为转录送出。服务器用的转录引擎：\(engineName(account.engine))。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("退出登录", role: .destructive) {
                Task {
                    await server.signOut()
                    model.refreshEnvironment()
                    NotificationCenter.default.post(name: .summarizerStateChanged, object: nil)
                }
            }
        } else {
            TextField("网址", text: $url, prompt: Text(verbatim: "https://shiyin.example.com"))
                .onSubmit { Task { await signIn(url) } }
            HStack {
                Button(busy ? "登录中…" : "登录") { Task { await signIn(url) } }
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    .buttonStyle(.borderedProminent)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text("公司有拾音的企业服务器时，填入公司给的网址、按「登录」，在打开的网页用公司账号登录。登录后录音交给公司的服务器转录，没有 NVIDIA 显卡的电脑也很快；整理也可以用公司提供的模型。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func engineName(_ engine: String) -> String {
        engine == "qwen" ? String(localized: "Qwen3-ASR（阿里巴巴开源）") : String(localized: "Breeze ASR 25（联发科）")
    }

    /// 检查网址 → 打开服务器的登录页（ASWebAuthenticationSession，用默认浏览器的登录状态）→ 换 token（M§36.2）
    private func signIn(_ text: String) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let attempt = try await server.beginSignIn(text)
            let callback = try await webAuthenticationSession.authenticate(using: attempt.loginURL, callbackURLScheme: EnterpriseServer.callbackScheme,
                                                                           preferredBrowserSession: .shared)
            try await server.completeSignIn(attempt, callback: callback)
            applyDefaults(llm: attempt.info.llm)
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
            // 用户关掉登录窗口
        } catch is CancellationError {
        } catch let failure as EnterpriseServer.Failure where failure == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 登录后默认转录、整理都用企业服务器（R49.3），可以再取消勾选改回原本的
    private func applyDefaults(llm: Bool) {
        if engine != "server" { previousEngine = engine }
        if llm && storedProvider != LLMProvider.enterprise.rawValue { previousProvider = storedProvider }
        model.applyEnterpriseDefaults(llm: llm)
    }
}
