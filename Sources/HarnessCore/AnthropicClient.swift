import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession lives here on Linux
#endif

// ---------------------------------------------------------------------------
// AnthropicClient.swift — the second dialect.
//
// Anthropic's Messages API (https://api.anthropic.com/v1/messages) is *not*
// OpenAI-compatible, so it gets its own ChatModel conformance. Comparing the
// two protocols is the point of this exercise:
//
//   OpenAI Chat Completions            Anthropic Messages
//   ───────────────────────            ──────────────────
//   system role message                top-level `system` parameter
//   assistant.tool_calls[]             content blocks type "tool_use"
//   role:"tool" message per result     one user message holding
//                                        content blocks type "tool_result"
//   tools[].function.parameters        tools[].input_schema
//   finish_reason: "tool_calls"        stop_reason: "tool_use"
//   Authorization: Bearer …            x-api-key + anthropic-version headers
//   SSE: choices[].delta               SSE: typed events (content_block_delta,
//                                        input_json_delta …)
//
// Mapping rules this client implements (Message → Messages API):
//   • system messages are hoisted into the `system` parameter, joined by
//     blank lines; the loop always emits exactly one at index 0.
//   • an assistant turn with tool calls becomes a content array: an optional
//     text block followed by one tool_use block per call, with `input` being
//     the *parsed* arguments JSON (the wire format is an object here, not a
//     string — the inverse of OpenAI, where arguments arrive as a string).
//   • every tool-result message becomes its own user message containing a
//     single tool_result block (Anthropic requires results in a user turn).
//   • unparseable tool arguments map to input {} — never crash the loop.
// ---------------------------------------------------------------------------

public struct AnthropicClient: ChatModel {
    public var config: Config

    public init(config: Config) {
        self.config = config
    }

    // ---- request-side conversion -----------------------------------------

    /// System prompt hoisted out of the message list (top-level parameter).
    static func systemParameter(_ messages: [Message]) -> String? {
        let system = messages.filter { $0.role == "system" }.compactMap { $0.content }
        return system.isEmpty ? nil : system.joined(separator: "\n\n")
    }

    /// One Messages-API content block. Kept as JSONValue so we can build the
    /// request body without a mirror Codable struct per block shape.
    static func contentBlocks(for message: Message) -> [JSONValue] {
        var blocks: [JSONValue] = []
        // Assistant text rides along with tool_use blocks in the same turn.
        if let text = message.content, !text.isEmpty {
            blocks.append(.object(["type": .string("text"), "text": .string(text)]))
        }
        for call in message.toolCalls ?? [] {
            // arguments is a JSON *string* on our side; Anthropic wants the
            // parsed object. Fall back to {} rather than dropping the call.
            let input = JSONValue.parse(call.function.arguments) ?? .object([:])
            blocks.append(.object([
                "type": .string("tool_use"),
                "id": .string(call.id),
                "name": .string(call.function.name),
                "input": input,
            ]))
        }
        if message.role == "tool", let id = message.toolCallId {
            blocks = [.object([
                "type": .string("tool_result"),
                "tool_use_id": .string(id),
                "content": .string(message.content ?? ""),
            ])]
        }
        return blocks
    }

