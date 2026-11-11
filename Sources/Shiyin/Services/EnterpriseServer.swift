import CryptoKit
import Foundation

/// 企业服务器（design §36、R49～R52）：网址、登录（服务器的登录页＋OAuth 授权码＋PKCE，D121）、换 token、调用 API。
/// 网址和账号（邮箱、名字、服务器名称，不是密钥）存 UserDefaults，有账号就算登录了；refresh token 只存在钥匙串（R49.6），
/// 第一次真的要调用服务器时才读（§22.1：不在启动、打开设置页时读）；access token 只放内存
@MainActor
@Observable
final class EnterpriseServer {
    static let shared = EnterpriseServer()

    static let urlKey = "enterpriseServerURL"
    nonisolated static let accountKey = "enterpriseServerAccount"
    static let keychainAccount = "enterpriseServer"
    /// 这版 app 说的 API 版本（M§36.2）
    static let apiVersion = 1
    nonisolated static let callbackScheme = "shiyin"
    nonisolated static let redirectURI = "shiyin://auth"

    /// 服务器的 /api/v1/info
    struct Info: Codable, Equatable {
        struct Transcription: Codable, Equatable {
            var engine: String
            var languages: [String]
        }
        var server: String
        var apiVersion: Int
        var minAppApi: Int
        var name: String
        var version: String
        var maxAudioSeconds: Int?
        var transcription: Transcription
        var llm: Bool
        /// 公司让不让 AI 工具读取会议（本地 MCP，R69.6）；没有 = 允许
        var mcp: Bool?
    }

    /// 登录的账号（不含密钥）
    struct Account: Codable, Equatable {
        var email: String
        var name: String
        var serverName: String
        var engine: String
        var llm: Bool
        /// 服务器的版本（反馈问题用，R52.3）；4.2 以前存的账号没有
        var serverVersion: String?
        /// 公司关掉本地 MCP 时是 false（R69.6）；没有 = 允许
        var mcp: Bool?
    }

    /// 公司的企业服务器关掉了「让 AI 工具读取会议」（R69.6、design §44.1）。直接读存着的账号：`Shiyin --mcp` 不建 EnterpriseServer
    nonisolated static var mcpBlocked: Bool {
        guard let data = UserDefaults.standard.data(forKey: accountKey),
              let account = try? JSONDecoder().decode(Account.self, from: data) else { return false }
        return account.mcp == false
    }

    enum Status: Equatable {
        case signedOut
        case signedIn
        /// 登录失效（账号被禁用、离职、撤销、30 天没用）：用到服务器的工作停着等重新登录（R49.4）
        case expired(String)
    }

