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
public struct ToolCall: Codable, Sendable, Equatable {
    public struct FunctionCall: Codable, Sendable, Equatable {
        public var name: String
        public var arguments: String

        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }

    public var id: String
    public var type: String
    public var function: FunctionCall

    public init(id: String, type: String = "function", function: FunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

/// A single conversation message in OpenAI chat format.
/// Exactly one of the three optional fields is populated per message:
///   - user / system messages:      `content`
///   - assistant asking for tools:  `toolCalls` (+ maybe `content`)
///   - tool result:                 `toolCallId` + `content`
public struct Message: Codable, Sendable {
    public var role: String
    public var content: String?
    public var toolCalls: [ToolCall]?
    public var toolCallId: String?
    /// Tool result messages are named after the tool (protocol detail; some
    /// servers want it). Encoded only for tool messages.
    public var name: String?

    private enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
        case name
    }

    public init(role: String, content: String?, toolCalls: [ToolCall]?,
                toolCallId: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
    }

    // Always emit "content" (as null when absent) — some servers reject
    // assistant tool_call messages without an explicit content: null.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try container.encodeIfPresent(name, forKey: .name)
    }

    // ---- Constructors (sugar that keeps the loop code readable) ----
    public static func system(_ text: String) -> Message {
        Message(role: "system", content: text, toolCalls: nil, toolCallId: nil, name: nil)
    }

    public static func user(_ text: String) -> Message {
        Message(role: "user", content: text, toolCalls: nil, toolCallId: nil, name: nil)
    }
    public static func tool(result: String, for call: ToolCall) -> Message {
        Message(role: "tool", content: result, toolCalls: nil, toolCallId: call.id, name: call.function.name)
    }
}

/// What the model produced in one turn.
public struct AssistantTurn: Sendable {
    public var text: String            // visible reply ("" when it only called tools)
    public var toolCalls: [ToolCall]   // [] when it replied with text only
    public var finishReason: String    // "stop" | "tool_calls" | ...
    public var usage: Usage?

    public var wantsTools: Bool { !toolCalls.isEmpty }
}

public struct Usage: Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
}

// ---------------------------------------------------------------------------
// ToolSpec — a tool = name + description + JSON schema + an executable.
//
// The description and schema are the *only* thing the model sees, so they are
// effectively a programming language the model writes against. Good tool
// descriptions are the difference between an agent that works and one that
// fumbles — write them like API docs.
// ---------------------------------------------------------------------------

public struct ToolSpec: Sendable {
    public var name: String
    public var description: String
    /// JSON Schema for the `parameters` object.
    public var parameters: JSONValue
    /// Execute with parsed arguments; returns the text fed back to the model.
    /// `context` carries what a tool needs from the harness itself — config,
    /// the parent's model client, cwd, and the agent's nesting depth (used by
    /// spawn_agent to enforce the recursion cap).
    public var run: @Sendable ([String: JSONValue], ToolContext) async throws -> String
}

/// What a tool needs from the harness around it. Passed to every tool run.
public struct ToolContext: Sendable {
    public var config: Config
    public var model: ChatModel
    public var cwd: String
    /// How deep this agent is in the spawn chain (top agent = 0).
    public var depth: Int

    public init(config: Config, model: ChatModel, cwd: String, depth: Int = 0) {
        self.config = config
        self.model = model
        self.cwd = cwd
        self.depth = depth
    }
}