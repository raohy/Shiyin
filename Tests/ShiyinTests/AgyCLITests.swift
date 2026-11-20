import XCTest
@testable import Shiyin

final class AgyCLITests: XCTestCase {
    @MainActor
    func testParseModelsGroupsEffortsAndStripsSpinnerAndAnsi() {
        let raw = """
        \r⠋ Fetching available models...\r\u{001B}[2Kgemini-4-neon-high              Gemini 4 Neon (High)
        gemini-4-neon-xhigh             Gemini 4 Neon (XHigh)
        gemini-4-neon-medium            Gemini 4 Neon (Medium)
        gemini-4-neon-low               Gemini 4 Neon (Low)
        gemini-pro-orchestrator-neon    Orchestrator (Neon)
        gemini-3.8-flash-high           Gemini 3.8 Flash (High)
        gemini-3.8-flash-low            Gemini 3.8 Flash (Low)
        claude-opus-5-5-max             Claude Opus 5.5 (Max)
        gpt-oss-120b-medium             GPT-OSS 120B (Medium)
        Error: ignored trailing warning
        """

        let parsed = AgyCLI.parseModels(raw)
        XCTAssertEqual(parsed, [
            AgyCLI.ModelOption(id: "gemini-4-neon", displayName: "Gemini 4 Neon", efforts: [.low, .medium, .high, .xhigh]),
            AgyCLI.ModelOption(id: "gemini-pro-orchestrator-neon", displayName: "Orchestrator (Neon)", efforts: []),
            AgyCLI.ModelOption(id: "gemini-3.8-flash", displayName: "Gemini 3.8 Flash", efforts: [.low, .high]),
            AgyCLI.ModelOption(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", efforts: [.max]),
            AgyCLI.ModelOption(id: "gpt-oss-120b", displayName: "GPT-OSS 120B", efforts: [.medium]),
        ])
    }

    @MainActor
    func testResolvedModelAndEffortStripsConflictingSuffix() {
        XCTAssertEqual(AgyCLI.resolvedModelAndEffort(model: "gemini-3.8-flash-high", effort: .low).model, "gemini-3.8-flash")
        XCTAssertEqual(AgyCLI.resolvedModelAndEffort(model: "gemini-3.8-flash-high", effort: .low).effort, .low)
        XCTAssertEqual(AgyCLI.resolvedModelAndEffort(model: "gemini-3.8-flash-XHigh", effort: .medium).model, "gemini-3.8-flash")
        XCTAssertEqual(AgyCLI.resolvedModelAndEffort(model: "gemini-3.8-flash-high", effort: .auto).model, "gemini-3.8-flash-high")
        XCTAssertEqual(AgyCLI.resolvedModelAndEffort(model: "  gemini-pro-orchestrator-neon ", effort: .auto).model, "gemini-pro-orchestrator-neon")
    }

    @MainActor
    func testBuildArgumentsForCLIs() {
        let agyDefault = AgyCLI.buildArguments(schemaPath: "/tmp/schema.json", model: "",
                                               thinkingEffort: .auto, promptArgument: "- leading dash")
        XCTAssertEqual(agyDefault, [
            "--output-format", "json", "--disable-slash-commands", "--json-schema", "/tmp/schema.json", "--print=- leading dash",
        ])

        let agyWithEffort = AgyCLI.buildArguments(schemaPath: "/tmp/schema.json", model: "gemini-3.8-flash-high",
                                                  thinkingEffort: .low, promptArgument: "prompt")
        XCTAssertEqual(agyWithEffort, [
            "--output-format", "json", "--disable-slash-commands", "--json-schema", "/tmp/schema.json",
            "--model", "gemini-3.8-flash", "--effort", "low", "--print=prompt",
        ])

        let claudeDefault = ClaudeCLI.buildArguments(system: "sys", schema: "{}", model: "", thinkingEffort: .auto)
        XCTAssertFalse(claudeDefault.contains("--effort"))
        let claudeMax = ClaudeCLI.buildArguments(system: "sys", schema: "{}", model: "claude-opus-5-5", thinkingEffort: .max)
        XCTAssertTrue(claudeMax.contains("--model"))
        XCTAssertTrue(claudeMax.contains("--effort"))
        XCTAssertEqual(claudeMax.last, "max")

        let codexDefault = CodexCLI.buildArguments(schemaPath: "/tmp/s.json", outputPath: "/tmp/o.json",
                                                   model: "", thinkingEffort: .auto)
        XCTAssertFalse(codexDefault.contains("-c"))
        let codexXHigh = CodexCLI.buildArguments(schemaPath: "/tmp/s.json", outputPath: "/tmp/o.json",
                                                 model: "gpt-5", thinkingEffort: .xhigh)
        XCTAssertEqual(Array(codexXHigh.suffix(5)), ["-m", "gpt-5", "-c", "model_reasoning_effort=xhigh", "-"])
    }

    @MainActor
    func testOpenAIAndGeminiRequestBodyIncludeThinkingEffort() throws {
        let format = LLMClient.OutputFormat(schema: #"{"type":"object","properties":{"ok":{"type":"boolean"}}}"#,
                                            toolName: "save", toolDescription: "Save")

        let openAIDefault = try OpenAIAPI.requestBody(model: "gpt-5", system: "sys", prompt: "hi",
                                                      format: format, thinkingEffort: .auto)
        XCTAssertNil(openAIDefault["reasoning"])
        let openAIHigh = try OpenAIAPI.requestBody(model: "gpt-5", system: "sys", prompt: "hi",
                                                   format: format, thinkingEffort: .high)
        XCTAssertEqual(openAIHigh["reasoning"] as? [String: String], ["effort": "high"])

        let geminiDefault = try GeminiAPI.requestBody(model: "gemini-3.8-flash", system: "sys", prompt: "hi",
                                                      format: format, thinkingEffort: .auto)
        XCTAssertNil(geminiDefault["generation_config"])
        let geminiXHigh = try GeminiAPI.requestBody(model: "gemini-4-neon", system: "sys", prompt: "hi",
                                                    format: format, thinkingEffort: .xhigh)
        XCTAssertEqual(geminiXHigh["generation_config"] as? [String: String], ["thinking_level": "xhigh"])
    }

    @MainActor
    func testParseJSONOutputHandlesSuccessFallbackAndErrors() throws {
        let okResult = SubprocessResult(status: 0, reason: .exit, stdout: Data(), stderr: "")
        let structuredStdout = Data(#"{"status":"SUCCESS","structured_output":{"title":"例会","ok":true}}"#.utf8)
        let structuredData = try AgyCLI.parseJSONOutput(stdout: structuredStdout, stderrTail: "", result: okResult)
        let structuredObj = try XCTUnwrap(JSONSerialization.jsonObject(with: structuredData) as? [String: Any])
        XCTAssertEqual(structuredObj["title"] as? String, "例会")
        XCTAssertEqual(structuredObj["ok"] as? Bool, true)

        let fencedStdout = Data(#"{"status":"SUCCESS","response":"```json\n{\"ok\":true}\n```"}"#.utf8)
        let fencedData = try AgyCLI.parseJSONOutput(stdout: fencedStdout, stderrTail: "", result: okResult)
        let fencedObj = try XCTUnwrap(JSONSerialization.jsonObject(with: fencedData) as? [String: Any])
        XCTAssertEqual(fencedObj["ok"] as? Bool, true)

        let authStdout = Data(#"{"status":"ERROR","error":"Not logged in: authentication required"}"#.utf8)
        XCTAssertThrowsError(try AgyCLI.parseJSONOutput(stdout: authStdout, stderrTail: "", result: okResult)) { error in
            guard case LLMError.notLoggedIn("agy") = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let limitStdout = Data(#"{"status":"ERROR","error":"You've hit your usage limit"}"#.utf8)
        XCTAssertThrowsError(try AgyCLI.parseJSONOutput(stdout: limitStdout, stderrTail: "", result: okResult)) { error in
            guard case LLMError.limited = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let failResult = SubprocessResult(status: 2, reason: .exit, stdout: Data(), stderr: "bad flag")
        XCTAssertThrowsError(try AgyCLI.parseJSONOutput(stdout: Data(), stderrTail: "bad flag", result: failResult)) { error in
            guard case LLMError.failed(let detail, let cause) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(detail, "bad flag")
            XCTAssertEqual(cause, .cliExit2)
        }
    }

    @MainActor
    func testAgyCLIWithMockToolEndToEnd() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agy-mock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prevToolDir = UserDefaults.standard.object(forKey: "debugToolDirectory")
        let prevNoCLI = UserDefaults.standard.object(forKey: "debugNoCLI")
        let prevCache = AgyCLI.cachedModelOptions
        defer {
            if let prevToolDir { UserDefaults.standard.set(prevToolDir, forKey: "debugToolDirectory") }
            else { UserDefaults.standard.removeObject(forKey: "debugToolDirectory") }
            if let prevNoCLI { UserDefaults.standard.set(prevNoCLI, forKey: "debugNoCLI") }
            else { UserDefaults.standard.removeObject(forKey: "debugNoCLI") }
            AgyCLI.cachedModelOptions = prevCache
            try? FileManager.default.removeItem(at: dir)
        }

        let argsRecord = dir.appendingPathComponent("recorded-args.json")
        let scriptURL = dir.appendingPathComponent("agy")
        let script = """
        #!/usr/bin/env python3
        import json, sys
        if len(sys.argv) > 1 and sys.argv[1] == "models":
            print("\\r⠋ Fetching available models...\\rgemini-3.8-flash-low   Gemini 3.8 Flash (Low)")
            print("gemini-3.8-flash-high  Gemini 3.8 Flash (High)")
            print("gemini-pro-orchestrator-neon  Orchestrator (Neon)")
            sys.exit(0)
        with open(\(String(reflecting: argsRecord.path)), "w", encoding="utf-8") as f:
            json.dump(sys.argv[1:], f, ensure_ascii=False)
        print(json.dumps({"status": "SUCCESS", "structured_output": {"answer": "mocked"}}))
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        UserDefaults.standard.set(dir.path, forKey: "debugToolDirectory")
        UserDefaults.standard.set(false, forKey: "debugNoCLI")

        let options = await AgyCLI.fetchModelOptions()
        XCTAssertEqual(options.map(\.id), ["gemini-3.8-flash", "gemini-pro-orchestrator-neon"])
        XCTAssertEqual(options.first?.efforts, [.low, .high])
        XCTAssertEqual(options.last?.efforts, [])

        let backend = AgyCLI(model: "gemini-3.8-flash-high", thinkingEffort: .low)
        let format = LLMClient.OutputFormat(schema: #"{"type":"object","properties":{"answer":{"type":"string"}}}"#,
                                            toolName: "test_tool", toolDescription: "Test")
        let data = try await backend.generateJSON(system: "SYSTEM", prompt: "USER", format: format, onStart: { _ in })
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(response["answer"], "mocked")

        let recordedData = try Data(contentsOf: argsRecord)
        let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: recordedData) as? [String])
        XCTAssertTrue(recorded.contains("--output-format"))
        XCTAssertTrue(recorded.contains("--disable-slash-commands"))
        XCTAssertTrue(recorded.contains("--json-schema"))
        if let modelIdx = recorded.firstIndex(of: "--model") {
            XCTAssertEqual(recorded[modelIdx + 1], "gemini-3.8-flash")
        } else {
            XCTFail("Missing --model flag")
        }
        if let effortIdx = recorded.firstIndex(of: "--effort") {
            XCTAssertEqual(recorded[effortIdx + 1], "low")
        } else {
            XCTFail("Missing --effort flag")
        }
        XCTAssertTrue(recorded.contains("--print=SYSTEM\n\nUSER"))
    }
}
