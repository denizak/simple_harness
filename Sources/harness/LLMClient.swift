import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession lives here on Linux
#endif

// ---------------------------------------------------------------------------
// LLMClient.swift — talking to the model.
//
// A harness is provider-agnostic by design: the *loop* only needs one
// capability — "give me these messages + these tools, give me a turn back".
// That's the `ChatModel` protocol. Implement it for any API dialect.
//
// `OpenAICompatClient` speaks the OpenAI Chat Completions dialect, which
// (despite the name) has become the lingua franca: Ollama, vLLM, OpenRouter,
// Groq, Together, LM Studio and most gateways all implement it. That's why we
// start here — one client, dozens of providers.
//
// (pi does the same trick in reverse: it normalizes providers to an
// Anthropic-shaped internal format. Different skin, same idea.)
// ---------------------------------------------------------------------------

protocol ChatModel: Sendable {
    /// One-shot completion (no streaming) — used by compaction's summarizer,
    /// where incremental display adds nothing.
    func complete(_ messages: [Message], tools: [ToolSpec]) async throws -> AssistantTurn

    /// Streaming variant used by the main loop. `onText` receives visible
    /// content fragments as they arrive (UI only — the loop prints them);
    /// the fully assembled turn (text + tool_calls + finish reason) is the
    /// return value, exactly what `complete` would have produced.
    func stream(
        _ messages: [Message],
        tools: [ToolSpec],
        onText: @Sendable (String) -> Void
    ) async throws -> AssistantTurn
}

extension ChatModel {
    /// Default streaming: fall back to one-shot and emit the text in one
    /// piece. Conformers get streaming for free; override it only when the
    /// provider actually supports SSE. (The stub model in the e2e suite uses
    /// exactly this fallback.)
    func stream(
        _ messages: [Message],
        tools: [ToolSpec],
        onText: @Sendable (String) -> Void
    ) async throws -> AssistantTurn {
        let turn = try await complete(messages, tools: tools)
        if !turn.text.isEmpty { onText(turn.text) }
        return turn
    }
}

struct LLMError: Error, CustomStringConvertible {
    let status: Int
    let body: String
    var description: String { "API error (HTTP \(status)): \(body.prefix(500))" }
}

struct OpenAICompatClient: ChatModel {
    var config: Config

    private struct Choice: Codable {
        // Mirror the wire format with camelCase names and map to snake_case
        // via CodingKeys — this keeps Swift style while decoding real JSON.
        struct ChoiceMessage: Codable {
            var role: String?
            var content: String?
            var toolCalls: [ToolCall]?

            private enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
            }
        }
        var message: ChoiceMessage
        var finishReason: String?

        private enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    private struct Response: Codable {
        var choices: [Choice]
        var usage: UsageWire?
        struct UsageWire: Codable {
            var promptTokens: Int
            var completionTokens: Int

            private enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }
    }

    func complete(_ messages: [Message], tools: [ToolSpec]) async throws -> AssistantTurn {
        var (body, request) = try requestFor(messages: messages, tools: tools, streaming: false)
        for attempt in 0..<2 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let error = LLMError(status: status, body: String(data: data, encoding: .utf8) ?? "<binary>")
                if Self.shouldRetryWithNone(error, attempt: attempt, sentEffort: body["reasoning_effort"] == nil) {
                    print(AgentUI.dim("  ↯ tools+reasoning rejected — retrying with reasoning_effort=none"))
                    (body, request) = try requestFor(messages: messages, tools: tools, streaming: false,
                                                     overrides: ["reasoning_effort": .string("none")])
                    continue
                }
                throw error
            }

