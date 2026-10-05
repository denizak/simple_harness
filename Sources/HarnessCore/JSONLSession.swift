import Foundation

// T6.5 — JSONL session log: an append-only, crash-safe transcript on disk.
//
// The previous session format was a single JSON blob written only at /save or
// REPL exit; a crash mid-task lost everything. JSONL fixes the durability half:
// one JSON object per line, fsync'd after every write, appended in real time as
// Agent.run() progresses. The completeness half stays with /save (/load, which
// also carries model/endpoint state that a transcript cannot.
//
// Event stream, not a mirror: the log stores {append | replace} events. Appends
// come from every turn; a compaction (which rewrites the in-memory history
// wholesale) emits a `replace` that the loader replays as "history is now
// exactly this". That keeps the log honest without anyone tracking offsets.
//
// Concurrency: writes go through a serial internal queue, and the file is
// opened with O_APPEND so the *kernel* re-seeks to the (new) end before every
// write — parent and sub-agents may share one log (Config.sessionLog travels
// with subConfig), and a handle opened before another writer appended still
// lands at the true end. Each write() with O_APPEND is atomic; no cross-
// process locking needed.

/// One line of the JSONL log: either "the history grew by this message" or
/// "the history is now exactly these messages" (post-compaction).
public struct SessionEvent: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case append, replace }
    public let kind: Kind
    public let message: Message?   // append
    public let messages: [Message]?  // replace

    public init(message: Message) {
        self.kind = .append
        self.message = message
        self.messages = nil
    }

    public init(messages: [Message]) {
        self.kind = .replace
        self.message = nil
        self.messages = messages
    }
}

/// Append-only session log. Cheap to hold: a raw fd + a serial queue.
/// All methods tolerate a nil fd (open failure) by turning into no-ops —
/// losing a transcript must never take down a run.
public final class JSONLSessionLog: @unchecked Sendable {
    private let fd: Int32?
    private let queue = DispatchQueue(label: "harness.jsonl-session")

    public init(path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        // O_WRONLY | O_APPEND: the kernel re-anchors every write() to the
        // current end of file, so a writer that opened the file EARLIER never
        // clobbers lines appended since — exactly what the replace-event test
        // caught with FileHandle.seekToEndOfFile (offset fixed at open time).
        fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    }

    deinit {
        if let fd { close(fd) }
    }

    /// Append one message event. Thread-safe; never throws.
    public func append(message: Message) {
        write(SessionEvent(message: message))
    }

    /// The history was rewritten (compaction). Everything before this point in
    /// the file is superseded; loaders replay `messages` as the whole state.
    public func replace(with messages: [Message]) {
        write(SessionEvent(messages: messages))
    }

    private func write(_ event: SessionEvent) {
        guard let fd else { return }
        queue.sync {
            guard let line = try? JSONEncoder().encode(event) else { return }
            var data = line
            data.append(0x0A)  // one event per line
            data.withUnsafeBytes { buffer in
                _ = Darwin.write(fd, buffer.baseAddress, buffer.count)
            }
            fsync(fd)  // survive a crash between turns
        }
    }

    // ------------------------------------------------------------------
    // Loading
    // ------------------------------------------------------------------

    /// Replay a log into an in-memory history. Missing file → empty. Corrupt
    /// lines are skipped (a torn tail from a crash is normal, not fatal).
    /// System prompts are not stored in the log; the caller re-adds theirs.
    public static func load(path: String) throws -> [Message] {
        guard FileManager.default.fileExists(atPath: path),
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        var history: [Message] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(SessionEvent.self, from: data) else {
                continue
            }
            switch event.kind {
            case .append:
                if let m = event.message { history.append(m) }
            case .replace:
                history = event.messages ?? []
            }
        }
        return history
    }
}
