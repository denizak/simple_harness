import Testing
import Foundation
@testable import HarnessCore

// ---------------------------------------------------------------------------
// HarnessTests.swift — the swift-testing suite (`swift test`).
//
// Mirrors the layers of `--selftest` / `--e2e`, but through the framework:
//   * swift-testing runs tests in PARALLEL and always rebuilds first — no
//     stale-binary trap (a failed build previously left an old test binary
//     "passing").
//   * `#expect` records failures with file/line, vs. hand-rolled ✓/✗.
//   * `@testable import HarnessCore` reaches the executable's internals — fine
//     for a single-module project; a library split is the next growth step.
//
// Live provider tests stay behind `harness --e2e` (they cost real quota and
// need network); everything here is offline and deterministic.
// ---------------------------------------------------------------------------

private func toolContext(_ cwd: String, depth: Int = 0) -> ToolContext {
    let config = Config(provider: "stub", baseURL: "stub://stub", apiKey: "none", model: "stub")
    return ToolContext(config: config, model: OpenAICompatClient(config: config), cwd: cwd, depth: depth)
}

private func runTool(_ body: () async throws -> String) async -> String {
    do { return try await body() } catch { return "error: \(error.localizedDescription)" }
}

@Suite("Tool layer")
struct ToolLayerTests {
    @Test("write_file / read_file / offset / edit_file semantics")
    func fileTools() async {
        let path = NSTemporaryDirectory() + "harness-test-\(UUID().uuidString).txt"
        let content: [String: JSONValue] = ["path": .string(path), "content": .string("alpha\nbeta\ngamma")]
        let wrote = await runTool { try await Tools.writeFile.run(content, toolContext(".")) }
        #expect(wrote.contains("wrote"))

        let read = await runTool { try await Tools.readFile.run(["path": .string(path)] as [String: JSONValue], toolContext(".")) }
        #expect(read.contains("1  alpha") && read.contains("3  gamma"))

        let offset = await runTool {
            try await Tools.readFile.run(["path": .string(path), "offset": .number(2)] as [String: JSONValue], toolContext("."))
        }
        #expect(offset.contains("2  beta") && !offset.contains("alpha"))

        let edited = await runTool {
            try await Tools.editFile.run(
                ["path": .string(path), "old_text": .string("beta"), "new_text": .string("BETA")] as [String: JSONValue],
                toolContext("."))
        }
        #expect(edited.contains("edited"))
        let missing = await runTool {
            try await Tools.editFile.run(
                ["path": .string(path), "old_text": .string("nope"), "new_text": .string("x")] as [String: JSONValue],
                toolContext("."))
        }
        #expect(missing.contains("not found"))
        // "a" appears in both "alpha" and "gamma" — ambiguity must be refused.
        let ambiguous = await runTool {
            try await Tools.editFile.run(
                ["path": .string(path), "old_text": .string("a"), "new_text": .string("x")] as [String: JSONValue],
                toolContext("."))
        }
        #expect(ambiguous.contains("appears"))

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("bash: stdout, exit codes, watchdog timeout")
    func bash() async {
        let echo = await runTool {
            try await Tools.bash.run(["command": .string("echo hello-test")] as [String: JSONValue], toolContext("."))
        }
        #expect(echo.contains("hello-test") && echo.contains("exit code: 0"))

        let failing = await runTool {
            try await Tools.bash.run(["command": .string("exit 3")] as [String: JSONValue], toolContext("."))
        }
        #expect(failing.contains("exit code: 3"))

        let timedOut = await runTool {
            try await Tools.bash.run(
                ["command": .string("sleep 5"), "timeout_seconds": .number(1)] as [String: JSONValue], toolContext("."))
        }
        #expect(timedOut.contains("signal") || timedOut.contains("exit code: 15"))
    }

    @Test("grep: case sensitivity, recursion, no-match report")
    func grep() async {
        let dir = NSTemporaryDirectory() + "harness-test-grep-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir + "sub", withIntermediateDirectories: true)
        try? "needle here\nother line\n".write(toFile: dir + "a.txt", atomically: true, encoding: .utf8)
        try? "NEEDLE upper\n".write(toFile: dir + "sub/b.md", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let sensitive = await runTool {
            try await Tools.grep.run(["pattern": .string("needle"), "path": .string(dir)] as [String: JSONValue], toolContext("."))
        }
        #expect(sensitive.contains("a.txt:1") && !sensitive.contains("b.md"))

        let insensitive = await runTool {
            try await Tools.grep.run(
                ["pattern": .string("needle"), "path": .string(dir), "ignore_case": .bool(true)] as [String: JSONValue], toolContext("."))
        }
        #expect(insensitive.contains("NEEDLE upper"))

        let none = await runTool {
            try await Tools.grep.run(["pattern": .string("no-such-token"), "path": .string(dir)] as [String: JSONValue], toolContext("."))
        }
        #expect(none.contains("no matches"))
    }

    @Test("spawn_agent refuses at the depth cap")
    func spawnDepthCap() async {
        let output = await runTool { try await Tools.spawnAgent.run(["task": .string("x")] as [String: JSONValue], toolContext(".", depth: 2)) }
        #expect(output.contains("depth limit"))
    }
}

@Suite("Compaction boundary math")
struct CompactionBoundaryTests {
    /// 0 system | 1 user | 2 assistant→tools | 3 tool | 4 assistant
    /// | 5 user | 6 assistant→tools | 7 tool | 8 assistant
    private var history: [Message] {
        let call = ToolCall(id: "call_1", type: "function", function: .init(name: "bash", arguments: "{}"))
        let asking = Message(role: "assistant", content: nil, toolCalls: [call], toolCallId: nil, name: nil)
        return [
            .system("sys"), .user("first"), asking, .tool(result: "r1", for: call),
            Message(role: "assistant", content: "done", toolCalls: nil, toolCallId: nil, name: nil),
            .user("second task"), asking, .tool(result: "r2", for: call),
            Message(role: "assistant", content: "done again", toolCalls: nil, toolCallId: nil, name: nil),
        ]
    }

    @Test("tail starts mid-exchange, never on a tool result")
    func boundaryPlacement() {
        #expect(Compaction.tailStart(in: history, keepTail: 3) == 6)
    }

    @Test("tool results rejected; assistant tool_calls accepted")
    func boundaryRules() {
        let messages = history
        #expect(!Compaction.isCleanBoundary(messages[3]))
        #expect(!Compaction.isCleanBoundary(messages[7]))
        #expect(Compaction.isCleanBoundary(messages[6]))
    }
}

@Suite("Provider resolution")
struct ProviderTests {
    @Test("env-key autodetect and --provider override")
    func autodetectAndOverride() {
        let cloud = Config.resolve(arguments: [], env: ["OLLAMA_API_KEY": "stub-key"], pi: PIConfigSnapshot())
        #expect(cloud.provider == "ollama-cloud")
        #expect(cloud.baseURL == "https://ollama.com/v1")
        #expect(cloud.model == "kimi-k2.7-code")

        let forced = Config.resolve(arguments: ["--provider", "openai"], env: ["OLLAMA_API_KEY": "a"], pi: PIConfigSnapshot())
        #expect(forced.provider == "openai" && forced.baseURL == "https://api.openai.com/v1")
    }

    @Test("env keys beat borrowed keys (two-pass autodetect)")
    func envKeysBeatBorrowed() {
        // deepseek has a borrowable pi key on machines with auth.json — an
        // explicit OPENAI_API_KEY must still win (caught a real regression).
        let resolved = Config.resolve(arguments: [], env: ["OPENAI_API_KEY": "explicit"], pi: PIConfigSnapshot())
        #expect(resolved.provider == "openai")
    }

    @Test("autodetect order: zai before deepseek")
    func autodetectOrder() {
        let both = Config.resolve(arguments: [], env: ["ZAI_API_KEY": "z", "DEEPSEEK_API_KEY": "d"], pi: PIConfigSnapshot())
        #expect(both.provider == "zai")
    }

    @Test("openrouter: opt-in via env key or --provider, vendor/model ids")
    func openRouter() {
        let none = Config.resolve(arguments: [], env: [:], pi: PIConfigSnapshot())
        #expect(none.provider != "openrouter")  // not in autodetect order

        let byEnv = Config.resolve(arguments: [], env: ["OPENROUTER_API_KEY": "or-key"], pi: PIConfigSnapshot())
        #expect(byEnv.provider == "openrouter")
        #expect(byEnv.baseURL == "https://openrouter.ai/v1")
        #expect(byEnv.model == "anthropic/claude-sonnet-4.5")
        #expect(byEnv.apiKey == "or-key")

        let explicit = Config.resolve(arguments: ["--provider", "openrouter"], env: [:], pi: PIConfigSnapshot())
        #expect(explicit.provider == "openrouter" && explicit.apiKey == "none")  // no borrowing for openrouter
    }

    @Test("coding plan endpoints are opt-in")
    func codingPlans() {
        let cn = Config.resolve(arguments: ["--provider", "zai-coding-cn"], env: [:], pi: PIConfigSnapshot())
        #expect(cn.provider == "zai-coding-cn")
        #expect(cn.baseURL == "https://open.bigmodel.cn/api/coding/paas/v4")
        #expect(cn.model == "glm-5.3")

        let intl = Config.resolve(arguments: ["--provider", "zai-coding"], env: [:], pi: PIConfigSnapshot())
        #expect(intl.provider == "zai-coding")
        #expect(intl.baseURL == "https://api.z.ai/api/coding/paas/v4")
    }

    @Test("borrowed keys use injected snapshot with env precedence")
    func piKeyBorrowing() {
        let snapshot = PIConfigSnapshot(apiKeys: ["zai-coding-cn": "cn-secret", "deepseek": "deep-secret"])
        let codingCN = Config.resolve(arguments: ["--provider", "zai-coding-cn"], env: [:], pi: snapshot)
        #expect(codingCN.apiKey == "cn-secret")
        let explicit = Config.resolve(arguments: ["--provider", "deepseek"],
                                      env: ["DEEPSEEK_API_KEY": "explicit"], pi: snapshot)
        #expect(explicit.apiKey == "explicit")
    }

    @Test("only DeepSeek borrowed credentials satisfy autodetect")
    func deepseekDefault() {
        let noKeys = Config.resolve(arguments: [], env: [:], pi: PIConfigSnapshot())
        #expect(noKeys.provider == "ollama")
        let deepseek = Config.resolve(arguments: [], env: [:],
                                      pi: PIConfigSnapshot(apiKeys: ["deepseek": "deep-secret", "zai": "zai-secret"]))
        #expect(deepseek.provider == "deepseek" && deepseek.apiKey == "deep-secret")
        let openAIWins = Config.resolve(arguments: [], env: ["OPENAI_API_KEY": "open-secret"],
                                        pi: PIConfigSnapshot(apiKeys: ["deepseek": "deep-secret"]))
        #expect(openAIWins.provider == "openai" && openAIWins.apiKey == "open-secret")
    }

    @Test("pi auth parsing ignores OAuth, empty keys, and malformed input")
    func piAuthParsing() {
        let data = #"{"openai":{"type":"api_key","key":"ok"},"oauth":{"type":"oauth","key":"token"},"empty":{"type":"api_key","key":""}}"#.data(using: .utf8)!
        #expect(parsePIAuthKeys(data) == ["openai": "ok"])
        #expect(parsePIAuthKeys(Data("no json".utf8)).isEmpty)
        #expect(parsePIProvider(Data("no json".utf8)) == nil)
    }

    @Test("wire quirks are profile data")
    func wireQuirks() {
        #expect(Config.resolve(arguments: [], env: ["OPENAI_API_KEY": "k"], pi: PIConfigSnapshot()).tokenLimitKey == "max_completion_tokens")
        #expect(Config.resolve(arguments: [], env: ["OLLAMA_API_KEY": "k"], pi: PIConfigSnapshot()).streamOptions)
        #expect(!Config.resolve(arguments: [], env: ["ZAI_API_KEY": "k"], pi: PIConfigSnapshot()).streamOptions)
    }
}

@Suite("naluri wire contract")
struct TypeSafeTests {
    private var questions: [NaluriQuestion] {
        [
            NaluriQuestion(id: "urgent", type: "noul", instructions: "Is this urgent?",
                             criteria: .object(["true": .string("Time-sensitive"), "false": .string("No urgency")])),
            NaluriQuestion(id: "team", type: "choice", instructions: "Which team?",
                             criteria: .object(["billing": .string("Payments"), "tech": .string("Bugs")])),
        ]
    }

    @Test("request shape and criteria carrying")
    func requestBuilding() {
        let request = TypeSafeClient.request(state: "server down", questions: questions)
        let fields = request.objectValue ?? [:]
        #expect(fields["model"]?.stringValue == "jev-latest")
        #expect(fields["state"]?.stringValue == "server down")
        #expect(fields["questions"]?.objectValue?.count == 2)
        #expect(fields["questions"]?.objectValue?["urgent"]?.objectValue?["criteria"]?
            .objectValue?["true"]?.stringValue == "Time-sensitive")
    }

    @Test("answers render with probabilities and confidence")
    func formatting() {
        let response = JSONValue.parse(
            #"{"model":"jev-1.13.0","answers":{"urgent":{"type":"noul","noul":0.95},"# +
            #""team":{"type":"choice","choice":"billing","probabilities":{"billing":0.88,"tech":0.12},"confidence":0.81}}}"#) ?? .null
        let rendered = NaluriFormat.render(response)
        #expect(rendered.contains("95%"))
        #expect(rendered.contains("billing"))
        #expect(rendered.contains("0.81"))
    }
}

@Suite("pre-model gate")
struct GateTests {
    @Test("decision rule: below threshold rejects, at-or-above proceeds")
    func decisionRule() {
        #expect(ModelGate.decide(noulProbability: 0.49, threshold: 0.5) != nil)
        #expect(ModelGate.decide(noulProbability: 0.5, threshold: 0.5) == nil)
        #expect(ModelGate.decide(noulProbability: 0.95, threshold: 0.5) == nil)
    }

    @Test("gate question is a well-formed noul ask")
    func questionShape() {
        #expect(ModelGate.question.type == "noul")
        let request = TypeSafeClient.request(state: "fix the build", questions: [ModelGate.question])
        #expect(request.objectValue?["questions"]?.objectValue?[ModelGate.question.id]?
            .objectValue?["type"]?.stringValue == "noul")
    }

    @Test("gate config: opt-in flag and threshold bounds via env")
    func configResolution() {
        let off = Config.resolve(arguments: [], env: ["TYPESAFE_API_KEY": "k"], pi: PIConfigSnapshot())
        #expect(!off.gateEnabled)
        let on = Config.resolve(arguments: [], env: ["TYPESAFE_API_KEY": "k", "HARNESS_GATE": "1"], pi: PIConfigSnapshot())
        #expect(on.gateEnabled)
        #expect(on.gateThreshold == 0.5)
        let tuned = Config.resolve(arguments: [],
                                   env: ["HARNESS_GATE": "yes", "HARNESS_GATE_THRESHOLD": "0.8"],
                                   pi: PIConfigSnapshot())
        #expect(tuned.gateEnabled)
        #expect(tuned.gateThreshold == 0.8)
        // Out-of-range thresholds fall back to the default rather than
        // creating an always-reject (0) or always-proceed (>=1) gate.
        let bogus = Config.resolve(arguments: [], env: ["HARNESS_GATE": "1", "HARNESS_GATE_THRESHOLD": "1.5"], pi: PIConfigSnapshot())
        #expect(bogus.gateThreshold == 0.5)
    }
}

@Suite("JSON config file")
struct ConfigFileTests {
    private let entries: [String: JSONValue] = [
        "provider": .string("zai-coding"),
        "baseURL": .string("https://file.example/v1"),
        "apiKey": .string("file-key"),
        "model": .string("file-model"),
        "maxTurns": .number(7),
        "compactKeepTail": .number(1),
        "streaming": .bool(false),
        "gate": .bool(true),
        "gateThreshold": .number(0.8),
        "typesafeApiKey": .string("ts-key"),
        "unknownKey": .string("ignored"),
    ]