    /// OpenAI-shaped conversation → Messages-API request body. Exposed for
    /// tests and the selftest: the mapping IS the interesting part.
    public static func requestBody(
        _ messages: [Message], tools: [ToolSpec], config: Config
    ) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "model": .string(config.model),
            "max_tokens": .number(Double(config.maxTokens)),
        ]
        if let system = systemParameter(messages) { body["system"] = .string(system) }
        body["messages"] = .array(messages.compactMap { message in
            switch message.role {
            case "system":
                return nil  // hoisted to the system parameter
            case "assistant" where (message.toolCalls ?? []).isEmpty && (message.content ?? "").isEmpty:
                return nil  // degenerate turn; Anthropic rejects empty content
            default:
                return .object([
                    "role": .string(message.role == "tool" ? "user" : message.role),
                    "content": .array(contentBlocks(for: message)),
                ])
            }
        })
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": tool.parameters,
                ])
            })
        }
        return body
    }

    static func request(for messages: [Message], tools: [ToolSpec], config: Config,
                        streaming: Bool) -> URLRequest {
        var body = requestBody(messages, tools: tools, config: config)
        if streaming { body["stream"] = .bool(true) }
        var request = URLRequest(url: URL(string: config.baseURL + "/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.httpBody = (try? JSONEncoder().encode(body)) ?? Data()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Anthropic authentication: a dedicated header, not Bearer — plus a
        // version pin that gates API behavior.
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    // ---- response-side conversion ----------------------------------------

    /// Map Anthropic stop reasons onto the loop's finish-reason vocabulary so
    /// Agent.swift stays dialect-blind. "tool_use" is the critical one.
    static func finishReason(for stopReason: String?) -> String {
        switch stopReason {
        case "tool_use": return "tool_calls"
        case "end_turn": return "stop"
        case "max_tokens": return "length"
        case "stop_sequence": return "stop"
        case nil: return "unknown"
        case .some(let other): return other
        }
    }

    /// AssistantTurn from a non-streaming response body.
    public static func turn(from data: Data) throws -> AssistantTurn {
        guard let root = JSONValue.parse(String(data: data, encoding: .utf8) ?? "") else {
            throw LLMError(status: 200, body: "Unparseable response body")
        }
        return try turn(from: root)
    }

    public static func turn(from root: JSONValue) throws -> AssistantTurn {
        guard let obj = root.objectValue else {
            throw LLMError(status: 200, body: "Unexpected response shape")
        }
        var text = ""
        var calls: [ToolCall] = []
        for block in obj["content"]?.arrayValue ?? [] {
            guard let block = block.objectValue else { continue }
            switch block["type"]?.stringValue {
            case "text":
                text += block["text"]?.stringValue ?? ""
            case "tool_use":
                // input is an object on the wire; re-stringify into the raw
                // arguments string our ToolCall carries.
                let input = block["input"] ?? .object([:])
                let arguments = (try? JSONEncoder().encode(input))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                calls.append(ToolCall(
                    id: block["id"]?.stringValue ?? "",
                    type: "function",
                    function: .init(name: block["name"]?.stringValue ?? "", arguments: arguments)
                ))
            default:
                break  // thinking / server_tool_use blocks are ignored for now
            }
        }
        var usage: Usage?
        if let usageObj = obj["usage"]?.objectValue,
           let prompt = usageObj["input_tokens"]?.intValue,
           let completion = usageObj["output_tokens"]?.intValue {
            usage = Usage(promptTokens: prompt, completionTokens: completion)
        }
        return AssistantTurn(
            text: text,
            toolCalls: calls,
            finishReason: finishReason(for: obj["stop_reason"]?.stringValue),
            usage: usage
        )
    }

    // ---- ChatModel conformance --------------------------------------------

    public func complete(_ messages: [Message], tools: [ToolSpec]) async throws -> AssistantTurn {
        let request = Self.request(for: messages, tools: tools, config: config, streaming: false)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError(status: status, body: String(data: data, encoding: .utf8) ?? "<binary>")
        }
        return try Self.turn(from: data)
    }

    public func stream(
        _ messages: [Message], tools: [ToolSpec], onText: @Sendable (String) -> Void
    ) async throws -> AssistantTurn {
        let request = Self.request(for: messages, tools: tools, config: config, streaming: true)
        let (bytes, response) = try await httpByteStream(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var errorBody = ""
            for try await byte in bytes.prefix(2_000) { errorBody.append(Character(UnicodeScalar(byte))) }
            throw LLMError(status: status, body: errorBody)
        }
        var assembler = AnthropicSSEAssembler()
        for try await line in sseLines(from: bytes) {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let event = JSONValue.parse(payload) else { continue }
            let fragment = assembler.ingest(event)
            if !fragment.isEmpty { onText(fragment) }
        }
        return assembler.assembled()
    }

    /// GET {baseURL}/models — Anthropic exposes a model list with the same
    /// {"data":[{"id": …}]} envelope the REPL's /models command expects.
    public func listModels() async throws -> [String] {
        var request = URLRequest(url: URL(string: config.baseURL + "/models")!)
        request.timeoutInterval = 60
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError(status: status, body: String(data: data, encoding: .utf8) ?? "<binary>")
        }
        guard let root = JSONValue.parse(String(data: data, encoding: .utf8) ?? ""),
              let entries = root.objectValue?["data"]?.arrayValue else {
            throw LLMError(status: status, body: "Unexpected /models response shape")
        }
        return entries.compactMap { $0.objectValue?["id"]?.stringValue }.sorted()
    }
}

