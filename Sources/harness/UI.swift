import Foundation
#if canImport(Glibc)
import Glibc  // fflush on Linux
#endif

// ---------------------------------------------------------------------------
// UI.swift — terminal rendering.
//
// Watching tool calls stream past is half the value of a harness: you can see
// the loop think. These helpers add ANSI color and truncation. Keep this dumb
// on purpose — a real harness (pi) renders to a full TUI, but the debugging
// value here comes from raw, greppable output.
// ---------------------------------------------------------------------------

enum AgentUI {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let red = "\u{1B}[31m"
    static let green = "\u{1B}[32m"
    static let yellow = "\u{1B}[33m"
    static let blue = "\u{1B}[34m"
    static let magenta = "\u{1B}[35m"
    static let cyan = "\u{1B}[36m"

    static func dim(_ text: String) -> String { "\(Self.dim)\(text)\(reset)" }
    static func warn(_ text: String) -> String { "\(Self.yellow)\(text)\(reset)" }
    static func errorText(_ text: String) -> String { "\(Self.red)\(text)\(reset)" }
    static func assistant(_ text: String) -> String { "\(Self.green)\(text)\(reset)" }

    /// Streaming fragment: green, no newline — the caller flushes explicitly.
    static func printStreaming(_ fragment: String) {
        print("\(Self.green)\(fragment)\(reset)", terminator: "")
        fflush(stdout)
    }

    /// "→ bash {\"command\": \"ls\"}" header above each tool execution.
    static func toolCall(_ call: ToolCall) -> String {
        var arguments = call.function.arguments
        if arguments.count > 160 { arguments = String(arguments.prefix(160)) + "…" }
        let header = "→ \(call.function.name) \(arguments)"
        return "\(Self.bold)\(Self.cyan)\(header)\(reset)"
    }

    /// Indented, truncated tool output.
    static func toolResult(_ output: String, isError: Bool) -> String {
        let color = isError ? red : blue
        let preview = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(12)
            .map { "  │ \($0)" }
            .joined(separator: "\n")
        let hidden = output.split(separator: "\n", omittingEmptySubsequences: false).count - 12
        let body = preview + (hidden > 0 ? "\n  │ … +\(hidden) more lines" : "")
        return "\(color)\(body)\(reset)"
    }
}