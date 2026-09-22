import Testing
import Foundation
@testable import harness

// ---------------------------------------------------------------------------
// HarnessTests.swift — the swift-testing suite (`swift test`).
//
// Mirrors the layers of `--selftest` / `--e2e`, but through the framework:
//   * swift-testing runs tests in PARALLEL and always rebuilds first — no
//     stale-binary trap (a failed build previously left an old test binary
//     "passing").
//   * `#expect` records failures with file/line, vs. hand-rolled ✓/✗.
//   * `@testable import harness` reaches the executable's internals — fine
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
        let cloud = Config.resolve(arguments: [], env: ["OLLAMA_API_KEY": "stub-key"])
        #expect(cloud.provider == "ollama-cloud")
        #expect(cloud.baseURL == "https://ollama.com/v1")
        #expect(cloud.model == "kimi-k2.7-code")

        let forced = Config.resolve(arguments: ["--provider", "openai"], env: ["OLLAMA_API_KEY": "a"])
        #expect(forced.provider == "openai" && forced.baseURL == "https://api.openai.com/v1")
    }

    @Test("env keys beat borrowed keys (two-pass autodetect)")
    func envKeysBeatBorrowed() {
        // deepseek has a borrowable pi key on machines with auth.json — an
        // explicit OPENAI_API_KEY must still win (caught a real regression).
        let resolved = Config.resolve(arguments: [], env: ["OPENAI_API_KEY": "explicit"])
        #expect(resolved.provider == "openai")
    }

    @Test("autodetect order: zai before deepseek")
    func autodetectOrder() {
        let both = Config.resolve(arguments: [], env: ["ZAI_API_KEY": "z", "DEEPSEEK_API_KEY": "d"])
        #expect(both.provider == "zai")
    }

    @Test("coding plan endpoints are opt-in")
    func codingPlans() {
        let cn = Config.resolve(arguments: ["--provider", "zai-coding-cn"], env: [:])
        #expect(cn.provider == "zai-coding-cn")
        #expect(cn.baseURL == "https://open.bigmodel.cn/api/coding/paas/v4")
        #expect(cn.model == "glm-5.3")

        let intl = Config.resolve(arguments: ["--provider", "zai-coding"], env: [:])
        #expect(intl.provider == "zai-coding")
        #expect(intl.baseURL == "https://api.z.ai/api/coding/paas/v4")
    }

    @Test("pi-stored keys are borrowed on explicit selection")
    func piKeyBorrowing() {
        // Only assert when pi's auth.json is present (environment-dependent).
        guard FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.pi/agent/auth.json") else { return }
        let codingCN = Config.resolve(arguments: ["--provider", "zai-coding-cn"], env: [:])
        #expect(codingCN.apiKey != "none")
        let deepseek = Config.resolve(arguments: ["--provider", "deepseek"], env: [:])
        #expect(deepseek.apiKey != "none")
    }

    @Test("zero-setup deepseek default via borrowed pi key")
    func deepseekDefault() {
        guard FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.pi/agent/auth.json") else { return }
        #expect(Config.resolve(arguments: [], env: [:]).provider == "deepseek")
    }

    @Test("wire quirks are profile data")
    func wireQuirks() {
        #expect(Config.resolve(arguments: [], env: ["OPENAI_API_KEY": "k"]).tokenLimitKey == "max_completion_tokens")
        #expect(Config.resolve(arguments: [], env: ["OLLAMA_API_KEY": "k"]).streamOptions)
        #expect(!Config.resolve(arguments: [], env: ["ZAI_API_KEY": "k"]).streamOptions)
    }
}

@Suite("TypeSafe judge wire contract")
struct TypeSafeTests {
    private var questions: [TypeSafeQuestion] {
        [
            TypeSafeQuestion(id: "urgent", type: "noul", instructions: "Is this urgent?",
                             criteria: .object(["true": .string("Time-sensitive"), "false": .string("No urgency")])),
            TypeSafeQuestion(id: "team", type: "choice", instructions: "Which team?",
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
        let rendered = TypeSafeClient.format(response)
        #expect(rendered.contains("95%"))
        #expect(rendered.contains("billing"))
        #expect(rendered.contains("0.81"))
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
    @Test("endpoint mismatch keeps the launch model; conversation loads")
    func mismatchKeepsLaunchModel() async throws {
        let dir = NSTemporaryDirectory() + "harness-loadtest-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sessionPath = dir + "session.json"

        let launchConfig = Config(
            provider: "stub", baseURL: "https://launch.example.com/v1", apiKey: "none", model: "launch-model")
        var agent = Agent(config: launchConfig, model: OpenAICompatClient(config: launchConfig))
        var messages: [Message] = [.system("sys")]

        let elsewhere = Session(model: "some-other-model", provider: "somewhere-else",
                                baseURL: "https://other.example.com/v1", messages: [.user("hi")])
        try elsewhere.save(to: URL(fileURLWithPath: sessionPath))
        await HarnessMain.handleCommand("/load \(sessionPath)", &agent, &messages)
        #expect(agent.config.model == "launch-model")
        #expect(messages.contains { $0.role == "user" && $0.content == "hi" })

        // Same endpoint → the session model IS restored.
        let sameEndpoint = Session(model: "same-model", provider: "stub",
                                   baseURL: "https://launch.example.com/v1", messages: [.user("hi")])
        try sameEndpoint.save(to: URL(fileURLWithPath: sessionPath))
        await HarnessMain.handleCommand("/load \(sessionPath)", &agent, &messages)
        #expect(agent.config.model == "same-model")
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