            // Decode one choice into an AssistantTurn.
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let choice = decoded.choices.first else {
                throw LLMError(status: status, body: "Response contained no choices: \(data.prefix(300))")
            }
            let usage = decoded.usage.map { Usage(promptTokens: $0.promptTokens, completionTokens: $0.completionTokens) }
            return AssistantTurn(
                text: choice.message.content ?? "",
                toolCalls: choice.message.toolCalls ?? [],
                finishReason: choice.finishReason ?? "unknown",
                usage: usage
            )
        }
        throw LLMError(status: 0, body: "retry loop exhausted")
    }

    /// The streaming path: same request with "stream": true, but the response
    /// is a Server-Sent Events stream — lines of `data: {chunk}` ending with
    /// `data: [DONE]`. Two things make this the hard part of a client:
    ///   1. Content arrives in FRAGMENTS (print-as-you-go).
    ///   2. tool_calls arrive as delta fragments keyed by `index`: the first
    ///      fragment carries the id + function name, later fragments append
    ///      to `arguments`. The assembler below stitches them back together.
    func stream(
        _ messages: [Message],
        tools: [ToolSpec],
        onText: @Sendable (String) -> Void
    ) async throws -> AssistantTurn {
        var (body, request) = try requestFor(messages: messages, tools: tools, streaming: true)
        for attempt in 0..<2 {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                var errorBody = ""
                for try await byte in bytes.prefix(2_000) { errorBody.append(Character(UnicodeScalar(byte))) }
                let error = LLMError(status: status, body: errorBody)
                if Self.shouldRetryWithNone(error, attempt: attempt, sentEffort: body["reasoning_effort"] == nil) {
                    print(AgentUI.dim("  ↯ tools+reasoning rejected — retrying with reasoning_effort=none"))
                    (body, request) = try requestFor(messages: messages, tools: tools, streaming: true,
                                                     overrides: ["reasoning_effort": .string("none")])
                    continue
                }
                throw error
            }

            var assembler = SSEAssembler()
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }  // ignore comments/blanks
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let chunk = JSONValue.parse(payload) else { continue }
                let fragment = assembler.ingest(chunk)
                if !fragment.isEmpty { onText(fragment) }
            }
            return assembler.assembled()
        }
        throw LLMError(status: 0, body: "retry loop exhausted")
    }

    /// Shared request construction for both paths.
    func requestFor(
        messages: [Message], tools: [ToolSpec], streaming: Bool,
        overrides: [String: JSONValue] = [:]
    ) throws -> ([String: JSONValue], URLRequest) {
        // The Message structs already Codable-encode to exact wire format, so
        // here each message is serialized and re-parsed into a dynamic
        // JSONValue object. A direct dictionary build would skip the Codable
        // path; the round-trip keeps the wire format defined in ONE place
        // (Message), so the session file and the API request can never drift.
        // Provider quirk (declared on the profile in Providers.swift):
        // newer OpenAI models (o-series, gpt-5+) reject "max_tokens" and
        // require "max_completion_tokens"; everyone else expects
        // "max_tokens". Small per-provider quirks like this are why
        // harnesses keep a provider layer at all.
        let maxTokensKey = config.tokenLimitKey
        var body: [String: JSONValue] = [
            "model": .string(config.model),
            "messages": .array(messages.map { .parse(encode($0)) ?? .null }),
            maxTokensKey: .number(Double(config.maxTokens)),
        ]
        // Reasoning effort: only sent when explicitly configured.
        if let effort = config.reasoningEffort { body["reasoning_effort"] = .string(effort) }
        for (key, value) in overrides { body[key] = value }
        if streaming {
            body["stream"] = .bool(true)
            // stream_options lets the usage arrive in the final chunk. Only
            // sent to profiles that declare support — some OpenAI-compatible
            // servers validate strictly and would reject the extra field.
            if config.streamOptions {
                body["stream_options"] = .object(["include_usage": .bool(true)])
            }
        }
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { tool in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.parameters,
                    ]),
                ])
            })
        }
        let payload = (try? JSONEncoder().encode(body)) ?? Data()

        // ---- 2. POST it ----------------------------------------------------
        var request = URLRequest(url: URL(string: config.baseURL + "/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if config.apiKey != "none" {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = payload

        return (body, request)
    }

    /// GET {baseURL}/models — the OpenAI-compatible model listing. Works on
    /// Ollama Cloud (lists cloud models), and on local servers that implement
    /// the endpoint. Used by the /models REPL command.
    func listModels() async throws -> [String] {
        var request = URLRequest(url: URL(string: config.baseURL + "/models")!)
        request.timeoutInterval = 60
        if config.apiKey != "none" {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

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

    private func encode(_ message: Message) -> String {
        (try? JSONEncoder().encode(message)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// ---------------------------------------------------------------------------
// SSEAssembler — stitches Server-Sent-Events chunks back into one turn.
//
// The streaming wire format sends tiny deltas:
//   {"choices":[{"delta":{"content":"Hel"}}]}
//   {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1",
//                 "function":{"name":"ba","arguments":"{\""}}]}}]}
//   {"choices":[{"delta":{"tool_calls":[{"index":0,
//                 "function":{"arguments":"cmd:\"ls\"}"}}]},
//               "finish_reason":"tool_calls"}]}
//   {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}
//   data: [DONE]
//
// Text deltas concatenate directly. tool_calls are the tricky part: each
// fragment is keyed by `index` — the first carries id + name, later ones
// APPEND to `arguments`. Usage may ride in on a final chunk with no choices.
// This is a pure struct so --selftest can unit-test it with canned chunks,
// no network needed.
// ---------------------------------------------------------------------------
struct SSEAssembler {
    private(set) var text = ""
    private var calls: [Int: ToolCall] = [:]
    private(set) var finishReason: String?
    private(set) var usage: Usage?

    /// Ingest one `data:` payload; returns the visible text fragment (may be
    /// empty — tool_call deltas carry no displayable text).
    mutating func ingest(_ chunk: JSONValue) -> String {
        guard let obj = chunk.objectValue else { return "" }
        if let usageObj = obj["usage"]?.objectValue,
           let prompt = usageObj["prompt_tokens"]?.intValue,
           let completion = usageObj["completion_tokens"]?.intValue {
            usage = Usage(promptTokens: prompt, completionTokens: completion)
        }
        guard let choice = obj["choices"]?.arrayValue?.first?.objectValue else { return "" }
        if let reason = choice["finish_reason"]?.stringValue {
            finishReason = reason
        }
        guard let delta = choice["delta"]?.objectValue else { return "" }

        var fragment = ""
        if let content = delta["content"]?.stringValue, !content.isEmpty {
            text += content
            fragment = content
        }
        if let pieces = delta["tool_calls"]?.arrayValue {
            for piece in pieces {
                guard let pieceObj = piece.objectValue, let index = pieceObj["index"]?.intValue else { continue }
                var call = calls[index] ?? ToolCall(id: "", type: "function", function: .init(name: "", arguments: ""))
                if let id = pieceObj["id"]?.stringValue, !id.isEmpty { call.id = id }
                if let type = pieceObj["type"]?.stringValue { call.type = type }
                if let fn = pieceObj["function"]?.objectValue {
                    if let name = fn["name"]?.stringValue { call.function.name += name }
                    if let args = fn["arguments"]?.stringValue { call.function.arguments += args }
                }
                calls[index] = call
            }
        }
        return fragment
    }

    func assembled() -> AssistantTurn {
        let ordered = calls.sorted { $0.key < $1.key }.map { index, call in
            var call = call
            if call.id.isEmpty { call.id = "call_\(index)" }  // id never arrived
            return call
        }
        return AssistantTurn(text: text, toolCalls: ordered, finishReason: finishReason ?? "stop", usage: usage)
    }
}

extension OpenAICompatClient {
    /// True when a 400 error body names reasoning_effort — the provider's own
    /// remedy (retry with reasoning_effort "none") applies. Seen on
    /// gpt-5.6-luna: "Function tools with reasoning_effort are not supported
    /// in /v1/chat/completions … set reasoning_effort to 'none'".
    static func isReasoningToolConflict(_ error: LLMError) -> Bool {
        error.status == 400 && error.body.contains("reasoning_effort")
    }

    /// Guard for the one-shot self-healing retry.
    static func shouldRetryWithNone(
        _ error: LLMError, attempt: Int, sentEffort: Bool
    ) -> Bool {
        attempt == 0 && sentEffort && isReasoningToolConflict(error)
    }
}
