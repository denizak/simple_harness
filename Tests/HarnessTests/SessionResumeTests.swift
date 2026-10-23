import Testing
import Foundation
@testable import HarnessCore

/// The --resume wiring: the parser, restore-through-/load-policy, and the
/// fail-closed error path. The precedence policy itself is covered by
/// RuntimeConfigurationTests; these cover what --resume adds on top.
@Suite("--resume startup")
struct SessionResumeStartupTests {

    // MARK: parser (pure)

    @Test("absent flag → .none")
    func parseNone() {
        #expect(SessionResume.parse([]) == .none)
        #expect(SessionResume.parse(["--once", "task", "--model", "m"]) == .none)
        #expect(SessionResume.parse(["--resume-log", "x"]) == .none)  // different flag
    }

    @Test("bare flag → .last; a following flag is never swallowed as a path")
    func parseLast() {
        #expect(SessionResume.parse(["--resume"]) == .last)
        #expect(SessionResume.parse(["--resume", "--once", "keep going"]) == .last)
        #expect(SessionResume.parse(["--resume", "--model", "m"]) == .last)
        #expect(SessionResume.parse(["--resume", "--resume"]) == .last)
    }

    @Test("non-flag token after the flag becomes the path")
    func parsePath() {
        #expect(SessionResume.parse(["--resume", "/tmp/s.json"]) == .path("/tmp/s.json"))
        #expect(SessionResume.parse(["--once", "t", "--resume", "s.json", "--no-streaming"])
                == .path("s.json"))
    }

    // MARK: apply (same helpers as /load)

    /// Build an agent + apply a resume request exactly as Harness startup
    /// does, so the tests exercise the wiring, not a re-implementation.
    private func apply(
        _ resume: SessionResume, launch: Config
    ) throws -> (agent: Agent, messages: [Message]) {
        var agent = Agent(config: launch, model: OpenAICompatClient(config: launch))
        var messages: [Message] = []
        if resume != .none {
            let url: URL?
            if case .path(let p) = resume { url = URL(fileURLWithPath: p) } else { url = nil }
            let session = try Session.load(from: url)
            messages = session.messages
            if let restored = session.restoreModel(activeBaseURL: agent.config.baseURL) {
                agent.selectModel(restored) { OpenAICompatClient(config: $0) }
            }
        } else {
            messages = [.system("sys")]
        }
        return (agent, messages)
    }

    private let launch = Config(provider: "stub", baseURL: "https://launch.test/v1",
                                apiKey: "none", model: "launched-model")

    @Test("endpoint match: conversation restored, model reconfigured")
    func restoreOnMatch() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.json")
        try Session(model: "saved-model", provider: "stub", baseURL: launch.baseURL,
                    messages: [.user("hello from the past")]).save(to: path)

        let (agent, messages) = try apply(.path(path.path), launch: launch)
        #expect(messages.count == 1 && messages[0].role == "user"
                && messages[0].content == "hello from the past")
        #expect(agent.config.model == "saved-model")
        let client = try #require(agent.model as? OpenAICompatClient)
        let (body, _) = try client.requestFor(messages: messages, tools: [], streaming: false)
        #expect(body["model"]?.stringValue == "saved-model")  // requests carry the restored model
    }

    @Test("endpoint mismatch: conversation restored, launch model kept")
    func keepsLaunchModelOnMismatch() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.json")
        try Session(model: "elsewhere-model", provider: "other", baseURL: "https://elsewhere.test/v1",
                    messages: [.user("hello from the past")]).save(to: path)

        let (agent, messages) = try apply(.path(path.path), launch: launch)
        #expect(messages.count == 1 && messages[0].role == "user"
                && messages[0].content == "hello from the past")
        #expect(agent.config.model == "launched-model")
    }

    // MARK: failure policy (fail closed)

    @Test("missing file throws; nothing is written over the default session")
    func missingFileThrowsWithoutClobber() throws {
        #expect(throws: (any Error).self) {
            try apply(.path("/nonexistent/\(UUID().uuidString)/s.json"), launch: launch)
        }
        // The failed startup must not have created/clobbered the autosave.
        let saved = try? Data(contentsOf: Session.defaultPath)
        let session = saved.flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
        if let session { #expect(!session.messages.isEmpty) }  // pre-existing file intact
    }
}
