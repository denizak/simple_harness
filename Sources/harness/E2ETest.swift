import Foundation

// ---------------------------------------------------------------------------
// E2ETest.swift — end-to-end tests, in two layers.
//
// A harness has three testable layers, and they fail differently:
//   1. tool layer        → --selftest (no API; already covered there)
//   2. THE LOOP          → here, with a STUB MODEL (offline, deterministic)
//   3. provider plumbing → here, with a LIVE round-trip (--e2e)
//
// Why a stub model? The loop's contract is: given a scripted reply, the agent
// must parse tool_calls, execute the REAL tools, feed results back as tool
// messages, and stop when the model replies in plain text. That logic is 90%
// of the harness and none of it needs a network — so we drive it with a
// scripted `ChatModel`. Fast, deterministic, CI-safe. This is the standard
// pattern for testing agent loops (same reason pi can replay sessions).
//
// The live round-trip then answers the only question the stub can't: does
// our request actually satisfy the real server?
//
// Run with: harness --e2e
// ---------------------------------------------------------------------------

/// A scripted model: each task call returns the next move; compaction
/// summarizer calls (detected by their system prompt) get a canned summary.
/// An actor because the agent awaits it from the loop while the test later
/// reads its counters.
actor StubModel: ChatModel {
    private let filePath: String
    private(set) var taskCalls = 0
    private(set) var summarizerCalls = 0

    init(filePath: String) { self.filePath = filePath }

    func complete(_ messages: [Message], tools: [ToolSpec]) async throws -> AssistantTurn {
        // Compaction's summarizer call is recognizable by its system prompt.
        if messages.first?.content?.contains("compress a coding-agent conversation") == true {
            summarizerCalls += 1
            return AssistantTurn(
                text: "- stub: earlier turns summarized", toolCalls: [], finishReason: "stop", usage: nil
            )
        }
        taskCalls += 1
        switch taskCalls {
        case 1:   // big output → pushes the transcript past the compaction threshold
            return turn("bash", arguments: #"{"command": "yes 0123456789 | head -400"}"#)
        case 2:
            return turn("write_file", arguments: try argumentsJSON([
                "path": .string(filePath), "content": .string("e2e stub content"),
            ]))
        case 3:
            return turn("read_file", arguments: try argumentsJSON(["path": .string(filePath)]))
        default:
            return AssistantTurn(text: "e2e-stub done", toolCalls: [], finishReason: "stop", usage: nil)
        }
    }

    private func turn(_ name: String, arguments: String) -> AssistantTurn {
        AssistantTurn(
            text: "",
            toolCalls: [ToolCall(id: "call_\(taskCalls)", type: "function",
                                 function: .init(name: name, arguments: arguments))],
            finishReason: "tool_calls",
            usage: nil
        )
    }

    private func argumentsJSON(_ dict: [String: JSONValue]) throws -> String {
        String(decoding: try JSONEncoder().encode(dict), as: UTF8.self)
    }
}

/// Script for the DELEGATION test: the parent asks for spawn_agent, the
/// sub-agent (which shares this stub) writes the file and reports, then the
/// parent finishes. Call order is deterministic because the loop is serial:
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
            return turn("write_file", arguments: try argumentsJSON([
                "path": .string(filePath), "content": .string("spawned!"),
            ]))
        case 3:
            return AssistantTurn(text: "sub report: done", toolCalls: [], finishReason: "stop", usage: nil)
        default:
            return AssistantTurn(text: "parent done", toolCalls: [], finishReason: "stop", usage: nil)
        }
    }

    private func turn(_ name: String, arguments: String) -> AssistantTurn {
        AssistantTurn(
            text: "",
            toolCalls: [ToolCall(id: "call_\(taskCalls)", type: "function",
                                 function: .init(name: name, arguments: arguments))],
            finishReason: "tool_calls",
            usage: nil
        )
    }

    private func argumentsJSON(_ dict: [String: JSONValue]) throws -> String {
        String(decoding: try JSONEncoder().encode(dict), as: UTF8.self)
    }
}

