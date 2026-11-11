import Foundation

/// 企业服务器的整理（R51、design §36.3、D123）：服务器转送 OpenAI 兼容格式给公司设置的模型。
/// 提示词照旧在 app 组好；key 是登录企业服务器拿到的 access token；模型留空就用公司设置的默认模型
struct EnterpriseAPI: LLMBackend {
    let model: String

    private var inner: OpenAICompatibleAPI {
        let base = EnterpriseServer.shared.savedURL
        return OpenAICompatibleAPI(model: model, baseURL: base?.appending(path: "api/v1/llm").absoluteString ?? "",
                                   key: {
                                       let token = try await EnterpriseServer.shared.validAccessToken()
                                       // 等 token 的时候换了服务器（加入链接）：新服务器的 token 不能送到旧的服务器
                                       guard let saved = EnterpriseServer.shared.savedURL, let base, EnterpriseServer.sameServer(saved, base) else {
                                           throw EnterpriseServer.Failure.loginExpired
                                       }
                                       return token
                                   }, requiresModel: false,
                                   name: String(localized: "公司的服务器"), plainServerErrors: true, session: EnterpriseServer.session)
    }

    func generateJSON(system: String, prompt: String, format: LLMClient.OutputFormat,
                      onStart: (Subprocess) -> Void) async throws -> Data {
        guard EnterpriseServer.shared.hasAccount else { throw LLMError.notConfigured(SummarizerProblem.enterpriseSignedOut.message) }
        do {
            do {
                return try await inner.generateJSON(system: system, prompt: prompt, format: format, onStart: onStart)
            } catch LLMError.rejected {
                // access token 被撤销或过期（401、403）：换一次 token 再送；换不到就是登录失效、账号被禁用（R49.4）
                EnterpriseServer.shared.invalidateAccess()
                _ = try await EnterpriseServer.shared.validAccessToken()
                return try await inner.generateJSON(system: system, prompt: prompt, format: format, onStart: onStart)
            }
        } catch let failure as EnterpriseServer.Failure {
            // 登录失效、账号被禁用：设置问题，暂停自动整理到重新登录（R51.3）
            throw LLMError.notConfigured(failure.errorDescription ?? SummarizerProblem.enterpriseSignedOut.message)
        } catch LLMError.rejected {
            throw LLMError.notConfigured(EnterpriseServer.Failure.loginExpired.errorDescription ?? "")
        }
    }

    /// 服务器提供的模型（GET /api/v1/llm/models）
    func listModels() async -> [String] {
        await Self.models()?.map(\.id) ?? []
    }

    /// 公司在后台设置的模型（R51.1）：id 给服务器、name 给人看；取不到是 nil
    struct Model: Identifiable, Equatable {
        let id: String
        let name: String
        let isDefault: Bool
    }

    static func models() async -> [Model]? {
        guard let (data, response) = try? await EnterpriseServer.shared.call("GET", "api/v1/llm/models", timeout: 15), response.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let name = (item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return Model(id: id, name: name, isDefault: item["default"] as? Bool ?? false)
        }
    }
}
