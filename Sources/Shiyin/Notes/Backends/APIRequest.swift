import Foundation

/// API 整理工具共用的 HTTP 送出与错误处理（design §8.4、§19.1）
@MainActor
enum APIRequest {
    struct Response {
        let status: Int
        let object: [String: Any]
        /// 错误回应里的消息；没有的话是回应开头的原文
        let message: String
    }

    /// 送出请求，HTTP 状态不是 200 时丢出看得懂的错误
    static func send(_ request: URLRequest, provider: String) async throws -> [String: Any] {
        let response = try await fetch(request, provider: provider)
        guard response.status == 200 else { throw error(response, provider: provider) }
        return response.object
    }

    /// 送出请求，不检查 HTTP 状态（OpenAI 兼容 API 要看错误内容决定要不要退回 JSON 模式）。
    /// 网络暂时出错、429、5xx 时自动重试一次（design §21.14、R20.5）；取消（Task 被取消）时丢出 CancellationError。
    /// session：企业服务器用不跟着转址的那一个（design §36.2、D126）
    static func fetch(_ request: URLRequest, provider: String, session: URLSession = .shared) async throws -> Response {
        var retried = false
        while true {
            let (data, response): (Data, URLResponse)
            do { (data, response) = try await session.data(for: request) }
            catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                if !retried, let code = (error as? URLError)?.code, retryableErrors.contains(code) {
                    retried = true
                    log.info("API request retry after network error \((error as NSError).code)")
                    try await Task.sleep(for: .seconds(5))
                    continue
                }
                throw LLMError.unreachable(String(localized: "连不到 \(provider)：\(error.localizedDescription)"))
            }
            let http = response as? HTTPURLResponse
            let result = parse(data, status: http?.statusCode ?? 0)
            // 429 是帐户没有额度时，等多久都不会好，不重试
            if !retried, retryableStatuses.contains(result.status), !isNoCredit(result) {
                retried = true
                let wait = min(30, max(1, Double(http?.value(forHTTPHeaderField: "retry-after") ?? "") ?? 5))
                log.info("API request retry after HTTP \(result.status), wait \(Int(wait))s")
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            return result
        }
    }

    private static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504]
    private static let retryableErrors: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                                                              .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]

    private static func parse(_ data: Data, status: Int) -> Response {
        let parsed = try? JSONSerialization.jsonObject(with: data)
        let object = parsed as? [String: Any] ?? [:]
        // Gemini 的 Interactions API 把错误包在数组里：[{"error": {...}}]（design §19.2）
        let errorObject = (object["error"] ?? (parsed as? [[String: Any]])?.first?["error"]) as? [String: Any]
        let message = (errorObject?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
        return Response(status: status, object: object, message: message)
    }

    private static func isNoCredit(_ response: Response) -> Bool {
        let message = response.message.lowercased()
        return response.status == 429 && ["credit", "quota", "billing"].contains { message.contains($0) }
    }

    /// 企业服务器自己的错误（design §36.2 的 `{"error": {"kind", "message"}}`）：只用服务器的消息（R51.6）；
    /// 转送的模型回的错误没有 kind，回传 nil 照一般的写法
    static func serverError(_ response: Response) -> LLMError? {
        guard let error = response.object["error"] as? [String: Any], error["kind"] is String,
              let message = error["message"] as? String, !message.isEmpty else { return nil }
        switch response.status {
        case 401, 403: return LLMError.rejected(message)
        case 429: return LLMError.limited(message)
        default: return LLMError.failed(message)
        }
    }

    static func error(_ response: Response, provider: String) -> LLMError {
        let status = response.status
        // Gemini 的 key 错误是 HTTP 400 加上「API key not valid」
        let keyProblem = status == 401 || (status == 400 && response.message.localizedCaseInsensitiveContains("API key"))
        // 429 有两种：额度用完（等多久都不会好，要加值）、短时间内用太多
        let noCredit = isNoCredit(response)
        let hint = keyProblem ? String(localized: "（API key 错误或已失效）")
            : noCredit ? String(localized: "（帐户没有额度，要到服务的网站加值）")
            : status == 429 ? String(localized: "（超过用量限制，请稍后再试）") : ""
        let message = String(localized: "\(provider) 回传 HTTP \(status)\(hint)：\(response.message)")
        // 设置问题和用量上限分开（design §34.4）：key 错误或没权限要改设置，429 等一下或加值
        if keyProblem || status == 403 { return LLMError.rejected(message) }
        if status == 429 { return LLMError.limited(message) }
        return LLMError.failed(message)
    }
}
