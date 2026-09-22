import Foundation

// ---------------------------------------------------------------------------
// Session.swift — persistence.
//
// An agent session is just the message history. Because Message mirrors the
// wire format, the saved file is literally a replayable API request body:
//   { "model": "...", "provider": "...", "messages": [...] }
//
// pi goes further (sessions as JSONL append-log for crash safety); that's
// listed in the README as an extension exercise.
// ---------------------------------------------------------------------------

struct Session: Codable, Sendable {
    var model: String
    var provider: String
    /// Endpoint the session ran on. Optional so older session files (before
    /// this field existed) still decode — /load uses it to refuse silently
    /// mixing a session's model with a different endpoint's configuration.
    var baseURL: String?
    var messages: [Message]

    static var defaultPath: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".harness")
            .appendingPathComponent("session.json")
    }

    func save(to url: URL? = nil) throws {
        let target = url ?? Self.defaultPath
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: target, options: .atomic)
    }

    static func load(from url: URL? = nil) throws -> Session {
        let target = url ?? Self.defaultPath
        let data = try Data(contentsOf: target)
        return try JSONDecoder().decode(Session.self, from: data)
    }
}

extension Agent {
    /// Persist the conversation alongside its model identity so /load can
    /// restore the exact configuration the session ran with.
    func saveSession(messages: [Message], to url: URL? = nil) throws {
        try Session(
            model: config.model, provider: config.provider,
            baseURL: config.baseURL, messages: messages
        ).save(to: url)
    }
}