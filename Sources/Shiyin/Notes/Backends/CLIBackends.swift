import Foundation

// claude / codex CLI（沿用第二版，design §8.4）。
// 工作目录是一个空的暂存文件夹：不会读到任何项目的 CLAUDE.md，用完就删

struct ClaudeCLI: LLMBackend {
    let model: String
    var thinkingEffort: ThinkingEffort = .auto

    static func buildArguments(system: String, schema: String, model: String, thinkingEffort: ThinkingEffort) -> [String] {
        // 不能加 --bare：--bare 不读 OAuth 登录信息
        var args = ["-p", "--output-format", "json", "--tools", "", "--no-session-persistence", "--strict-mcp-config",
                    "--system-prompt", system, "--json-schema", schema]
        if !model.isEmpty { args += ["--model", model] }
        if thinkingEffort != .auto { args += ["--effort", thinkingEffort.rawValue] }
        return args
    }

    func generateJSON(system: String, prompt: String, format: LLMClient.OutputFormat,
                      onStart: (Subprocess) -> Void) async throws -> Data {
        guard let exe = Paths.findTool("claude") else { throw LLMError.notInstalled("claude") }
        let dir = try Paths.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let args = Self.buildArguments(system: system, schema: format.schema, model: model, thinkingEffort: thinkingEffort)
        let process = Subprocess(exe, args, directory: dir)
        onStart(process)
        let result = try await process.run(input: Data(prompt.utf8), timeout: LLMClient.timeout)
        let text = String(decoding: result.stdout, as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            let detail = result.stderrTail(500)
            if LLMError.isLoginProblem(detail + text) { throw LLMError.notLoggedIn("claude") }
            if LLMError.isLimitProblem(detail + text) { throw LLMError.cliLimited(.claude, output: detail + "\n" + text) }
            throw LLMError.failed(detail.isEmpty ? String(localized: "claude 没有回传结果（结束代码 \(result.status)）") : detail,
                                  cause: .cli(result))
        }
        if (object["is_error"] as? Bool) == true || object["structured_output"] == nil {
            let message = (object["result"] as? String) ?? result.stderrTail(500)
            if LLMError.isLoginProblem(message) { throw LLMError.notLoggedIn("claude") }
            if LLMError.isLimitProblem(message) { throw LLMError.cliLimited(.claude, output: message) }
            throw LLMError.failed(String(message.prefix(500)), cause: .cliError)
        }
        return try JSONSerialization.data(withJSONObject: object["structured_output"]!)
    }

    func listModels() async -> [String] { [] }
}

struct CodexCLI: LLMBackend {
    let model: String
    var thinkingEffort: ThinkingEffort = .auto

    static func buildArguments(schemaPath: String, outputPath: String, model: String,
                               thinkingEffort: ThinkingEffort) -> [String] {
        var args = ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never",
                    "--output-schema", schemaPath, "-o", outputPath]
        if !model.isEmpty { args += ["-m", model] }
        if thinkingEffort != .auto { args += ["-c", "model_reasoning_effort=\(thinkingEffort.rawValue)"] }
        args.append("-")
        return args
    }

    func generateJSON(system: String, prompt: String, format: LLMClient.OutputFormat,
                      onStart: (Subprocess) -> Void) async throws -> Data {
        guard let tool = Paths.locateTool("codex") else { throw LLMError.notInstalled("codex") }
        let dir = try Paths.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaFile = dir.appendingPathComponent("schema.json")
        let output = dir.appendingPathComponent("out.json")
        try format.schema.write(to: schemaFile, atomically: true, encoding: .utf8)
        let args = Self.buildArguments(schemaPath: schemaFile.path, outputPath: output.path,
                                       model: model, thinkingEffort: thinkingEffort)
        let process = Subprocess(tool.url, args, environment: tool.environment, directory: dir)
        onStart(process)
        // Codex 没有独立的系统提示词参数，放在用户提示词前面
        let result = try await process.run(input: Data((system + "\n\n" + prompt).utf8), timeout: LLMClient.timeout)
        guard result.succeeded, let data = try? Data(contentsOf: output), !data.isEmpty else {
            let detail = result.stderrTail(500)
            if LLMError.isLoginProblem(detail) { throw LLMError.notLoggedIn("codex") }
            if LLMError.isLimitProblem(detail) { throw LLMError.cliLimited(.codex, output: detail) }
            let message = detail.isEmpty ? String(localized: "codex 没有回传结果（结束代码 \(result.status)）") : detail
            // 桌面版附的 codex 出错：建议另外装 CLI（R55.4）
            if let app = tool.desktopApp {
                throw LLMError.failed(message + "\n" + String(localized: "这是 \(app) 附的 codex，也可以另外安装 Codex CLI（npm install -g @openai/codex）再试。"),
                                      cause: .cli(result))
            }
            throw LLMError.failed(message, cause: .cli(result))
        }
        return data
    }

    func listModels() async -> [String] { [] }
}