    private(set) var account: Account?
    private(set) var status: Status = .signedOut {
        // 登录、失效、重新登录：整理工具「准备好了没」要重算（R51.3；只看账号的话，登录完成前算的会留着「登录已失效」）
        didSet { if status != oldValue { NotificationCenter.default.post(name: .summarizerStateChanged, object: nil) } }
    }

    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessExpires = Date.distantPast
    @ObservationIgnored private var refreshing: Task<String, Error>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.accountKey), let saved = try? JSONDecoder().decode(Account.self, from: data) {
            account = saved
            status = .signedIn
        }
    }

    var isSignedIn: Bool { account != nil && status == .signedIn }
    /// 有登录过（失效了也算）：设置页显示账号、正式转录的选项照样出现
    var hasAccount: Bool { account != nil }

    var savedURL: URL? { UserDefaults.standard.string(forKey: Self.urlKey).flatMap { Self.normalized($0) } }
    /// 隐私说明用的主机名称（design §36.5）
    var host: String { savedURL.map(Self.displayHost) ?? "" }

    // MARK: 网址

    /// 只接受 https；DEBUG 版可以用本机的 http（R49.2）。去掉结尾的 /，贴了 /api/v1/info 之类的也去掉。
    /// 有账号密码（user:pass@）、主机是百分比编码的非英文字的不接受（加入链接用来假装成别的网站，design §36.2）
    nonisolated static func normalized(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        for suffix in ["/api/v1/info", "/api/v1", "/admin", "/login"] where value.hasSuffix(suffix) { value.removeLast(suffix.count) }
        guard let url = URL(string: value), let host = url.host(), !host.isEmpty, let scheme = url.scheme?.lowercased() else { return nil }
        guard (url.user() ?? "").isEmpty, (url.password() ?? "").isEmpty, displayHost(url).allSatisfy(\.isASCII) else { return nil }
        if scheme == "https" { return url }
        #if DEBUG
        if scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host) { return url }
        #endif
        return nil
    }

    /// 给人看的主机名称：国际化网域是 punycode（xn--…），长得像别的网站的字符骗不了人。
    /// host() 对国际化网域回传百分比编码，percentEncoded: false 才是 punycode
    nonisolated static func displayHost(_ url: URL) -> String {
        url.host(percentEncoded: false) ?? ""
    }

    /// 同一台服务器（不管结尾的斜线、大小写）
    nonisolated static func sameServer(_ a: URL, _ b: URL) -> Bool {
        a.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
            b.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    enum Failure: LocalizedError, Equatable {
        case invalidURL
        case notShiyin
        case serverTooOld
        case appTooOld
        case unreachable(String)
        case untrusted
        case loginExpired
        case forbidden(String)
        case denied(String)
        case server(kind: String, message: String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidURL: return String(localized: "网址不对：要以 https:// 开头，例如 https://shiyin.example.com")
            case .notShiyin: return String(localized: "这个网址不是拾音的企业服务器")
            case .serverTooOld: return String(localized: "企业服务器的版本太旧，请通知公司的管理者更新")
            case .appTooOld: return String(localized: "拾音的版本太旧，请先更新拾音")
            case .unreachable(let detail): return String(localized: "连不到企业服务器（\(detail)）。请确认网址，在公司外面要先连 VPN。")
            case .untrusted: return String(localized: "企业服务器的证书不受这台 Mac 信任，请公司的管理者协助安装证书")
            case .loginExpired: return String(localized: "企业服务器的登录已失效，请重新登录")
            case .forbidden(let message), .denied(let message): return message
            case .server(_, let message): return message
            case .cancelled: return String(localized: "已取消")
            }
        }

        /// 设置问题（登录失效、账号被禁用）：工作停着等，不算失败（R49.4、R51.3）
        var isSetupProblem: Bool {
            switch self {
            case .loginExpired, .forbidden, .denied, .notShiyin, .serverTooOld, .appTooOld, .invalidURL, .untrusted: return true
            default: return false
            }
        }

        /// 暂时的问题：连不上、服务器忙、5xx（R50.5：等着、自动再试）
        var isTemporary: Bool {
            switch self {
            case .unreachable: return true
            case .server(let kind, _): return kind == "busy" || kind == "server_error"
            default: return false
            }
        }
    }

    /// 确认那是拾音的服务器、版本兼容（R49.1、R49.2）
    func fetchInfo(_ url: URL) async throws -> Info {
        var request = URLRequest(url: url.appending(path: "api/v1/info"))
        request.timeoutInterval = 15
        Self.addLanguage(&request)
        let (data, response) = try await Self.send(request)
        guard response.statusCode == 200, let info = try? JSONDecoder().decode(Info.self, from: data), info.server == "shiyin" else {
            throw Failure.notShiyin
        }
        if info.apiVersion < Self.apiVersion { throw Failure.serverTooOld }
        if info.minAppApi > Self.apiVersion { throw Failure.appTooOld }
        return info
    }

    /// 重新读服务器的信息（R51.5、design §36.3）：公司在后台加了模型、改了名称或转录引擎；连不上就保留旧的。不读钥匙串
    func refreshInfo() async {
        guard let url = savedURL, let before = account, let info = try? await fetchInfo(url) else { return }
        // 读的时候退出登录、换了账号或服务器：不要盖掉
        guard let current = account, current.email == before.email, let saved = savedURL, Self.sameServer(saved, url) else { return }
        var updated = current
        updated.serverName = info.name
        updated.engine = info.transcription.engine
        updated.llm = info.llm
        updated.serverVersion = info.version
        updated.mcp = info.mcp
        if updated != current {
            save(updated)
            NotificationCenter.default.post(name: .summarizerStateChanged, object: nil)
        }
        await refreshGlossary()
    }

    /// 公司词汇表（R53.1）：旧的服务器回 404 就是没有；连不上保留上次的
    func refreshGlossary() async {
        guard isSignedIn, let (data, response) = try? await call("GET", "api/v1/glossary", timeout: 15) else { return }
        if response.statusCode == 404 { CompanyGlossary.save([], updatedAt: nil); return }
        guard response.statusCode == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let terms = object["terms"] as? [String] else { return }
        CompanyGlossary.save(terms, updatedAt: object["updatedAt"] as? String)
    }

    // MARK: 登录（M§36.2）

    /// 一次登录：PKCE 的 verifier 和 state 只放内存
    struct Attempt {
        let base: URL
        let info: Info
        let verifier: String
        let state: String

        var loginURL: URL {
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            var components = URLComponents(url: base.appending(path: "login"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: "shiyin-app"),
                URLQueryItem(name: "redirect_uri", value: EnterpriseServer.redirectURI),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
            ]
            return components.url!
        }

        static func base64URL(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        /// 32 bytes 随机；系统产生不出来就不登录（全是 0 的 state、verifier 等于没有保护）
        static func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw Failure.server(kind: "random", message: String(localized: "没办法产生登录用的随机码，请再试一次"))
            }
            return base64URL(Data(bytes))
        }
    }

    /// 第一步：检查网址，准备好登录页的网址（设置页再用 ASWebAuthenticationSession 打开）
    func beginSignIn(_ text: String) async throws -> Attempt {
        guard let url = Self.normalized(text) else { throw Failure.invalidURL }
        let info = try await fetchInfo(url)
        return Attempt(base: url, info: info, verifier: try Attempt.random() + Attempt.random(), state: try Attempt.random())
    }

    /// 第二步：登录页转回 shiyin://auth?code=…&state=…，用授权码加 PKCE 换 token
    func completeSignIn(_ attempt: Attempt, callback: URL) async throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        // state 不是这次发的（网页里的链接、旧的登录）就忽略
        guard value("state") == attempt.state else { throw Failure.cancelled }
        if value("error") != nil {
            throw Failure.denied(value("error_description") ?? String(localized: "企业服务器拒绝了这次登录"))
        }
        guard let code = value("code") else { throw Failure.cancelled }
        let tokens = try await tokenRequest(attempt.base, [
            "grant_type": "authorization_code", "code": code, "code_verifier": attempt.verifier,
            "device": Host.current().localizedName ?? "Mac", "platform": "mac", "appVersion": Updater.currentVersion,
        ])
        // 加入链接换到另一台（R49.7、design §36.2）：新的登录成功了才退出登录旧的。先拿旧服务器的 access token
        //（同时在换的 token 也等它换完，不然换完会把旧服务器的 refresh token 写回钥匙串），存好新的登录之后再撤销
        var previous: (url: URL, token: String?)?
        if account != nil, let old = savedURL, !Self.sameServer(old, attempt.base) {
            previous = (old, try? await validAccessToken())
        }
        try Keychain.set(Self.keychainAccount, tokens.refreshToken)
        UserDefaults.standard.set(attempt.base.absoluteString, forKey: Self.urlKey)
        let account = Account(email: tokens.email, name: tokens.name, serverName: attempt.info.name,
                              engine: attempt.info.transcription.engine, llm: attempt.info.llm, serverVersion: attempt.info.version,
                              mcp: attempt.info.mcp)
        save(account)
        accessToken = tokens.accessToken
        accessExpires = Date().addingTimeInterval(TimeInterval(tokens.expiresIn) - 60)
        status = .signedIn
        log.info("enterprise server signed in")
        if let previous {
            // 旧服务器那边撤销这台电脑（送不出去也照样换）；旧公司的词汇表不能留给新的公司用
            if let token = previous.token { await Self.revoke(previous.url, token: token) }
            CompanyGlossary.clear()
            // 新的服务器没有提供整理：整理工具原本是「公司」的改成还没设置（同退出登录，R49.5）
            if !attempt.info.llm { Self.removeSaved(AppSettings.providerKey, ifEqual: LLMProvider.enterprise.rawValue) }
            log.info("enterprise server switched")
        }
        await refreshGlossary()
    }

    /// 退出登录（R49.5）：服务器那边撤销这台电脑（送不出去也照样清掉本机的），转录、整理改回本机的
    func signOut() async {
        if let url = savedURL, let token = try? await validAccessToken() { await Self.revoke(url, token: token) }
        forgetLogin()
        CompanyGlossary.clear()
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
        account = nil
        status = .signedOut
        Self.removeSaved(AppSettings.transcriptionEngineKey, ifEqual: "server")
        Self.removeSaved(AppSettings.providerKey, ifEqual: LLMProvider.enterprise.rawValue)
        log.info("enterprise server signed out")
    }

    /// 撤销这台电脑在服务器上的登录（POST /api/v1/auth/logout）；送不出去不管
    private static func revoke(_ url: URL, token: String) async {
        var request = URLRequest(url: url.appending(path: "api/v1/auth/logout"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await send(request)
    }

    /// 只清掉存下来的值是企业服务器的设置（启动参数带的值不算：曾经因此删掉用户自己选的整理工具）
    private static func removeSaved(_ key: String, ifEqual value: String) {
        let saved = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
        if saved[key] as? String == value { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func forgetLogin() {
        Keychain.delete(Self.keychainAccount)
        accessToken = nil
        accessExpires = .distantPast
    }

    private func save(_ account: Account) {
        self.account = account
        if let data = try? JSONEncoder().encode(account) { UserDefaults.standard.set(data, forKey: Self.accountKey) }
    }

    private struct TokenResponse {
        var accessToken: String
        var expiresIn: Int
        var refreshToken: String
        var email: String
        var name: String
    }

    private func tokenRequest(_ base: URL, _ body: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: base.appending(path: "api/v1/auth/token"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.addLanguage(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await Self.send(request)
        guard response.statusCode == 200 else { throw Self.failure(data, response) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw Failure.notShiyin
        }
        let user = json["user"] as? [String: Any]
        return TokenResponse(accessToken: access, expiresIn: json["expires_in"] as? Int ?? 3600, refreshToken: refresh,
                             email: user?["email"] as? String ?? "", name: user?["name"] as? String ?? "")
    }

    /// 还有效的 access token；过期了用 refresh token 换（同时只换一次：refresh token 换过就作废，design §5.2）
    func validAccessToken() async throws -> String {
        guard account != nil, let base = savedURL else { throw Failure.loginExpired }
        if let accessToken, accessExpires > Date() { return accessToken }
        if let refreshing { return try await refreshing.value }
        let task = Task { @MainActor () throws -> String in
            defer { self.refreshing = nil }
            // 钥匙串读不到（没有、用户拒绝访问）：当成要重新登录，但不删钥匙串的项目
            guard let refresh = try? Keychain.read(Self.keychainAccount), !refresh.isEmpty else {
                self.status = .expired(Failure.loginExpired.errorDescription ?? "")
                throw Failure.loginExpired
            }
            do {
                let tokens = try await self.tokenRequest(base, ["grant_type": "refresh_token", "refresh_token": refresh,
                                                                "appVersion": Updater.currentVersion])
                try Keychain.set(Self.keychainAccount, tokens.refreshToken)
                self.accessToken = tokens.accessToken
                self.accessExpires = Date().addingTimeInterval(TimeInterval(tokens.expiresIn) - 60)
                if self.status != .signedIn { self.status = .signedIn }
                return tokens.accessToken
            } catch let failure as Failure {
                // 服务器说登录失效、账号被禁用：清掉这台的登录，等用户重新登录（R49.4）
                if failure == .loginExpired { self.markExpired(nil) }
                else if case .forbidden(let message) = failure { self.markExpired(message) }
                throw failure
            }
        }
        refreshing = task
        return try await task.value
    }

    /// 服务器说 access token 不能用了（整理的请求回 401）：丢掉，下次用 refresh token 换新的
    func invalidateAccess() {
        accessToken = nil
        accessExpires = .distantPast
    }

    private func markExpired(_ message: String?) {
        forgetLogin()
        status = .expired(message ?? Failure.loginExpired.errorDescription ?? "")
        log.info("enterprise server login expired")
    }

    // MARK: API

    /// 调用 API：带 access token，401 时换一次 token 再送（R49.4）
    func call(_ method: String, _ path: String, json: Any? = nil, body: Data? = nil, headers: [String: String] = [:],
              timeout: TimeInterval = 60) async throws -> (Data, HTTPURLResponse) {
        guard let base = savedURL else { throw Failure.loginExpired }
        // 中途换了服务器（加入链接，design §36.2）：新服务器的 token 不能送到旧的服务器、旧服务器的回应不能动到新的登录；
        // 当成工作不在了（转录在新的服务器重建）
        func switched() -> Bool { savedURL.map { !Self.sameServer($0, base) } ?? true }
        for attempt in 0..<2 {
            let token = try await validAccessToken()
            if switched() { throw Failure.server(kind: "not_found", message: "") }
            var request = URLRequest(url: base.appending(path: path))
            request.httpMethod = method
            request.timeoutInterval = timeout
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            Self.addLanguage(&request)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            if let json {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: json)
            } else if let body {
                request.httpBody = body
            }
            let (data, response) = try await Self.send(request)
            if switched() { throw Failure.server(kind: "not_found", message: "") }
            if response.statusCode == 401 && attempt == 0 {
                accessToken = nil
                accessExpires = .distantPast
                continue
            }
            if response.statusCode == 401 { markExpired(nil); throw Failure.loginExpired }
            if response.statusCode == 403 {
                let failure = Self.failure(data, response)
                markExpired(failure.errorDescription)
                throw failure
            }
            return (data, response)
        }
        throw Failure.loginExpired
    }

    /// 企业服务器专用的连接（design §36.2、D126）：不跟着转址。URLSession.shared 会跟着 307、308 转到别的主机，
    /// Authorization 会拿掉，但 body（refresh token、录音、逐字稿）照样送过去
    nonisolated static let session = URLSession(configuration: .default, delegate: NoRedirect(), delegateQueue: nil)

    /// 送出请求；连不上、逾时、证书不受信任换成 Failure；服务器要转址（3xx）是错误
    nonisolated static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.notShiyin }
            if (300..<400).contains(http.statusCode) { throw redirected(http.statusCode) }
            return (data, http)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .secureConnectionFailed, .clientCertificateRejected:
                throw Failure.untrusted
            case .appTransportSecurityRequiresSecureConnection: throw Failure.invalidURL
            default: throw Failure.unreachable(error.localizedDescription)
            }
        }
    }

    /// 服务器要转到别的网址：不跟着转（D126），不是暂时的问题（转录的工作算失败）
    nonisolated static func redirected(_ status: Int) -> Failure {
        .server(kind: "redirect", message: String(localized: "企业服务器要求转到别的网址（HTTP \(status)），拾音不会跟着转。请确认网址，或请公司的管理者检查服务器的设置。"))
    }

    /// 服务器的错误 {"error": {"kind", "message"}}（M§36.2）
    nonisolated static func failure(_ data: Data, _ response: HTTPURLResponse) -> Failure {
        let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        let kind = error?["kind"] as? String ?? (response.statusCode >= 500 ? "server_error" : "bad_request")
        let message = error?["message"] as? String ?? String(localized: "企业服务器回传错误（HTTP \(response.statusCode)）")
        switch (response.statusCode, kind) {
        case (401, _), (_, "unauthorized"): return .loginExpired
        case (403, _), (_, "forbidden"): return .forbidden(message)
        default: return .server(kind: kind, message: message)
        }
    }

    /// 服务器给的消息用 app 的界面语言（M§36.2）
    nonisolated static func addLanguage(_ request: inout URLRequest) {
        request.setValue(MeetingLanguage.ui(zh: "zh-CN", en: "en"), forHTTPHeaderField: "Accept-Language")
    }

    // MARK: DEBUG

    #if DEBUG
    /// shiyinctl enterpriselogin：服务器开发用的登录（design §11.1 的 devLogin）不经过浏览器，直接送出邮箱，走一样的 completeSignIn
    func debugDevSignIn(_ text: String, email: String) async throws {
        let attempt = try await beginSignIn(text)
        _ = try await Self.send(URLRequest(url: attempt.loginURL))
        var request = URLRequest(url: attempt.base.appending(path: "login/dev"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let challenge = URLComponents(url: attempt.loginURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code_challenge" }?.value ?? ""
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "email", value: email), URLQueryItem(name: "state", value: attempt.state),
                           URLQueryItem(name: "challenge", value: challenge)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, _) = try await Self.send(request)
        let html = String(decoding: data, as: UTF8.self)
        guard let range = html.range(of: #"window\.location\.replace\("([^"]+)"\)"#, options: .regularExpression) else { throw Failure.notShiyin }
        let quoted = String(html[range]).replacingOccurrences(of: "window.location.replace(", with: "").dropLast()
        let callback = try JSONDecoder().decode(String.self, from: Data(quoted.utf8))
        try await completeSignIn(attempt, callback: URL(string: callback)!)
    }

    /// 测试用：让 access token 立刻过期（下一次调用会换新的）
    func debugExpireAccess() { accessExpires = .distantPast }

    var debugState: [String: Any] {
        var state: [String: Any] = ["url": savedURL?.absoluteString ?? "", "hasAccount": account != nil]
        switch status {
        case .signedOut: state["status"] = "signedOut"
        case .signedIn: state["status"] = "signedIn"
        case .expired(let message): state["status"] = "expired"; state["message"] = message
        }
        if let account { state["email"] = account.email; state["serverName"] = account.serverName; state["engine"] = account.engine }
        state["glossary"] = CompanyGlossary.terms
        return state
    }
    #endif
}

/// 挡掉转址：回传 nil，URLSession 就把 3xx 的回应原样交回来（EnterpriseServer.send 当成错误）
private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
