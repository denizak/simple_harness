import Foundation

// ---------------------------------------------------------------------------
// Compaction.swift — keeping the context bounded.
//
// Every harness has this problem: the transcript only ever grows, but every
// model call re-sends ALL of it. Left alone, a long session gets slower,
// pricier, and eventually overflows the model's context window.
//
// pi's answer (and ours): when the transcript grows past a threshold, ask the
// model to summarize the OLDER portion into a single message, keeping only a
// recent tail verbatim:
//
//     before:  [system, u1, a1→tools, t, a2, u2, a3→tools, t, a4 ...]
//     after:   [system, SUMMARY, u2, a3→tools, t, a4 ...]
//
// Two rules make this safe:
//   1. The tail must not START on a tool result — a tool result whose
//      requesting tool_call was summarized away is invalid (the API requires
//      every tool_call to be answered exactly once, in order). Starting the
//      tail on a user or assistant message is always safe.
//   2. Compaction failures are swallowed: a failed summary call never breaks
//      the task. The loop just keeps running on the larger history.
//
// Size is estimated in UTF-8 bytes (a cheap token proxy — roughly 4 bytes ≈
// 1 token of English text). Real harnesses read the API's usage.promptTokens
// instead; the byte estimate keeps this deterministic and testable.
// ---------------------------------------------------------------------------

enum Compaction {
    // ---- Pure helpers (unit-testable without any API call) ----------------

    /// Byte-size estimate of the conversation.
    static func size(of messages: [Message]) -> Int {
        messages.reduce(0) { total, message in
            total + (message.content?.utf8.count ?? 0) + (message.toolCalls?.count ?? 0) * 64
        }
    }

    /// True when a message is a safe place to START the kept tail.
    /// The only forbidden start is a tool result: if the tail began there,
    /// the tool_call that requested it would be summarized away and the API
    /// would reject the orphaned result. User and assistant messages (with
    /// or without tool_calls) are always safe — a tail starting at an
    /// assistant tool_call keeps its results, which follow it in history.
    static func isCleanBoundary(_ message: Message) -> Bool {
        message.role != "tool"
    }

    /// Index where the kept tail may start, walking BACKWARD from the ideal
    /// cut point until a clean boundary is found (so the tail is at least
    /// `keepTail` messages whenever any boundary exists). Returns nil when
    /// even message 1 isn't a boundary — then we can't compact at all.
    static func tailStart(in messages: [Message], keepTail: Int) -> Int? {
        var index = max(1, messages.count - max(2, keepTail))
        while index > 1 {
            if isCleanBoundary(messages[index]) { return index }
            index -= 1
        }
        return nil
    }

    /// Render the older portion as plain text for the summarizer call.
    /// Each message is capped so one huge tool result can't dominate.
    static func transcript(_ messages: [Message], perMessageCap: Int = 1500) -> String {
        messages.map { message in
            var text = message.content ?? ""
            if text.count > perMessageCap {
                text = String(text.prefix(perMessageCap)) + " …[cut]"
            }
            if message.role == "tool", let callId = message.toolCallId {
                return "[tool result for \(callId)] \(text)"
            }
            var line = "[\(message.role)] \(text)"
            if let calls = message.toolCalls, !calls.isEmpty {
                let rendered = calls
                    .map { "\($0.function.name)(\($0.function.arguments.prefix(200)))" }
                    .joined(separator: "; ")
                line += " (asks to run: \(rendered))"
            }
            return line
        }.joined(separator: "\n")
    }

    // ---- The trigger -------------------------------------------------------
    private static let summarizerSystem = """
    You compress a coding-agent conversation into a terse handoff note.
    Preserve: the user's goals, decisions made, file paths and code facts,
    commands run and their outcomes, errors and their fixes, and unfinished work.
    Output a compact bullet list (max ~200 words). No preamble.
    """

    /// No-op unless the transcript exceeds `config.compactAboveBytes`. When it
    /// does, summarize everything before the kept tail and splice the history
    /// into [system, summary, tail…]. Runs before every model call; for
    /// short sessions it is a cheap size check.
    /// Upper bound on the summary message we accept (~200 words + prefix).
    private static let maxSummaryBytes = 1_300
    static func compactIfNeeded(
        _ messages: inout [Message],
        config: Config,
        model: ChatModel
    ) async {
        let total = size(of: messages)
        guard total > config.compactAboveBytes else { return }
        guard let start = tailStart(in: messages, keepTail: config.compactKeepTail),
              start > 1 else { return }

        let older = Array(messages[1..<start])
        // Pre-flight: is the older portion substantial enough to be worth a
        // summarizer call at all? A tiny older block can never clear the
        // gain bar below (the summary message costs ~100 bytes plus text) —
        // the e2e test caught the first draft wasting a call on exactly that.
        let minGain = max(512, total / 4)
        guard size(of: older) > minGain + maxSummaryBytes else { return }

        let turn = try? await model.complete(
            [.system(summarizerSystem), .user(transcript(older))],
            tools: []  // the summarizer must not run tools
        )
        guard let summary = turn?.text, !summary.isEmpty else {
            return  // rule 2: best-effort; keep the full history on failure
        }

        let summaryMessage = Message.user(
            "[Auto-compacted] Summary of the earlier conversation:\n\(summary)"
        )
        // A compaction that doesn't meaningfully shrink the transcript is not
        // worth its summarizer call — and can even GROW the history (the
        // summary text itself becomes part of the transcript; the e2e test
        // caught exactly that: 5199 → 5250 bytes for one summarized message).
        // Only splice when the gain clears this bar; otherwise wait for more
        // history to accumulate.
        let candidate = [messages[0], summaryMessage] + Array(messages[start...])
        let newSize = size(of: candidate)
        guard newSize < total - minGain else { return }

        messages = candidate
        print(AgentUI.dim(
            "🧹 compacted \(older.count) older messages (\(total) → \(newSize) bytes)"
        ))
    }
}