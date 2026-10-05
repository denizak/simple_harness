import Foundation
import Testing
@testable import HarnessCore

// JSONL session log — README "Where to go next" #3.
//
// Design under test: an append-only event log ({append | replace} events, one
// JSON object per line, fsync after each line). Compaction logs a `replace`,
// so the loader replays a clean state instead of tracking a watermark.
// System prompts are not logged; restore only accepts .user seeds.

private func tempLogPath(_ name: String) -> String {
    let dir = NSTemporaryDirectory() + "jsonl-tests-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/" + name + ".jsonl"
}

@Suite("JSONL session log")
struct JSONLSessionTests {

    @Test("append -> load round-trips user, assistant, tool messages")
    func roundTrip() throws {
        let path = tempLogPath("roundtrip")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let log = try JSONLSessionLog(path: path)
        log.append(message: .user("list files"))
        log.append(message: Message(
            role: "assistant", content: "listing",
            toolCalls: [ToolCall(id: "c1", function: .init(name: "bash", arguments: "{}"))]))
        log.append(message: .tool(result: "a.txt", for: ToolCall(id: "c1", function: .init(name: "bash", arguments: "{}"))))

        let restored = try JSONLSessionLog.load(path: path)
        #expect(restored.count == 3)
        #expect(restored[0].role == "user" && restored[0].content == "list files")
        #expect(restored[1].role == "assistant" && restored[1].toolCalls?.count == 1)
        #expect(restored[2].role == "tool" && restored[2].toolCallId == "c1")
        #expect(restored[2].content == "a.txt")
    }

    @Test("compaction logs a replace event; later appends survive it")
    func replaceEvent() throws {
        let path = tempLogPath("replace")
        defer { try? FileManager.default.removeItem(atPath: path) }

        var logA = try JSONLSessionLog(path: path)
        let logB = try JSONLSessionLog(path: path)
        logA.append(message: .user("old question"))
        logB.append(message: Message(role: "assistant", content: "old answer", toolCalls: nil))
        logA.replace(with: [.user("[Auto-compacted] Summary of the earlier conversation:\nold")])
        logB.append(message: .user("next"))

        let restored = try JSONLSessionLog.load(path: path)
        #expect(restored.count == 2)
        #expect(restored[0].content?.hasPrefix("[Auto-compacted]") == true)
        #expect(restored[1].content == "next")
    }

    @Test("load skips corrupt lines instead of failing")
    func corruptLine() throws {
        let path = tempLogPath("corrupt")
        defer { try? FileManager.default.removeItem(atPath: path) }

        FileManager.default.createFile(atPath: path, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        handle.write(try JSONEncoder().encode(SessionEvent(message: .user("good"))))
        handle.write(Data("\n".utf8))
        handle.write(Data("{broken".utf8))
        handle.write(Data("\n".utf8))
        handle.write(try JSONEncoder().encode(SessionEvent(message: .user("good2"))))
        handle.write(Data("\n".utf8))
        try handle.close()

        let restored = try JSONLSessionLog.load(path: path)
        #expect(restored.map(\.content) == ["good", "good2"])
    }

    @Test("load on a missing path returns empty")
    func missingFile() throws {
        #expect(try JSONLSessionLog.load(path: "/nonexistent/\(UUID()).jsonl").isEmpty)
    }

    @Test("default is OFF (nil log); concurrent appends all land")
    func defaultOffAndConcurrency() async throws {
        let config = Config(provider: "stub", baseURL: "stub://stub", apiKey: "none", model: "stub")
        #expect(config.sessionLog == nil, "logging must be opt-in, not ambient")

        let path = tempLogPath("concurrent")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let log = try JSONLSessionLog(path: path)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { log.append(message: .user("msg \(i)")) }
            }
        }
        let restored = try JSONLSessionLog.load(path: path)
        #expect(restored.count == 20)
        #expect(restored.allSatisfy { $0.content?.hasPrefix("msg ") == true })
    }

    @Test("run() appends user/assistant turns; compaction writes replace")
    func runIntegration() async throws {
        let path = tempLogPath("run")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let model = StubModel(filePath: "/tmp/unused-\(UUID()).txt")
        var config = Config(provider: "stub", baseURL: "stub://stub", apiKey: "none", model: "stub")
        config.sessionLog = path
        config.compactAboveBytes = 3000
        config.compactKeepTail = 4
        config.streaming = false
        var agent = Agent(config: config, model: model)
        var messages: [Message] = [.system("fixture system")]
        try await agent.run(task: "start the scripted task", messages: &messages)

        // The raw event stream: the user turn was appended (first thing the
        // run does), and compaction journaled exactly one replace.
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let events = try raw.split(separator: "\n").map {
            try JSONDecoder().decode(SessionEvent.self, from: Data($0.utf8))
        }
        #expect(events.first?.message?.content == "start the scripted task")
        #expect(events.contains { $0.kind == .replace })

        // The replay: compaction replaced the early turns with a summary, so
        // the restored history keeps the compacted block, the kept tail (tool
        // results) and the final assistant answer.
        let restored = try JSONLSessionLog.load(path: path)
        #expect(restored.contains { $0.content?.hasPrefix("[Auto-compacted]") == true })
        #expect(restored.contains { $0.role == "tool" })
        #expect(restored.last?.content == "stub done")
    }
}