    @Test("file values apply; env overrides file; flags override env")
    func precedence() {
        let base = Config.resolve(arguments: [], env: [:], pi: PIConfigSnapshot(), file: entries)
        #expect(base.baseURL == "https://file.example/v1")
        #expect(base.model == "file-model")
        #expect(base.maxTurns == 7)
        #expect(base.compactKeepTail == 2)  // clamped like the env path
        #expect(!base.streaming)
        #expect(base.gateEnabled)
        #expect(base.gateThreshold == 0.8)
        #expect(base.typesafeApiKey == "ts-key")

        let envWins = Config.resolve(arguments: [], env: ["HARNESS_MODEL": "env-model"],
                                     pi: PIConfigSnapshot(), file: entries)
        #expect(envWins.model == "env-model")

        let flagWins = Config.resolve(arguments: ["--model", "flag-model"],
                                      env: ["HARNESS_MODEL": "env-model"],
                                      pi: PIConfigSnapshot(), file: entries)
        #expect(flagWins.model == "flag-model")
    }

    @Test("file provider selects a catalog profile; --provider outranks it")
    func providerSelection() {
        let fromFile = Config.resolve(arguments: [], env: [:], pi: PIConfigSnapshot(), file: entries)
        #expect(fromFile.provider == "zai-coding")

        let flagBeatsFile = Config.resolve(arguments: ["--provider", "openai"],
                                           env: [:], pi: PIConfigSnapshot(), file: entries)
        #expect(flagBeatsFile.provider == "openai")
        // The profile supplies endpoint/quirks, but the file's scalar values
        // (applied after catalog selection) still customize on top of it.
        #expect(flagBeatsFile.model == "file-model")
    }

