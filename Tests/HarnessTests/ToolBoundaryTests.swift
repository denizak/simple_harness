import Testing
import Foundation
@testable import HarnessCore

private func boundaryContext(_ cwd: String, depth: Int = 0) -> ToolContext {
    let config = Config(provider: "stub", baseURL: "stub://stub", apiKey: "none", model: "stub", maxAgentDepth: 2)
    return ToolContext(config: config, model: OpenAICompatClient(config: config), cwd: cwd, depth: depth)
}

@Suite("Tool boundaries")
struct ToolBoundaryTests {
    @Test("spawn advertisement matches root-depth policy")
    func spawnDepths() async throws {
        for (depth, permitted) in [(0, true), (1, true), (2, false)] {
            let context = boundaryContext(".", depth: depth)
            let agent = Agent(config: context.config, model: context.model, depth: depth)
            #expect(agent.availableTools.contains { $0.name == "spawn_agent" } == permitted)
            if !permitted {
                let output = try await Tools.spawnAgent.run(["task": .string("x")], context)
                #expect(output.contains("depth limit"))
            }
        }
        let disabled = Config(provider: "x", baseURL: "x", apiKey: "none", model: "x", maxAgentDepth: 0)
        let agent = Agent(config: disabled, model: OpenAICompatClient(config: disabled))
        #expect(!agent.availableTools.contains { $0.name == "spawn_agent" })
    }

    @Test("file tools resolve relative paths against context cwd")
    func relativePaths() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = boundaryContext(dir.path)
        let write = try await Tools.writeFile.run(["path": .string("nested/a.txt"), "content": .string("alpha beta")], context)
        #expect(write.contains("wrote"))
        #expect((try String(contentsOf: dir.appendingPathComponent("nested/a.txt"), encoding: .utf8)) == "alpha beta")
        let read = try await Tools.readFile.run(["path": .string("nested/a.txt")], context)
        #expect(read.contains("alpha beta"))
        let edited = try await Tools.editFile.run(["path": .string("nested/a.txt"), "old_text": .string("beta"), "new_text": .string("BETA")], context)
        #expect(edited.contains("edited"))
        let grep = try await Tools.grep.run(["pattern": .string("BETA"), "path": .string("nested")], context)
        #expect(grep.contains("a.txt:1"))
    }

    @Test("invalid limits and empty edit needles fail without modifying files")
    func invalidArguments() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("safe.txt")
        try "unchanged".write(to: file, atomically: true, encoding: .utf8)
        let context = boundaryContext(dir.path)
        let read = try await Tools.readFile.run(["path": .string("safe.txt"), "limit": .number(-2)], context)
        #expect(read.contains("limit"))
        let grep = try await Tools.grep.run(["pattern": .string("x"), "max_matches": .number(0)], context)
        #expect(grep.contains("max_matches"))
        let edit = try await Tools.editFile.run(["path": .string("safe.txt"), "old_text": .string(""), "new_text": .string("oops")], context)
        #expect(edit.contains("old_text"))
        let timeout = try await Tools.bash.run(["command": .string("echo no"), "timeout_seconds": .number(0)], context)
        #expect(timeout.contains("timeout_seconds"))
        let unchanged = try String(contentsOf: file, encoding: .utf8)
        #expect(unchanged == "unchanged")
    }
}

private actor HiddenSpawnModel: ChatModel {
    private var calls = 0
    func complete(_ messages: [Message], tools: [ToolSpec]) async throws -> AssistantTurn {
        calls += 1
        if calls == 1 {
            #expect(!tools.contains { $0.name == "spawn_agent" })
            return AssistantTurn(text: "", toolCalls: [ToolCall(id: "hidden-call", function: .init(name: "spawn_agent", arguments: #"{"task":"must not run"}"#))], finishReason: "tool_calls", usage: nil)
        }
        return AssistantTurn(text: "done", toolCalls: [], finishReason: "stop", usage: nil)
    }
}

@Suite("Unavailable tool dispatch")
struct UnavailableToolTests {
    @Test("hidden spawn request is reported, not executed")
    func hiddenTool() async throws {
        var config = Config(provider: "stub", baseURL: "stub://stub", apiKey: "none", model: "stub", maxAgentDepth: 2)
        config.streaming = false
        let model = HiddenSpawnModel()
        var agent = Agent(config: config, model: model, depth: 2)
        var messages: [Message] = [.system("fixture")]
        try await agent.run(task: "test", messages: &messages)
        let result = try #require(messages.first { $0.role == "tool" })
        #expect(result.toolCallId == "hidden-call")
        #expect(result.content?.contains("unavailable") == true)
        #expect(!messages.contains { $0.content?.contains("SUB-AGENT REPORT") == true })
    }
}
