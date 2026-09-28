import Testing
import Foundation
@testable import HarnessCore

private actor FailAfterWriteModel: ChatModel {
    private let filePath: String
    private var callCount = 0

    init(filePath: String) { self.filePath = filePath }

    func complete(_ messages: [Message], tools: [ToolSpec]) async throws -> AssistantTurn {
        callCount += 1
        if callCount == 1 {
            let args = String(decoding: try JSONEncoder().encode(
                ["path": .string(filePath), "content": .string("written-once")] as [String: JSONValue]), as: UTF8.self)
            return AssistantTurn(text: "", toolCalls: [ToolCall(id: "write-once", function: .init(name: "write_file", arguments: args))], finishReason: "tool_calls", usage: nil)
        }
        if callCount == 2 { throw LLMError(status: 503, body: "scripted temporary failure") }
        return AssistantTurn(text: "recovered", toolCalls: [], finishReason: "stop", usage: nil)
    }

    func observedCalls() -> Int { callCount }
}

@Suite("Explicit task recovery")
struct RecoveryTests {
    @Test("continuation keeps one prompt and does not repeat successful side effects")
    func resumesAfterTool() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("result.txt").path
        var config = Config(provider: "stub", baseURL: "stub://stub", apiKey: "none", model: "stub")
        config.streaming = false
        let model = FailAfterWriteModel(filePath: path)
        var agent = Agent(config: config, model: model)
        var messages: [Message] = [.system("recovery fixture")]

        do {
            try await agent.run(task: "write once", messages: &messages)
            Issue.record("expected scripted model failure")
        } catch { #expect(String(describing: error).contains("scripted temporary failure")) }

        #expect(messages.filter { $0.role == "user" && $0.content == "write once" }.count == 1)
        #expect(messages.filter { $0.role == "tool" && $0.toolCallId == "write-once" }.count == 1)
        let fileContents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(fileContents == "written-once")

        try await agent.continueRun(messages: &messages)
        #expect(messages.filter { $0.role == "user" && $0.content == "write once" }.count == 1)
        #expect(messages.filter { $0.role == "tool" && $0.toolCallId == "write-once" }.count == 1)
        #expect(messages.last?.content == "recovered")
        #expect(await model.observedCalls() == 3)
    }

    @Test("retry gets a fresh turn budget after a turn-cap failure")
    func resumesAfterTurnCap() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("result.txt").path
        var config = Config(provider: "stub", baseURL: "stub://stub", apiKey: "none", model: "stub", maxTurns: 1)
        config.streaming = false
        let model = FailAfterWriteModel(filePath: path)
        var agent = Agent(config: config, model: model)
        var messages: [Message] = [.system("turn-cap fixture")]

        do {
            try await agent.run(task: "write once", messages: &messages)
            Issue.record("expected turn-cap error")
        } catch { #expect(String(describing: error).contains("turn cap")) }
        #expect(messages.filter { $0.role == "tool" && $0.toolCallId == "write-once" }.count == 1)

        // The second scripted call throws by design. Replace the exhausted
        // client with a completing one while keeping transcript/config intact.
        let completion = CompletionModel()
        agent.reconfigure({ _ in }, makeModel: { _ in completion })
        try await agent.continueRun(messages: &messages)
        #expect(messages.filter { $0.role == "user" && $0.content == "write once" }.count == 1)
        #expect(messages.filter { $0.role == "tool" && $0.toolCallId == "write-once" }.count == 1)
        #expect(messages.last?.content == "resumed")
    }
}

private struct CompletionModel: ChatModel {
    func complete(_ messages: [Message], tools: [ToolSpec]) async throws -> AssistantTurn {
        AssistantTurn(text: "resumed", toolCalls: [], finishReason: "stop", usage: nil)
    }
}