    @Test("suppressed file loading keeps resolution deterministic")
    func noFileByDefault() {
        let plain = Config.resolve(arguments: [], env: [:], pi: PIConfigSnapshot())
        #expect(plain.model != "file-model")
    }

    @Test("flags override file values for gate and runtime settings")
    func flagOverrides() {
        let file: [String: JSONValue] = [
            "gate": .bool(true), "gateThreshold": .number(0.8),
            "streaming": .bool(true), "maxTurns": .number(7),
        ]
        let off = Config.resolve(arguments: ["--no-gate", "--no-streaming", "--max-turns", "3"],
                                 env: [:], pi: PIConfigSnapshot(), file: file)
        #expect(!off.gateEnabled)
        #expect(!off.streaming)
        #expect(off.maxTurns == 3)

        let tuned = Config.resolve(arguments: ["--gate-threshold", "0.6"],
                                   env: [:], pi: PIConfigSnapshot(), file: file)
        #expect(tuned.gateEnabled)  // from file
        #expect(tuned.gateThreshold == 0.6)
    }
}

@Suite("reasoning_effort quirk")
struct ReasoningTests {
    @Test("override lands in the body; absent by default")
    func requestQuirk() throws {
        let client = OpenAICompatClient(config: Config(
            provider: "quirky", baseURL: "https://example.com/v1", apiKey: "none", model: "gpt-5.6-luna"))
        let (plain, _) = try client.requestFor(messages: [.user("hi")], tools: [Tools.grep], streaming: false)
        #expect(plain["reasoning_effort"] == nil)
        let (overridden, _) = try client.requestFor(
            messages: [.user("hi")], tools: [], streaming: false,
            overrides: ["reasoning_effort": .string("none")])
        #expect(overridden["reasoning_effort"] == .string("none"))
    }

