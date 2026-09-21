import Foundation

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
    func complete(_ messages: [Message], tools: [ToolSpec]) async throws -> AssistantTurn
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
        // ---- 1. Build the request body ------------------------------------
        // The Message structs already Codable-encode to exact wire format, so
        // here each message is serialized and re-parsed into a dynamic
        // JSONValue object. A direct dictionary build would skip the Codable
        // path; the round-trip keeps the wire format defined in ONE place
        // (Message), so the session file and the API request can never drift.
        // Provider quirk: newer OpenAI models (o-series, gpt-5+) reject
        // "max_tokens" and require "max_completion_tokens"; everyone else
        // expects "max_tokens". Small per-provider quirks like this are why
        // harnesses keep a provider layer at all.
        let maxTokensKey = config.baseURL.contains("api.openai.com")
            ? "max_completion_tokens"
            : "max_tokens"
        var body: [String: JSONValue] = [
            "model": .string(config.model),
            "messages": .array(messages.map { .parse(encode($0)) ?? .null }),
            maxTokensKey: .number(Double(config.maxTokens)),
        ]
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

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError(status: status, body: String(data: data, encoding: .utf8) ?? "<binary>")
        }

        // ---- 3. Decode one choice into an AssistantTurn --------------------
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