// ---------------------------------------------------------------------------
// AnthropicSSEAssembler — reassembly for the Messages event grammar.
//
// Streaming here is *typed events*, not OpenAI's shapeless choice deltas:
//   data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}
//   data: {"type":"content_block_start","index":0,
//          "content_block":{"type":"text"}}
//   data: {"type":"content_block_delta","index":0,
//          "delta":{"type":"text_delta","text":"Hel"}}
//   data: {"type":"content_block_start","index":1,
//          "content_block":{"type":"tool_use","id":"t1","name":"bash"}}
//   data: {"type":"content_block_delta","index":1,
//          "delta":{"type":"input_json_delta","partial_json":"{\"cmd\""}}
//   data: {"type":"content_block_stop","index":1}
//   data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},
//          "usage":{"output_tokens":5}}
//   data: {"type":"message_stop"}
//
// Blocks are keyed by `index`; tool arguments arrive as partial_json
// fragments that concatenate. Pure struct, unit-testable offline like
// SSEAssembler.
// ---------------------------------------------------------------------------
public struct AnthropicSSEAssembler {
    public init() {}

    private(set) var text = ""
    private var blocks: [Int: ToolCall] = [:]
    private var stopReason: String?
    private var promptTokens: Int?
    private var completionTokens: Int?

    /// Ingest one event payload; returns the visible text fragment (may be
    /// empty — most event types carry none).
    public mutating func ingest(_ event: JSONValue) -> String {
        guard let obj = event.objectValue else { return "" }
        switch obj["type"]?.stringValue {
        case "message_start":
            promptTokens = obj["message"]?.objectValue?["usage"]?
                .objectValue?["input_tokens"]?.intValue ?? promptTokens
        case "content_block_start":
            guard let index = obj["index"]?.intValue,
                  let block = obj["content_block"]?.objectValue,
                  block["type"]?.stringValue == "tool_use" else { return "" }
            blocks[index] = ToolCall(
                id: block["id"]?.stringValue ?? "",
                type: "function",
                function: .init(name: block["name"]?.stringValue ?? "", arguments: "")
            )
        case "content_block_delta":
            guard let index = obj["index"]?.intValue,
                  let delta = obj["delta"]?.objectValue else { return "" }
            switch delta["type"]?.stringValue {
            case "text_delta":
                guard let piece = delta["text"]?.stringValue, !piece.isEmpty else { return "" }
                text += piece
                return piece
            case "input_json_delta":
                if var call = blocks[index] {
                    call.function.arguments += delta["partial_json"]?.stringValue ?? ""
                    blocks[index] = call
                }
            default:
                break  // thinking_delta etc.
            }
        case "message_delta":
            stopReason = obj["delta"]?.objectValue?["stop_reason"]?.stringValue ?? stopReason
            if let output = obj["usage"]?.objectValue?["output_tokens"]?.intValue {
                completionTokens = output
            }
        default:
            break  // ping, message_stop, content_block_stop
        }
        return ""
    }

    public func assembled() -> AssistantTurn {
        let ordered = blocks.sorted { $0.key < $1.key }.map { $0.value }
        let usage = Usage(
            promptTokens: promptTokens ?? 0,
            completionTokens: completionTokens ?? 0
        )
        return AssistantTurn(
            text: text,
            toolCalls: ordered,
            finishReason: AnthropicClient.finishReason(for: stopReason),
            usage: (promptTokens != nil || completionTokens != nil) ? usage : nil
        )
    }
}