    @Test("conflict detection and retry guards")
    func conflictDetection() {
        let conflict = LLMError(status: 400, body:
            "Function tools with reasoning_effort are not supported for gpt-5.6-luna.")
        #expect(OpenAICompatClient.isReasoningToolConflict(conflict))
        #expect(OpenAICompatClient.shouldRetryWithNone(conflict, attempt: 0, sentEffort: true))
        #expect(!OpenAICompatClient.shouldRetryWithNone(conflict, attempt: 1, sentEffort: true))
        #expect(!OpenAICompatClient.shouldRetryWithNone(conflict, attempt: 0, sentEffort: false))
    }
}

@Suite("SSE assembler")
struct SSEAssemblerTests {
    @Test("text and tool_calls stitched from delta fragments")
    func stitching() {
        var assembler = SSEAssembler()
        let chunks = [
            #"{"choices":[{"delta":{"content":"Hel"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"ba","arguments":"{\"cmd\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"ls\"}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#,
        ]
        for chunk in chunks {
            guard let parsed = JSONValue.parse(chunk) else { Issue.record("chunk failed to parse: \(chunk)"); continue }
            _ = assembler.ingest(parsed)
        }
        let assembled = assembler.assembled()
        #expect(assembled.text == "Hel")
        #expect(assembled.toolCalls.count == 1)
        #expect(assembled.toolCalls[0].function.name == "ba")
        #expect(assembled.toolCalls[0].function.arguments == "{\"cmd\":\"ls\"}")
        #expect(assembled.toolCalls[0].id == "c1")
        #expect(assembled.finishReason == "tool_calls")
        #expect(assembled.usage?.promptTokens == 10)
    }
}

@Suite("/load precedence")
struct LoadPrecedenceTests {
    @Test("endpoint mismatch keeps the active model")
    func mismatchKeepsActive() {
        let elsewhere = Session(model: "some-other-model", provider: "somewhere-else",
                                baseURL: "https://other.example.com/v1", messages: [.user("hi")])
        #expect(elsewhere.restoreModel(activeBaseURL: "https://launch.example.com/v1") == nil)
    }

