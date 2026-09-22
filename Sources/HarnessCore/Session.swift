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

public struct Session: Codable, Sendable {
    public var model: String
    public var provider: String
    /// Endpoint the session ran on. Optional so older session files (before
    /// this field existed) still decode — /load uses it to refuse silently
    /// mixing a session's model with a different endpoint's configuration.
    public var baseURL: String?
    public var messages: [Message]

    /// baseURL defaults to nil so older session files (without the field)
    /// decode unchanged.
    public init(model: String, provider: String, baseURL: String? = nil,
                messages: [Message]) {
        self.model = model
        self.provider = provider
        self.baseURL = baseURL
        self.messages = messages
    }

    public static var defaultPath: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".harness")
            .appendingPathComponent("session.json")
    }

    public func save(to url: URL? = nil) throws {
        let target = url ?? Self.defaultPath
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: target, options: .atomic)
    }

    public static func load(from url: URL? = nil) throws -> Session {
        let target = url ?? Self.defaultPath
        let data = try Data(contentsOf: target)
        return try JSONDecoder().decode(Session.self, from: data)
    }
}

public extension Agent {
    /// Persist the conversation alongside its model identity so /load can
    /// restore the exact configuration the session ran with.
    public func saveSession(messages: [Message], to url: URL? = nil) throws {
        try Session(
            model: config.model, provider: config.provider,
            baseURL: config.baseURL, messages: messages
        ).save(to: url)
    }
}

extension Session {
    /// Precedence policy for /load: a session records a PAST run — it must
    /// not silently override the provider/model the harness was launched
    /// with. Returns the session's model ONLY when the session ran on the
    /// same endpoint; nil means "keep the active configuration". Old session
    /// files without an endpoint record restore the model (original behavior).
    public func restoreModel(activeBaseURL: String) -> String? {
        guard let sessionURL = baseURL else { return model }
        return sessionURL == activeBaseURL ? model : nil
    }
}