/// Antigravity CLI（agy，design §F53）：非交互模式使用 --print=<prompt> 和 --json-schema
struct AgyCLI: LLMBackend {
    struct ModelOption: Equatable, Identifiable, Sendable {
        let id: String
        let displayName: String
        let efforts: [ThinkingEffort]
    }

    @MainActor static var cachedModelOptions: [ModelOption] = []

    private static let effortSuffixes: [(suffix: String, labelSuffix: String, effort: ThinkingEffort)] = [
        ("-xhigh", " (XHigh)", .xhigh),
        ("-medium", " (Medium)", .medium),
        ("-high", " (High)", .high),
        ("-low", " (Low)", .low),
        ("-max", " (Max)", .max),
    ]
    private static let maxInlinePromptBytes = 700_000

    let model: String
    var thinkingEffort: ThinkingEffort = .auto

    static func resolvedModelAndEffort(model: String, effort: ThinkingEffort) -> (model: String, effort: ThinkingEffort) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard effort != .auto, !trimmed.isEmpty else { return (trimmed, effort) }
        let lower = trimmed.lowercased()
        for item in effortSuffixes where lower.hasSuffix(item.suffix) {
            return (String(trimmed.dropLast(item.suffix.count)), effort)
        }
        return (trimmed, effort)
    }

    static func buildArguments(schemaPath: String, model: String, thinkingEffort: ThinkingEffort,
                               promptArgument: String) -> [String] {
        var args = ["--output-format", "json", "--disable-slash-commands", "--json-schema", schemaPath]
        let (resolvedModel, resolvedEffort) = resolvedModelAndEffort(model: model, effort: thinkingEffort)
        if !resolvedModel.isEmpty { args += ["--model", resolvedModel] }
        if resolvedEffort != .auto { args += ["--effort", resolvedEffort.rawValue] }
        args.append("--print=\(promptArgument)")
        return args
    }

    static func parseModels(_ rawOutput: String) -> [ModelOption] {
        struct Entry {
            var id: String
            var displayName: String
            var efforts: [ThinkingEffort]
        }

        var entries: [Entry] = []
        var indexById: [String: Int] = [:]

        for rawLine in rawOutput.split(whereSeparator: \.isNewline) {
            let afterCR = rawLine.split(separator: "\r", omittingEmptySubsequences: true).last.map(String.init) ?? ""
            let cleaned = afterCR
                .replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if ["Error:", "error:", "Fetching ", "Usage:"].contains(where: { cleaned.hasPrefix($0) }) { continue }

            let parts = cleaned.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard let first = parts.first else { continue }
            let rawId = String(first)
            guard let head = rawId.first, head.isASCII, head.isLetter || head.isNumber,
                  rawId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._:/".contains($0)) }),
                  !rawId.hasSuffix(":") else { continue }
            let rawName = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : rawId

            let lowerId = rawId.lowercased()
            var baseId = rawId
            var cleanName = rawName.isEmpty ? rawId : rawName
            var matchedEffort: ThinkingEffort?

            for item in effortSuffixes where lowerId.hasSuffix(item.suffix) {
                baseId = String(rawId.dropLast(item.suffix.count))
                matchedEffort = item.effort
                if cleanName.lowercased().hasSuffix(item.labelSuffix.lowercased()) {
                    cleanName = String(cleanName.dropLast(item.labelSuffix.count)).trimmingCharacters(in: .whitespaces)
                }
                if cleanName.isEmpty { cleanName = baseId }
                break
            }

            if let existing = indexById[baseId] {
                if let matchedEffort, !entries[existing].efforts.contains(matchedEffort) {
                    entries[existing].efforts.append(matchedEffort)
                }
            } else {
                indexById[baseId] = entries.count
                entries.append(Entry(id: baseId, displayName: cleanName, efforts: matchedEffort.map { [$0] } ?? []))
            }
        }

        let order = Dictionary(uniqueKeysWithValues: ThinkingEffort.orderedLevels.enumerated().map { ($1, $0) })
        return entries.map { entry in
            let sortedEfforts = entry.efforts.sorted { (order[$0] ?? Int.max) < (order[$1] ?? Int.max) }
            return ModelOption(id: entry.id, displayName: entry.displayName, efforts: sortedEfforts)
        }
    }

    static func parseJSONOutput(stdout: Data, stderrTail: String, result: SubprocessResult) throws -> Data {
        let text = String(decoding: stdout, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let parsedObject: [String: Any]? = {
            if let data = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
            if let line = text.split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .last(where: { $0.hasPrefix("{") }),
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                return obj
            }
            return nil
        }()

        guard let object = parsedObject else {
            let combined = stderrTail + "\n" + text
            if LLMError.isLoginProblem(combined) { throw LLMError.notLoggedIn("agy") }
            if LLMError.isLimitProblem(combined) { throw LLMError.cliLimited(.agy, output: combined) }
            throw LLMError.failed(stderrTail.isEmpty ? String(localized: "agy 没有回传结果（结束代码 \(result.status)）") : stderrTail,
                                  cause: .cli(result))
        }

        let isErrorStatus = (object["status"] as? String)?.uppercased() == "ERROR"
        let errorText = (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isErrorStatus || !errorText.isEmpty {
            let responseText = (object["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = !errorText.isEmpty ? errorText : (!responseText.isEmpty ? responseText : stderrTail)
            if LLMError.isLoginProblem(message) { throw LLMError.notLoggedIn("agy") }
            if LLMError.isLimitProblem(message) { throw LLMError.cliLimited(.agy, output: message) }
            throw LLMError.failed(String(message.prefix(500)), cause: .cliError)
        }

        if let structured = object["structured_output"], !(structured is NSNull),
           JSONSerialization.isValidJSONObject(structured) {
            return try JSONSerialization.data(withJSONObject: structured)
        }

        if let response = object["response"] as? String, !response.isEmpty {
            let extracted = OpenAICompatibleAPI.extractJSON(response)
            if let data = extracted.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
                return data
            }
        }

        let fallbackMessage = stderrTail.isEmpty ? String(localized: "agy 回传内容不含结构化结果") : stderrTail
        throw LLMError.failed(String(fallbackMessage.prefix(500)), cause: .cliError)
    }

    func generateJSON(system: String, prompt: String, format: LLMClient.OutputFormat,
                      onStart: (Subprocess) -> Void) async throws -> Data {
        guard let tool = Paths.locateTool("agy") else { throw LLMError.notInstalled("agy") }
        let dir = try Paths.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let schemaFile = dir.appendingPathComponent("schema.json")
        try format.schema.write(to: schemaFile, atomically: true, encoding: .utf8)

        let combined = system + "\n\n" + prompt
        let promptArgument: String
        if combined.utf8.count <= Self.maxInlinePromptBytes {
            promptArgument = combined
        } else {
            let promptFile = dir.appendingPathComponent("prompt.txt")
            try combined.write(to: promptFile, atomically: true, encoding: .utf8)
            promptArgument = "Read the full instructions and input from prompt.txt in the current working directory, follow them strictly, and respond with only the required JSON."
        }

        let args = Self.buildArguments(schemaPath: schemaFile.path, model: model,
                                       thinkingEffort: thinkingEffort, promptArgument: promptArgument)
        let process = Subprocess(tool.url, args, environment: tool.environment, directory: dir)
        onStart(process)
        let result = try await process.run(timeout: LLMClient.timeout)
        return try Self.parseJSONOutput(stdout: result.stdout, stderrTail: result.stderrTail(500), result: result)
    }

    @MainActor
    static func fetchModelOptions() async -> [ModelOption] {
        guard let tool = Paths.locateTool("agy") else { return [] }
        let process = Subprocess(tool.url, ["models"], environment: tool.environment,
                                 directory: FileManager.default.temporaryDirectory)
        guard let result = try? await process.run(timeout: 30), result.succeeded else { return [] }
        let parsed = parseModels(String(decoding: result.stdout, as: UTF8.self))
        if !parsed.isEmpty { cachedModelOptions = parsed }
        return parsed
    }

    func listModels() async -> [String] {
        await Self.fetchModelOptions().map(\.id)
    }
}