enum E2ETest {
    static func run() async {
        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("  ✓ \(name)")
            } else {
                failures += 1
                print(AgentUI.errorText("  ✗ \(name) \(detail)"))
            }
        }

        print("e2e [offline]: the loop with a stub model (compaction forced)")
        failures += await offlineLoopWithCompaction()

        print("e2e [offline]: sub-agent delegation (stub model)")
        failures += await offlineSpawnTest()

        print("e2e [live]: round-trip against the configured provider")
        failures += await liveRoundTrip()

        print(failures == 0 ? "e2e: all passed" : AgentUI.errorText("e2e: \(failures) failure(s)"))
        exit(failures == 0 ? 0 : 1)
    }

    /// One scripted task through the REAL agent + REAL tools in a temp dir:
    /// bash (big output) → write_file → read_file → done. Compaction is forced
    /// with a tiny threshold so the summarizer call happens mid-task.
    private static func offlineLoopWithCompaction() async -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("  ✓ \(name)")
            } else {
                failures += 1
                print(AgentUI.errorText("  ✗ \(name) \(detail)"))
            }
        }

        let dir = NSTemporaryDirectory() + "harness-e2e-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filePath = dir + "probe.txt"

        var config = Config(provider: "stub", baseURL: "stub://stub", apiKey: "none", model: "stub-1")
        config.compactAboveBytes = 3000  // force compaction after the big bash output
        config.compactKeepTail = 4
        let stub = StubModel(filePath: filePath)
        var agent = Agent(config: config, model: stub)
        var messages: [Message] = [.system(systemPrompt(for: config))]

        do {
            try await agent.run(task: "write a probe file and read it back", messages: &messages)
        } catch {
            check("loop completes", false, "\(error)")
            return failures
        }

        check("stub drove 4 task turns", await stub.taskCalls == 4, "\(await stub.taskCalls)")
        check("summarizer was called once", await stub.summarizerCalls == 1, "\(await stub.summarizerCalls)")
        check("history was compacted",
              messages.count > 1 && (messages[1].content?.hasPrefix("[Auto-compacted]") ?? false),
              messages.dropFirst(2).first?.role ?? "missing")
        check("real tool ran (write_file on disk)",
              (try? String(contentsOfFile: filePath, encoding: .utf8)) == "e2e stub content", "")
        check("tool result fed back",
              messages.contains { $0.role == "tool" && $0.content?.contains("e2e stub content") ?? false }, "")
        check("loop ended on plain text", messages.last?.role == "assistant" && messages.last?.toolCalls == nil, "")
        return failures
    }

    /// Delegation through the REAL loop: the parent's stub asks for spawn_agent,
    /// the SUB-agent (sharing the same stub) writes the file and reports, then
    /// the parent finishes. Proves: ToolContext reaches the tool, the sub-agent
    /// runs its own conversation with the parent's model client, and the
    /// parent's loop continues afterward with the report in hand.
    private static func offlineSpawnTest() async -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("  ✓ \(name)")
            } else {
                failures += 1
                print(AgentUI.errorText("  ✗ \(name) \(detail)"))
            }
        }

        let dir = NSTemporaryDirectory() + "harness-e2e-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let filePath = dir + "sub.txt"

        var config = Config(provider: "stub", baseURL: "stub://stub", apiKey: "none", model: "stub-1")
        config.compactAboveBytes = 0  // disable compaction — keep the script simple
        let stub = SpawnStubModel(filePath: filePath)
        var agent = Agent(config: config, model: stub, depth: 0)
        var messages: [Message] = [.system(systemPrompt(for: config))]

        do {
            try await agent.run(task: "delegate the file task", messages: &messages)
        } catch {
            check("parent loop completes", false, "\(error)")
            return failures
        }

        check("stub drove 4 turns (parent + sub)", await stub.taskCalls == 4, "\(await stub.taskCalls)")
        check("sub-agent's write_file landed on disk",
              (try? String(contentsOfFile: filePath, encoding: .utf8)) == "spawned!", "")
        check("sub report reached the parent as a tool result",
              messages.contains { $0.role == "tool" && $0.content?.contains("SUB-AGENT REPORT") ?? false }, "")
        check("parent loop ended on plain text",
              messages.last?.role == "assistant" && messages.last?.toolCalls == nil, "")
        return failures
    }

    /// A real request against the configured provider. Deliberately tiny:
    /// one bash echo, expect the output somewhere in the conversation.
    private static func liveRoundTrip() async -> Int {
        var failures = 0
        let config = Config.resolve(arguments: [])
        var agent = Agent(config: config, model: OpenAICompatClient(config: config))
        var messages: [Message] = [.system(systemPrompt(for: config))]

        print(AgentUI.dim("  [\(config.provider) / \(config.model) @ \(config.baseURL)]"))
        do {
            try await agent.run(task: "Use bash to run exactly: echo e2e-live-ok", messages: &messages)
            let sawIt = messages.contains { $0.content?.contains("e2e-live-ok") ?? false }
            if sawIt {
                print("  ✓ live round-trip (tool ran, output reached the conversation)")
            } else {
                failures += 1
                print(AgentUI.errorText("  ✗ live round-trip: 'e2e-live-ok' never appeared"))
            }
        } catch {
            failures += 1
            print(AgentUI.errorText("  ✗ live round-trip failed: \(error)"))
            print(AgentUI.warn(
                "    is a provider reachable? set OLLAMA_API_KEY / OPENAI_API_KEY / ZAI_API_KEY or run a local server"
            ))
        }
        return failures
    }
}