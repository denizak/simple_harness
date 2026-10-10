import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession lives here on Linux
#endif

// ---------------------------------------------------------------------------
// TypeSafe.swift — the TypeSafe / Jev backend for naluri.
//
// One NaluriBackend among possible others (see Naluri.swift). TypeSafe
// (https://docs.typesafe.ai) is NOT a chat API: its System One model (Jev)
// answers typed questions about a `state` and returns calibrated
// probabilities — not prose.
//
// Wire contract (https://docs.typesafe.ai/api.md):
//   POST https://api.typesafe.ai/v1/systemone      Authorization: Bearer <key>
//   { "state": <string>, "model": "jev-latest", "questions": { <id>: {type, instructions, criteria} } }
//   → { "model": "...", "answers": { <id>: {"type": "noul", "noul": 0.95} | … }, "usage": {...} }
// ---------------------------------------------------------------------------

public enum TypeSafeClient {
    public static let endpoint = "https://api.typesafe.ai/v1/systemone"
    public static let model = "jev-latest"

    /// Pure helper — builds the request body from tool arguments. Unit-tested
    /// in --selftest (no network, no key needed).
    public static func request(state: String, questions: [NaluriQuestion]) -> JSONValue {
        var questionMap: [String: JSONValue] = [:]
        for question in questions {
            var entry: [String: JSONValue] = [
                "type": .string(question.type),
                "instructions": .string(question.instructions),
            ]
            if let criteria = question.criteria { entry["criteria"] = criteria }
            questionMap[question.id] = .object(entry)
        }
        return .object([
            "state": .string(state),
            "model": .string(model),
            "questions": .object(questionMap),
        ])
    }

    /// POST the evaluation. Retries 429/529 with linear backoff (the docs
    /// recommend backing off rather than immediate retries).
    public static func evaluate(
        state: String, questions: [NaluriQuestion], apiKey: String
    ) async throws -> JSONValue {
        let payload = try JSONEncoder().encode(request(state: state, questions: questions))
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        for attempt in 0..<3 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 429 Too Many Requests / 529 Overloaded → back off and retry.
            if (status == 429 || status == 529), attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000) * UInt64(attempt + 1))
                continue
            }
            guard (200..<300).contains(status) else {
                throw LLMError(status: status, body: String(data: data, encoding: .utf8) ?? "<binary>")
            }
            guard let root = JSONValue.parse(String(data: data, encoding: .utf8) ?? "") else {
                throw LLMError(status: status, body: "TypeSafe response was not valid JSON")
            }
            return root
        }
        throw LLMError(status: 0, body: "TypeSafe retry loop exhausted")
    }
}

/// The TypeSafe (Jev) implementation of NaluriBackend.
struct TypeSafeBackend: NaluriBackend {
    let apiKey: String
    func evaluate(state: String, questions: [NaluriQuestion]) async throws -> JSONValue {
        try await TypeSafeClient.evaluate(state: state, questions: questions, apiKey: apiKey)
    }
}
