import AppKit
import AuthenticationServices

/// 加入链接（R49.7、design §36.2、§36.3）：shiyin://join?server=… → 问要不要加入 → 公司的登录页 → 套用默认。
/// 不经过设置窗口（SwiftUI 的设置窗口从 app 外面打不开），用 NSAlert 和 AppKit 的 ASWebAuthenticationSession。
/// 链接谁都做得出来：标题写主机（punycode），服务器给的名称只当成「自称」；登录的是别台时，新的登录成功了才换掉
/// （EnterpriseServer.completeSignIn）
@MainActor
enum EnterpriseJoin {
    static func isJoin(_ url: URL) -> Bool { url.scheme?.lowercased() == "shiyin" && url.host()?.lowercased() == "join" }

    private static var busy = false
    private static var session: ASWebAuthenticationSession?
    private static let anchor = Anchor()

    static func handle(_ url: URL) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        NSApp.activate()
        let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "server" }?.value ?? ""
        let server = EnterpriseServer.shared
        guard let target = EnterpriseServer.normalized(text) else {
            return notice(String(localized: "没办法加入"), EnterpriseServer.Failure.invalidURL.errorDescription ?? "", style: .warning)
        }
        if server.isSignedIn, let saved = server.savedURL, EnterpriseServer.sameServer(saved, target), let account = server.account {
            return notice(String(localized: "已经加入「\(account.serverName)」了"),
                          String(localized: "这台 Mac 已经用 \(account.email) 登录 \(EnterpriseServer.displayHost(target))。"))
        }
        let attempt: EnterpriseServer.Attempt
        do { attempt = try await server.beginSignIn(text) } catch {
            return notice(String(localized: "没办法加入"), error.localizedDescription, style: .warning)
        }
        let host = EnterpriseServer.displayHost(attempt.base)
        let confirm = NSAlert()
        confirm.messageText = String(localized: "加入 \(host) 的企业服务器？")
        var info = String(localized: "这台服务器自称「\(attempt.info.name)」。") + "\n\n"
            + String(localized: "会打开 \(host) 的登录页，用公司账号登录。登录后录音交给公司的服务器转录，整理也用公司设置的模型。")
        if let current = server.account {
            info += "\n\n" + String(localized: "登录成功之后，才会退出登录目前的「\(current.serverName)」（\(server.host)）；没有登录成功就维持原本的登录。")
        }
        confirm.informativeText = info
        confirm.addButton(withTitle: String(localized: "加入"))
        confirm.addButton(withTitle: String(localized: "取消"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            let callback = try await authenticate(attempt.loginURL)
            try await server.completeSignIn(attempt, callback: callback)
            AppModel.shared.applyEnterpriseDefaults(llm: attempt.info.llm)
            notice(String(localized: "已加入「\(attempt.info.name)」"),
                   String(localized: "录音会交给公司的服务器转录。要改回这台 Mac，到「设置 → 高级 → 企业服务器」。"))
        } catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin {
        } catch let failure as EnterpriseServer.Failure where failure == .cancelled {
        } catch {
            notice(String(localized: "没办法登录"), error.localizedDescription, style: .warning)
        }
    }

    private static func notice(_ title: String, _ message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// 用默认浏览器的登录状态打开登录页，等 shiyin://auth 回来（同设置页的登录，§36.3）
    private static func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(EnterpriseServer.callbackScheme)) { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? EnterpriseServer.Failure.cancelled) }
            }
            session.presentationContextProvider = anchor
            self.session = session
            if !session.start() { continuation.resume(throwing: EnterpriseServer.Failure.cancelled) }
        }
    }

    private final class Anchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey } ?? NSWindow() }
        }
    }
}