    @Test("endpoint match restores the session model")
    func matchRestoresSession() {
        let same = Session(model: "same-model", provider: "stub",
                           baseURL: "https://launch.example.com/v1", messages: [.user("hi")])
        #expect(same.restoreModel(activeBaseURL: "https://launch.example.com/v1") == "same-model")
    }

    @Test("old session files without an endpoint record restore the model")
    func legacyRestores() {
        let legacy = Session(model: "legacy-model", provider: "old", baseURL: nil, messages: [.user("hi")])
        #expect(legacy.restoreModel(activeBaseURL: "https://anything.example.com/v1") == "legacy-model")
    }
}

// ---------------------------------------------------------------------------
// Stub-model loop tests — the agent loop with a scripted ChatModel and REAL
// tools in a temp directory. Offline, deterministic: proves tool_calls parse,
// tools execute, results feed back, and the loop terminates.
// ---------------------------------------------------------------------------

actor StubModel: ChatModel {
    private let filePath: String
    private(set) var taskCalls = 0
    private(set) var summarizerCalls = 0

    init(filePath: String) { self.filePath = filePath }

    func complete(_ messages: [Message], tools: [ToolSpec]) async throws -> AssistantTurn {
        if messages.first?.content?.contains("compress a coding-agent conversation") == true {
            summarizerCalls += 1
            return AssistantTurn(text: "- stub: earlier turns summarized", toolCalls: [], finishReason: "stop", usage: nil)
        }
        taskCalls += 1
        switch taskCalls {
        case 1: return turn("bash", arguments: #"{"command": "yes 0123456789 | head -400"}"#)
        case 2:
            return turn("write_file", arguments: String(
                decoding: try JSONEncoder().encode(
                    ["path": .string(filePath), "content": .string("stub content")] as [String: JSONValue]), as: UTF8.self))
        case 3:
            return turn("read_file", arguments: String(
                decoding: try JSONEncoder().encode(["path": .string(filePath)] as [String: JSONValue]), as: UTF8.self))
        default:
            return AssistantTurn(text: "stub done", toolCalls: [], finishReason: "stop", usage: nil)
        }
    }

    private func turn(_ name: String, arguments: String) -> AssistantTurn {
        AssistantTurn(
            text: "", toolCalls: [ToolCall(id: "call_\(taskCalls)", type: "function",
            function: .init(name: name, arguments: arguments))],
            finishReason: "tool_calls", usage: nil)
    }
}

/// Script for the DELEGATION test: the parent asks for spawn_agent, the
/// sub-agent (sharing this stub) writes the file and reports, then the
/// parent finishes. Call order is deterministic (the loop is serial):
/// 1 = parent spawns, 2 = sub writes, 3 = sub reports, 4 = parent wraps up.
actor SpawnStubModel: ChatModel {
    private let filePath: String
    private(set) var taskCalls = 0

    init(filePath: String) { self.filePath = filePath }

    func complete(_ messages: [Message], tools: [ToolSpec]) async throws -> AssistantTurn {
        taskCalls += 1
        switch taskCalls {
        case 1:
            let task = "Create a file at \(filePath) with exactly 'spawned!' using write_file, " +
                       "then reply 'sub report: done'."
            return turn("spawn_agent", arguments: "{\"task\": \"\(task)\"}")
        case 2:
            return turn("write_file", arguments: String(
                decoding: try JSONEncoder().encode(
                    ["path": .string(filePath), "content": .string("spawned!")] as [String: JSONValue]), as: UTF8.self))
        case 3:
            return AssistantTurn(text: "sub report: done", toolCalls: [], finishReason: "stop", usage: nil)
        default:
            return AssistantTurn(text: "parent done", toolCalls: [], finishReason: "stop", usage: nil)
        }
    }

    private func turn(_ name: String, arguments: String) -> AssistantTurn {
        AssistantTurn(
            text: "", toolCalls: [ToolCall(id: "call_\(taskCalls)", type: "function",
            function: .init(name: name, arguments: arguments))],
            finishReason: "tool_calls", usage: nil)
    }
}

@Suite("Stub-model loop")
struct StubLoopTests {
    private func makeAgent(stub: StubModel, compactAboveBytes: Int) -> Agent {
        var config = Config(provider: "stub", baseURL: "stub://stub", apiKey: "none", model: "stub-1")
        config.compactAboveBytes = compactAboveBytes
        return Agent(config: config, model: stub)
    }

    @Test("big tool output forces exactly one summarizer; the exchange survives")
    func compactionMidTask() async throws {
        let dir = NSTemporaryDirectory() + "harness-looptest-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filePath = dir + "probe.txt"

        var config = Config(provider: "stub", baseURL: "stub://stub", apiKey: "none", model: "stub-1")
        config.compactAboveBytes = 3000
        config.compactKeepTail = 4
        let stub = StubModel(filePath: filePath)
        var agent = Agent(config: config, model: stub)
        var messages: [Message] = [.system("You are a coding agent harness fixture.")]

        try await agent.run(task: "write a probe file and read it back", messages: &messages)

        #expect(await stub.taskCalls == 4)
        #expect(await stub.summarizerCalls == 1)
        #expect(messages.count > 1 && (messages[1].content?.hasPrefix("[Auto-compacted]") ?? false))
        #expect((try? String(contentsOfFile: filePath, encoding: .utf8)) == "stub content")
        #expect(messages.last?.role == "assistant" && messages.last?.toolCalls == nil)
    }

    @Test("sub-agent delegation lands on disk and reports back")
    func delegation() async throws {
        let dir = NSTemporaryDirectory() + "harness-delegate-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filePath = dir + "sub.txt"

        var config = Config(provider: "stub", baseURL: "stub://stub", apiKey: "none", model: "stub-1")
        config.compactAboveBytes = 0
        let stub = SpawnStubModel(filePath: filePath)
        var agent = Agent(config: config, model: stub, depth: 0)
        var messages: [Message] = [.system("You are a coding agent harness fixture.")]

        try await agent.run(task: "delegate the file task", messages: &messages)

        #expect((try? String(contentsOfFile: filePath, encoding: .utf8)) == "spawned!")
        #expect(messages.contains { $0.role == "tool" && $0.content?.contains("SUB-AGENT REPORT") ?? false })
        #expect(messages.last?.role == "assistant" && messages.last?.toolCalls == nil)
    }
}
@Suite("naluri chat backend (logprobs)")
struct ChatNaluriTests {
    private let noul = NaluriQuestion(id: "urgent", type: "noul", instructions: "Is this urgent?")
    private let choice = NaluriQuestion(
        id: "team", type: "choice", instructions: "Which team?",
        criteria: .object(["billing": .string("Payments"), "tech": .string("Bugs")]))
    private let score = NaluriQuestion(
        id: "sev", type: "score", instructions: "How severe?",
        criteria: .array([.string("Low"), .string("Mid"), .string("High")]))

    @Test("distribution normalises over candidates, merging case and whitespace variants")
    func distribution() throws {
        let top: [(token: String, logprob: Double)] = [
            ("Yes", log(0.6)), (" yes", log(0.2)), ("no", log(0.1)), ("maybe", log(0.1)),
        ]
        let result = try #require(ChatNaluri.distribution(top: top, candidates: ["yes", "no"]))
        #expect(abs(result[0] - 0.8 / 0.9) < 1e-9)
        #expect(abs(result[1] - 0.1 / 0.9) < 1e-9)
        #expect(ChatNaluri.distribution(top: [("zzz", -1)], candidates: ["yes", "no"]) == nil)
    }

    @Test("prompts constrain the answer token and reject out-of-range questions")
    func prompts() throws {
        #expect(try ChatNaluri.prompt(for: noul, state: "x").candidates == ["yes", "no"])
        let picked = try ChatNaluri.prompt(for: choice, state: "x")
        #expect(picked.candidates == ["a", "b"])
        #expect(picked.text.contains("A. billing"))
        #expect(try ChatNaluri.prompt(for: score, state: "x").candidates == ["0", "1", "2"])
        let tooFew = NaluriQuestion(id: "s", type: "score", instructions: "?", criteria: .array([.string("only")]))
        #expect(throws: LLMError.self) { try ChatNaluri.prompt(for: tooFew, state: "x") }
    }

    @Test("answers use the shared shape and render through NaluriFormat")
    func answers() {
        let n = ChatNaluri.answer(for: noul, probabilities: [0.9, 0.1], calibrated: true)
        #expect(n.objectValue?["noul"]?.doubleValue == 0.9)
        let c = ChatNaluri.answer(for: choice, probabilities: [0.25, 0.75], calibrated: true)
        #expect(c.objectValue?["choice"]?.stringValue == "tech")
        let s = ChatNaluri.answer(for: score, probabilities: [0, 0.5, 0.5], calibrated: false)
        #expect(s.objectValue?["score"]?.doubleValue == 1.5)
        let rendered = NaluriFormat.render(.object(["answers": .object(["urgent": n, "team": c, "sev": s])]))
        #expect(rendered.contains("90%") && rendered.contains("tech") && rendered.contains("uncalibrated"))
    }

    @Test("backend selection: typesafe default, chat providers by name, none without keys")
    func selection() {
        var config = Config(provider: "ollama", baseURL: "http://x", apiKey: "none", model: "m")
        #expect(config.naluriBackend == nil)
        config.typesafeApiKey = "k"
        #expect(config.naluriBackend is TypeSafeBackend)
        config.naluriBackendName = "deepseek"
        config.provider = "deepseek"
        config.apiKey = "dk"
        let chat = config.naluriBackend as? ChatNaluri
        #expect(chat?.model == "deepseek-flash")
        config.naluriBackendName = "zai"
        config.provider = "zai"
        config.apiKey = "zk"
        #expect((config.naluriBackend as? ChatNaluri)?.model == "glm-5.3-flash")
    }
}

@Suite("naluri eval scoring")
struct NaluriEvalTests {
    private func answer(_ id: String, _ body: [String: JSONValue]) -> JSONValue {
        .object(["answers": .object([id: .object(body)]),
                 "usage": .object(["input_tokens": .number(100), "output_tokens": .number(2)])])
    }

    @Test("shipped case file decodes, ids unique, expectations valid")
    func caseFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let cases = try NaluriEvalCase.load(path: root.appendingPathComponent("Evals/naluri.json").path)
        #expect(cases.count >= 30)
        #expect(Set(cases.map(\.id)).count == cases.count)
        for testCase in cases {
            switch testCase.type {
            case "noul": #expect(["yes", "no"].contains(testCase.expected), "\(testCase.id)")
            case "choice": #expect(testCase.criteria?.objectValue?[testCase.expected] != nil, "\(testCase.id)")
            case "score":
                let levels = testCase.criteria?.arrayValue?.count ?? 0
                #expect((Int(testCase.expected) ?? -1) < levels, "\(testCase.id)")
            default: Issue.record("unknown type in \(testCase.id)")
            }
        }
    }

    @Test("noul: accuracy, confidence and Brier")
    func noul() {
        let testCase = NaluriEvalCase(id: "q", group: "g", state: "s", type: "noul",
                                      instructions: "?", criteria: nil, expected: "yes")
        let right = NaluriEvalScoring.grade(testCase, root: answer("q", ["type": .string("noul"), "noul": .number(0.9)]))
        #expect(right.correct && right.predicted == "yes" && right.inputTokens == 100)
        #expect(abs((right.brier ?? 9) - 0.02) < 1e-9)
        let wrong = NaluriEvalScoring.grade(testCase, root: answer("q", ["type": .string("noul"), "noul": .number(0.2)]))
        #expect(!wrong.correct && wrong.predicted == "no" && abs((wrong.confidence ?? 0) - 0.8) < 1e-9)
    }

    @Test("score: legend numbering (0- or 1-based) is respected")
    func scoreBase() {
        let testCase = NaluriEvalCase(id: "q", group: "g", state: "s", type: "score", instructions: "?",
                                      criteria: .array([.string("a"), .string("b"), .string("c")]), expected: "2")
        let oneBased: [String: JSONValue] = [
            "type": .string("score"), "score": .number(3.1), "confidence": .number(0.7),
            "legend": .object(["1": .string("a"), "2": .string("b"), "3": .string("c")])]
        #expect(NaluriEvalScoring.grade(testCase, root: answer("q", oneBased)).correct)
        let zeroBased: [String: JSONValue] = [
            "type": .string("score"), "score": .number(1.2),
            "legend": .object(["0": .string("a"), "1": .string("b"), "2": .string("c")])]
        let graded = NaluriEvalScoring.grade(testCase, root: answer("q", zeroBased))
        #expect(!graded.correct && graded.withinOne == true)
    }

    @Test("summary aggregates; skipped cases are not graded; cost uses assumed prices")
    func summary() {
        let testCase = NaluriEvalCase(id: "q", group: "g", state: "s", type: "noul",
                                      instructions: "?", criteria: nil, expected: "yes")
        let good = NaluriEvalScoring.grade(testCase, root: answer("q", ["type": .string("noul"), "noul": .number(0.9)]))
        var skipped = NaluriEvalScoring.grade(testCase, root: .null)
        skipped.skipped = true
        let summary = NaluriEvalSummary.summarize(backend: "b", model: "m", results: [good, skipped], costUSD: 0)
        #expect(summary.graded == 1 && summary.skipped == 1 && summary.accuracy == 1)
        let cost = NaluriEvalPricing.cost(backend: "deepseek", input: 1_000_000, output: 0)
        #expect(abs(cost - 0.30) < 1e-9)
    }
}
