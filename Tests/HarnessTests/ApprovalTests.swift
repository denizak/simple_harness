import Testing
import Foundation
@testable import HarnessCore

// ---------------------------------------------------------------------------
// ApprovalTests.swift — the tool-approval gate (T6), verified offline.
//
// The loop under test is the REAL Agent.execute choke point with a REAL
// write_file, driven by a scripted model and a scripted hook. Denial is
// proved by file content, not by mocking the tool: if the call had run, the
// bytes would be on disk. The one live-wire piece (the stdin prompt) is left
// to the selftest's scripted-stdin path, per the task spec.
//
// Deliberate contrast with GateTests: the classifier gate FAILS OPEN (an
// outage lets the request through); the approval gate FAILS CLOSED (no human
// to ask = no consent = the tool does not run).
// ---------------------------------------------------------------------------

/// Scripted loop model: try the dangerous call, then (when told to) fall back
/// to a read-only alternative. Records every tool result the loop produced so
/// tests can assert exactly-once semantics per call ID.
private actor GateScriptModel: ChatModel {
    private let filePath: String
    private let tasks: Int
    private var step = 0
    private(set) var toolResults: [String] = []

    init(filePath: String, tasks: Int = 1) {
        self.filePath = filePath
        self.tasks = tasks
    }

    /// The loop appends each tool result to `messages`; the model never sees
    /// them directly, so tests that need denial text assert on the transcript.
    func complete(_ messages: [Message], tools: [ToolSpec]) async throws -> AssistantTurn {
        // Turn WITHIN the current task: assistant messages since the last user
        // message — across two run() calls a flat counter would drift (task one
        // ends on a "done", task two must start over at write→read).
        let lastUser = messages.lastIndex { $0.role == "user" } ?? -1
        let turnInTask = messages[(lastUser + 1)...].filter { $0.role == "assistant" }.count + 1
        let scripted = messages.filter { $0.role == "user" }.count <= tasks
        step += 1
        // `content` first: the argument summary is capped at 80 chars and long
        // temp paths would otherwise push the payload past the cut.
        let write = #"{"content": "TAMPERED", "path": "\#(filePath)"}"#
        switch (turnInTask, scripted) {
        case (1, true):   return call("write_file", write)
        case (2, true):   return call("read_file",  #"{"path": "\#(filePath)"}"#)
        default:          return done("script done")
        }
    }

    private func call(_ name: String, _ arguments: String) -> AssistantTurn {
        AssistantTurn(text: "", toolCalls: [ToolCall(id: "gate-\(step)", function: .init(name: name, arguments: arguments))], finishReason: "tool_calls", usage: nil)
    }

    private func done(_ text: String) -> AssistantTurn {
        AssistantTurn(text: text, toolCalls: [], finishReason: "stop", usage: nil)
    }
}

/// A temp directory + a canary file whose content must survive every denial.
private struct Sandbox {
    let dir: URL
    let canary: URL
    let original = "unchanged bytes"

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        canary = dir.appendingPathComponent("canary.txt")
        try original.write(to: canary, atomically: true, encoding: .utf8)
    }

    func canaryUnchanged() -> Bool {
        (try? String(contentsOf: canary, encoding: .utf8)) == original
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

/// Stub config with streaming off (deterministic turns) and policy set.
/// A scripted decider: pops its script per ask, then denies (fail-closed
/// default for tests, so an unexpected extra ask can never execute a write).
/// Records what it was asked so tests can assert exactly-once prompting.
private actor HookRecorder {
    private var script: [ApprovalDecision]
    private(set) var askCount = 0
    private(set) var askedTools: [String] = []
    private(set) var askedSummaries: [String] = []

    init(script: [ApprovalDecision]) { self.script = script }

    /// Actor-isolated: the only place the script and the counters change.
    func decide(name: String, summary: String) -> ApprovalDecision {
        askCount += 1
        askedTools.append(name)
        askedSummaries.append(summary)
        return script.isEmpty ? .deny : script.removeFirst()
    }

    /// The ApprovalHook proper. `nonisolated` computed property returning a
    /// closure that hops back into the actor for every decision — the script
    /// stays serialized even when parent and sub-agent loops both ask.
    nonisolated var hook: ApprovalHook {
        { name, summary in
            await self.decide(name: name, summary: summary)
        }
    }
}

/// Emits one call whose arguments are not a JSON object, then finishes.
/// The parse guard must fire BEFORE the approval gate, so no hook is asked.
private actor BrokenArgsModel: ChatModel {
    private var step = 0
    func complete(_ messages: [Message], tools: [ToolSpec]) async throws -> AssistantTurn {
        step += 1
        if step == 1 {
            return AssistantTurn(text: "", toolCalls: [ToolCall(
                id: "gate-1", function: .init(name: "write_file", arguments: "this is not json"))],
                finishReason: "tool_calls", usage: nil)
        }
        return AssistantTurn(text: "gave up", toolCalls: [], finishReason: "stop", usage: nil)
    }
}

private func gateConfig(policy: ApprovalPolicy) -> Config {
    var config = Config(provider: "stub", baseURL: "stub://stub", apiKey: "none", model: "stub", approvalPolicy: policy)
    config.streaming = false
    return config
}

@Suite("Approval policy rule (pure)")
struct ApprovalRuleTests {
    @Test("never gates nothing, dangerous gates the mutating set, all gates everything")
    func ruleMatrix() {
        let remembered = ["bash", "grep", "write_file", "spawn_agent"]
        for tool in remembered {
            #expect(!ApprovalPolicy.never.requiresApproval(tool: tool, alreadyApproved: false))
        }
        #expect(ApprovalPolicy.dangerous.requiresApproval(tool: "bash", alreadyApproved: false))
        #expect(ApprovalPolicy.dangerous.requiresApproval(tool: "write_file", alreadyApproved: false))
        #expect(ApprovalPolicy.dangerous.requiresApproval(tool: "edit_file", alreadyApproved: false))
        for tool in ["grep", "read_file", "spawn_agent", "judge"] {
            #expect(!ApprovalPolicy.dangerous.requiresApproval(tool: tool, alreadyApproved: false))
        }
        for tool in ApprovalPolicy.dangerousTools + ["grep", "read_file"] {
            #expect(ApprovalPolicy.all.requiresApproval(tool: tool, alreadyApproved: false))
        }
    }

    @Test("an already-approved tool is never asked about again, under any policy")
    func alwaysSuppression() {
        for policy in [ApprovalPolicy.dangerous, .all] {
            #expect(!policy.requiresApproval(tool: "bash", alreadyApproved: true))
            #expect(!policy.requiresApproval(tool: "read_file", alreadyApproved: true))
        }
    }

    @Test("policy parsing: exact words, case-insensitive; junk stays nil")
    func parsing() {
        #expect(ApprovalPolicy.parse("all") == .all)
        #expect(ApprovalPolicy.parse("DANGEROUS") == .dangerous)
        #expect(ApprovalPolicy.parse("Never") == .never)
        #expect(ApprovalPolicy.parse("sometimes") == nil)
        #expect(ApprovalPolicy.parse("") == nil)
    }

    @Test("decision parsing: y/yes approve, a/always remember, anything else denies")
    func decisionParsing() {
        #expect(ApprovalDecision.parse(line: "y") == .approve)
        #expect(ApprovalDecision.parse(line: "  YES\n") == .approve)
        #expect(ApprovalDecision.parse(line: "a") == .approveAlways)
        #expect(ApprovalDecision.parse(line: "always") == .approveAlways)
        #expect(ApprovalDecision.parse(line: "n") == .deny)
        #expect(ApprovalDecision.parse(line: "maybe") == .deny)
        #expect(ApprovalDecision.parse(line: nil) == .deny)  // EOF is not consent
    }

    @Test("argument summary is one line and bounded")
    func summaries() {
        #expect(approvalArgumentSummary("{\"path\": \"a.txt\"}") == "{\"path\": \"a.txt\"}")
        #expect(!approvalArgumentSummary("line1\nline2").contains("\n"))
        #expect(approvalArgumentSummary("").isEmpty == false)
        let long = String(repeating: "x", count: 500)
        #expect(approvalArgumentSummary(long).count == 80)
        #expect(approvalArgumentSummary(long).hasSuffix("..."))
    }

    @Test("denial text names the tool")
    func denialText() {
        #expect(approvalDeniedText(tool: "bash").contains("bash"))
        #expect(approvalDeniedText(tool: "bash").hasPrefix("error:"))
    }
}

// ---------------------------------------------------------------------------
// Loop-level tests: the real Agent.execute choke point + a real write_file.
// ---------------------------------------------------------------------------

@Suite("Approval gate in the loop")
struct ApprovalLoopTests {
    @Test("policy never: existing behavior, no hook consulted even if installed")
    func neverChangesNothing() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let recorder = HookRecorder(script: [.approve, .approve])
        let model = GateScriptModel(filePath: sandbox.canary.path)
        var agent = Agent(config: gateConfig(policy: .never), model: model)
        agent.approvalHook = recorder.hook
        agent.approvalState = ApprovalState()
        var messages: [Message] = [.system("approval fixture")]
        try await agent.run(task: "write the canary", messages: &messages)

        let askCount = await recorder.askCount
        #expect(askCount == 0)  // never = the gate is silent
        #expect((try? String(contentsOf: sandbox.canary, encoding: .utf8)) == "TAMPERED")
    }

    @Test("deny: tool never runs (file untouched by content), one tool result, loop continues")
    func denyLeavesDiskUntouched() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let model = GateScriptModel(filePath: sandbox.canary.path)
        var config = gateConfig(policy: .dangerous)
        config.maxTurns = 5
        var agent = Agent(config: config, model: model)
        agent.approvalHook = { _, _ in .deny }
        var messages: [Message] = [.system("approval fixture")]
        try await agent.run(task: "write the canary", messages: &messages)

        // The write was denied, the read was allowed: both calls answered
        // exactly once, and the canary content is what we wrote, not TAMPERED.
        let toolResults = messages.filter { $0.role == "tool" }
        #expect(toolResults.map { $0.toolCallId } == ["gate-1", "gate-2"])
        #expect(toolResults[0].content?.contains("approval denied") == true)
        #expect(toolResults[0].content?.contains("write_file") == true)
        #expect(sandbox.canaryUnchanged())
        #expect(messages.last?.role == "assistant" && messages.last?.toolCalls == nil)
    }

    @Test("approve once: call runs this turn, hook is consulted again next turn")
    func approveOnce() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let recorder = HookRecorder(script: [.approve, .approve])
        let model = GateScriptModel(filePath: sandbox.canary.path)
        var agent = Agent(config: gateConfig(policy: .dangerous), model: model)
        agent.approvalHook = recorder.hook
        var messages: [Message] = [.system("approval fixture")]
        try await agent.run(task: "write then read", messages: &messages)

        #expect(await recorder.askCount == 1)  // write gated; read NOT gated (read-only)
        let writeResult = try #require(messages.first { $0.toolCallId == "gate-1" })
        #expect(writeResult.content?.contains("TAMPERED") != true)
        #expect(writeResult.content?.contains("wrote") == true)
        #expect((try? String(contentsOf: sandbox.canary, encoding: .utf8)) == "TAMPERED")
    }

    @Test("nil hook under a demanding policy denies without executing (fail-closed)")
    func nilHookFailsClosed() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let model = GateScriptModel(filePath: sandbox.canary.path)
        var agent = Agent(config: gateConfig(policy: .dangerous), model: model)
        // No hook installed — the --once situation.
        var messages: [Message] = [.system("approval fixture")]
        try await agent.run(task: "write the canary", messages: &messages)

        let writeResult = try #require(messages.first { $0.toolCallId == "gate-1" })
        #expect(writeResult.content?.contains("no approval hook") == true)
        #expect(writeResult.content?.contains("dangerous") == true)
        #expect(sandbox.canaryUnchanged())
    }

    @Test("approveAlways suppresses the next prompt within the task")
    func approveAlwaysSuppresses() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let recorder = HookRecorder(script: [.approveAlways, .approve])
        let model = GateScriptModel(filePath: sandbox.canary.path)
        var agent = Agent(config: gateConfig(policy: .dangerous), model: model)
        agent.approvalHook = recorder.hook
        agent.approvalState = ApprovalState()
        var messages: [Message] = [.system("approval fixture")]
        try await agent.run(task: "write then write again", messages: &messages)

        let askCount = await recorder.askCount
        #expect(askCount == 1)  // asked once, remembered for the rest of the task
        #expect((try? String(contentsOf: sandbox.canary, encoding: .utf8)) == "TAMPERED")
    }

    @Test("a fresh task forgets the earlier 'always' and prompts again")
    func newTaskPromptsAgain() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let recorder = HookRecorder(script: [.approveAlways, .approveAlways])
        let model = GateScriptModel(filePath: sandbox.canary.path, tasks: 2)
        var agent = Agent(config: gateConfig(policy: .dangerous), model: model)
        agent.approvalHook = recorder.hook
        var messages: [Message] = [.system("approval fixture")]

        try await agent.run(task: "task one", messages: &messages)
        #expect(await recorder.askCount == 1)

        try await agent.run(task: "task two", messages: &messages)  // run() resets the state
        #expect(await recorder.askCount == 2)
    }

    @Test("continueRun (a /retry of the same task) keeps the 'always' approval")
    func retryKeepsAlways() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let recorder = HookRecorder(script: [.approveAlways])
        let model = GateScriptModel(filePath: sandbox.canary.path)
        var agent = Agent(config: gateConfig(policy: .dangerous), model: model)
        agent.approvalHook = recorder.hook
        var messages: [Message] = [.system("approval fixture")]

        try await agent.run(task: "the task", messages: &messages)
        #expect(await recorder.askCount == 1)

        // The same recorded conversation continued after a (scripted) failure:
        // what the user already approved must not be asked again.
        try await agent.continueRun(messages: &messages)
        #expect(await recorder.askCount == 1)
    }

    @Test("malformed arguments still fail as a parse error — never prompted")
    func unparseableCallIsNotPrompted() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let recorder = HookRecorder(script: [.approve])
        let model = BrokenArgsModel()
        var agent = Agent(config: gateConfig(policy: .dangerous), model: model)
        agent.approvalHook = recorder.hook
        var messages: [Message] = [.system("approval fixture")]
        try await agent.run(task: "broken json", messages: &messages)

        #expect(await recorder.askCount == 0)
        let result = try #require(messages.first { $0.role == "tool" })
        #expect(result.content?.contains("could not parse tool arguments") == true)
        #expect(sandbox.canaryUnchanged())
    }
}

