import Testing
import Foundation
@testable import HarnessCore

@Suite("Runtime model configuration")
struct RuntimeConfigurationTests {
    @Test("model selection refreshes the client request and saved metadata")
    func selectionRefreshesClient() throws {
        let config = Config(provider: "stub", baseURL: "https://example.test/v1", apiKey: "none", model: "model-a")
        let agentModel = OpenAICompatClient(config: config)
        var agent = Agent(config: config, model: agentModel)
        agent.selectModel("model-b") { OpenAICompatClient(config: $0) }

        #expect(agent.config.model == "model-b")
        let client = try #require(agent.model as? OpenAICompatClient)
        let (body, _) = try client.requestFor(messages: [.user("hello")], tools: [], streaming: false)
        #expect(body["model"]?.stringValue == "model-b")

        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let savedPath = directory.appendingPathComponent("session.json")
        try agent.saveSession(messages: [.user("hello")], to: savedPath)
        let loaded = try Session.load(from: savedPath)
        #expect(loaded.model == "model-b")
    }

    @Test("session endpoint restore keeps active endpoint")
    func endpointRestore() {
        let config = Config(provider: "active", baseURL: "https://active.test/v1", apiKey: "active-key", model: "active-model")
        var agent = Agent(config: config, model: OpenAICompatClient(config: config))
        let session = Session(model: "restored-model", provider: "old", baseURL: config.baseURL,
                              messages: [.user("task")])
        if let restored = session.restoreModel(activeBaseURL: config.baseURL) {
            agent.selectModel(restored) { OpenAICompatClient(config: $0) }
        }
        #expect(agent.config.model == "restored-model")
        #expect(agent.config.baseURL == "https://active.test/v1")
        #expect(agent.config.apiKey == "active-key")
        let client = agent.model as? OpenAICompatClient
        #expect(client?.config.model == "restored-model")

        let mismatch = Session(model: "other", provider: "other", baseURL: "https://other.test/v1", messages: [])
        if let restored = mismatch.restoreModel(activeBaseURL: agent.config.baseURL) {
            agent.selectModel(restored) { OpenAICompatClient(config: $0) }
        }
        #expect(agent.config.model == "restored-model")
        #expect((agent.model as? OpenAICompatClient)?.config.baseURL == "https://active.test/v1")
    }
}
