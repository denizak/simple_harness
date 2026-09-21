import Foundation

// ---------------------------------------------------------------------------
// Types.swift — the conversation "wire format".
//
// These structs mirror the OpenAI Chat Completions JSON exactly. A nice
// consequence: a saved session file is byte-for-byte what you'd POST to the
// API, so you can open `.harness/session.json` and literally see the full
// conversation the model sees — history, tool calls, tool results.
//
// The message protocol is the heart of every agent harness:
//   user:      "human says something"
//   assistant: "model replies (text) and/or asks to run tools"
//   tool:      "the harness reports what the tool returned"
// ---------------------------------------------------------------------------

/// One tool invocation the model asked for. `arguments` stays a raw JSON
/// *string* — that's how the wire format carries it (models emit a string, we
/// parse it with JSONValue).
struct ToolCall: Codable, Sendable, Equatable {
    struct FunctionCall: Codable, Sendable, Equatable {
        var name: String
        var arguments: String
    }

    var id: String
    var type: String
    var function: FunctionCall
}

/// A single conversation message in OpenAI chat format.
/// Exactly one of the three optional fields is populated per message:
///   - user / system messages:      `content`
///   - assistant asking for tools:  `toolCalls` (+ maybe `content`)
///   - tool result:                 `toolCallId` + `content`
struct Message: Codable, Sendable {
    var role: String
    var content: String?
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    /// Tool result messages are named after the tool (protocol detail; some
    /// servers want it). Encoded only for tool messages.
    var name: String?

    private enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
        case name
    }

    // Always emit "content" (as null when absent) — some servers reject
    // assistant tool_call messages without an explicit content: null.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(name, forKey: .name)
    }

    // ---- Constructors (sugar that keeps the loop code readable) ----
    static func system(_ text: String) -> Message {
        Message(role: "system", content: text, toolCalls: nil, toolCallId: nil, name: nil)
    }

    static func user(_ text: String) -> Message {
        Message(role: "user", content: text, toolCalls: nil, toolCallId: nil, name: nil)
    }
    static func tool(result: String, for call: ToolCall) -> Message {
        Message(role: "tool", content: result, toolCalls: nil, toolCallId: call.id, name: call.function.name)
    }
}

/// What the model produced in one turn.
struct AssistantTurn: Sendable {
    var text: String            // visible reply ("" when it only called tools)
    var toolCalls: [ToolCall]   // [] when it replied with text only
    var finishReason: String    // "stop" | "tool_calls" | ...
    var usage: Usage?

    var wantsTools: Bool { !toolCalls.isEmpty }
}

struct Usage: Sendable {
    var promptTokens: Int
    var completionTokens: Int
}

// ---------------------------------------------------------------------------
// ToolSpec — a tool = name + description + JSON schema + an executable.
//
// The description and schema are the *only* thing the model sees, so they are
// effectively a programming language the model writes against. Good tool
// descriptions are the difference between an agent that works and one that
// fumbles — write them like API docs.
// ---------------------------------------------------------------------------

struct ToolSpec: Sendable {
    var name: String
    var description: String
    /// JSON Schema for the `parameters` object.
    var parameters: JSONValue
    /// Execute with parsed arguments; returns the text fed back to the model.
    var run: @Sendable ([String: JSONValue], String) async throws -> String
}