// ---------------------------------------------------------------------------
// Config resolution: env, flag, config file, precedence — offline & pure.
// ---------------------------------------------------------------------------

@Suite("Approval config resolution")
struct ApprovalConfigTests {
    @Test("default is never; HARNESS_APPROVAL selects dangerous/all")
    func envResolution() throws {
        let base = Config.resolve(arguments: [], env: [:], pi: PIConfigSnapshot(), file: [:])
        #expect(base.approvalPolicy == .never)

        let dangerous = Config.resolve(arguments: [], env: ["HARNESS_APPROVAL": "dangerous"], pi: PIConfigSnapshot(), file: [:])
        #expect(dangerous.approvalPolicy == .dangerous)

        let all = Config.resolve(arguments: [], env: ["HARNESS_APPROVAL": "All"], pi: PIConfigSnapshot(), file: [:])
        #expect(all.approvalPolicy == .all)
    }

    @Test("the --approval flag wins over the environment")
    func flagBeatsEnv() throws {
        let config = Config.resolve(arguments: ["--approval", "never"], env: ["HARNESS_APPROVAL": "all"], pi: PIConfigSnapshot(), file: [:])
        #expect(config.approvalPolicy == .never)
    }

    @Test("a config file can set the policy; flags beat it too")
    func configFileAndPrecedence() throws {
        let fromFile = Config.resolve(arguments: [], env: [:], pi: PIConfigSnapshot(),
                                      file: ["approvalPolicy": .string("all")])
        #expect(fromFile.approvalPolicy == .all)

        let flagWins = Config.resolve(arguments: ["--approval", "dangerous"], env: [:], pi: PIConfigSnapshot(),
                                      file: ["approvalPolicy": .string("all")])
        #expect(flagWins.approvalPolicy == .dangerous)
    }

    @Test("unrecognized values warn and fall back to never")
    func junkValuesStayNever() throws {
        let config = Config.resolve(arguments: [], env: ["HARNESS_APPROVAL": "yolo"], pi: PIConfigSnapshot(), file: [:])
        #expect(config.approvalPolicy == .never)
    }
}

// ---------------------------------------------------------------------------
// Delegation: the hook and the task-scoped state travel through spawn_agent.
// ---------------------------------------------------------------------------

/// Parent asks spawn_agent; the sub-agent's dangerous write must consult the
/// SAME hook and state. Turn order is deterministic (the loop is serial):
/// 1 parent spawns → 2 sub writes → 3 sub reports → 4 parent wraps up.
private actor DelegationGateModel: ChatModel {
    private let filePath: String
    private var step = 0
    init(filePath: String) { self.filePath = filePath }

    func complete(_ messages: [Message], tools: [ToolSpec]) async throws -> AssistantTurn {
        step += 1
        switch step {
        case 1:
            let task = "Create a file at \(filePath) with exactly 'TAMPERED' using write_file, " +
                       "then reply 'sub report: done'."
            return turn("spawn_agent", #"{"task": "\#(task)"}"#)
        case 2:  return turn("write_file", #"{"content": "TAMPERED", "path": "\#(filePath)"}"#)
        case 3:  return done("sub report: done")
        default: return done("parent done")
        }
    }

    private func turn(_ name: String, _ arguments: String) -> AssistantTurn {
        AssistantTurn(text: "", toolCalls: [ToolCall(id: "del-\(step)", function: .init(name: name, arguments: arguments))], finishReason: "tool_calls", usage: nil)
    }

    private func done(_ text: String) -> AssistantTurn {
        AssistantTurn(text: text, toolCalls: [], finishReason: "stop", usage: nil)
    }
}

/// Script for the "always travels down" test: the parent writes the canary
/// ITSELF (turn 1, gets the 'always'), then delegates (turn 2), sub writes
/// (turn 3, must be covered), sub reports (turn 4), parent wraps (turn 5).
private actor ParentThenChildModel: ChatModel {
    private let filePath: String
    private var step = 0
    init(filePath: String) { self.filePath = filePath }

    func complete(_ messages: [Message], tools: [ToolSpec]) async throws -> AssistantTurn {
        step += 1
        switch step {
        case 1:  return turn("write_file", #"{"content": "TAMPERED", "path": "\#(filePath)"}"#)
        case 2:
            let task = "Create a file at \(filePath) with exactly 'TAMPERED' using write_file, " +
                       "then reply 'sub report: done'."
            return turn("spawn_agent", #"{"task": "\#(task)"}"#)
        case 3:  return turn("write_file", #"{"content": "TAMPERED", "path": "\#(filePath)"}"#)
        case 4:  return done("sub report: done")
        default: return done("parent done")
        }
    }

    private func turn(_ name: String, _ arguments: String) -> AssistantTurn {
        AssistantTurn(text: "", toolCalls: [ToolCall(id: "ptc-\(step)", function: .init(name: name, arguments: arguments))], finishReason: "tool_calls", usage: nil)
    }

    private func done(_ text: String) -> AssistantTurn {
        AssistantTurn(text: text, toolCalls: [], finishReason: "stop", usage: nil)
    }
}

@Suite("Approval across sub-agents")
struct ApprovalDelegationTests {
    @Test("the shared hook and 'always' state reach depth 1")
    func hookTravelsThroughSpawn() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let recorder = HookRecorder(script: [.approve, .approve])
        let model = DelegationGateModel(filePath: sandbox.canary.path)
        var agent = Agent(config: gateConfig(policy: .dangerous), model: model)
        agent.approvalHook = recorder.hook
        agent.approvalState = ApprovalState()
        var messages: [Message] = [.system("delegation fixture")]

        try await agent.run(task: "delegate the write", messages: &messages)

        // Ask 1: the sub-agent's write_file, through the inherited hook.
        let askCount = await recorder.askCount
        #expect(askCount == 1)
        let askedTool = await recorder.askedTools.first
        #expect(askedTool == "write_file")
        // The hook saw a real argument summary (the payload text is in it).
        let summaries = await recorder.askedSummaries
        #expect(summaries.first?.contains("TAMPERED") == true)

        // Denial or approval, the write landed ONLY via consent; the sub's
        // report came back to the parent either way.
        #expect(messages.contains { $0.role == "tool" && $0.content?.contains("SUB-AGENT REPORT") ?? false })
    }

    @Test("a parent's 'always' covers the sub-agent's same tool")
    func parentAlwaysCoversChild() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        // Turn 1: parent is asked (and says always) for its own write_file;
        // turn 2: the sub's write_file must run WITHOUT a second ask.
        let recorder = HookRecorder(script: [.approveAlways, .approveAlways])
        let model = ParentThenChildModel(filePath: sandbox.canary.path)
        var agent = Agent(config: gateConfig(policy: .dangerous), model: model)
        agent.approvalHook = recorder.hook
        agent.approvalState = ApprovalState()
        var messages: [Message] = [.system("delegation fixture")]

        try await agent.run(task: "write, delegate, finish", messages: &messages)

        #expect(await recorder.askCount == 1)  // the child's call was covered
        #expect(messages.contains { $0.role == "tool" && $0.content?.contains("SUB-AGENT REPORT") ?? false })
    }

    @Test("no hook anywhere denies inside the child too (fail-closed)")
    func childInheritsFailClosed() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanup() }
        let model = DelegationGateModel(filePath: sandbox.canary.path)
        var agent = Agent(config: gateConfig(policy: .dangerous), model: model)
        // No hook anywhere. The child's write_file must also be denied.
        var messages: [Message] = [.system("delegation fixture")]
        try await agent.run(task: "delegate without a hook", messages: &messages)

        #expect(sandbox.canaryUnchanged())
    }
}
