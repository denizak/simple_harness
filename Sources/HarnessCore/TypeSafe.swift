import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession lives here on Linux
#endif

// ---------------------------------------------------------------------------
// TypeSafe.swift — typed judgments as a tool primitive.
//
// TypeSafe (https://docs.typesafe.ai) is NOT a chat API: its System One
// models answer typed questions about a `state` and return calibrated
// probabilities — not prose. So it does NOT implement ChatModel (the loop
// needs text generation); instead it's a TOOL the agent can call when a
// decision wants a number, e.g. "is this log urgent? 0.95" or "which team
// should handle this? billing (88%)". Code owns the workflow; the model
// supplies programmable common sense.
//
// Wire contract (https://docs.typesafe.ai/api.md):
//   POST https://api.typesafe.ai/v1/systemone      Authorization: Bearer <key>
//   { "state": <string>, "model": "jev-latest", "questions": { <id>: {type, instructions, criteria} } }
//   → { "model": "...", "answers": { <id>: {"type": "noul", "noul": 0.95} | … }, "usage": {...} }
// ---------------------------------------------------------------------------

/// One typed question, normalized from tool arguments.
public struct TypeSafeQuestion: Sendable {
    public var id: String
    /// "noul" (yes/no) | "choice" (pick one) | "score" (rate on levels)
    public var type: String
    public var instructions: String
    /// noul → {"true": …, "false": …} · choice → {option: description} · score → [levels]
    public var criteria: JSONValue?

    public init(id: String, type: String, instructions: String, criteria: JSONValue? = nil) {
        self.id = id
        self.type = type
        self.instructions = instructions
        self.criteria = criteria
    }
}

public enum TypeSafeClient {
    public static let endpoint = "https://api.typesafe.ai/v1/systemone"
    public static let model = "jev-latest"

    /// Pure helper — builds the request body from tool arguments. Unit-tested
    /// in --selftest (no network, no key needed).
    public static func request(state: String, questions: [TypeSafeQuestion]) -> JSONValue {
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
        state: String, questions: [TypeSafeQuestion], apiKey: String
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

    /// Render the answer map into compact, model-readable lines.
    /// Split into tiny per-answer functions: one big `format` made the Swift
    /// type-checker blow its time budget (each optional-chain + interpolation
    /// accumulates). Small functions type-check in microseconds.
    public static func format(_ root: JSONValue) -> String {
        guard let answers = root.objectValue?["answers"]?.objectValue else {
            return "TypeSafe returned no answers"
        }
        var lines: [String] = []
        for (id, answer) in answers.sorted(by: { $0.key < $1.key }) {
            lines.append(formatAnswer(id: id, answer: answer))
        }
        if let usage = root.objectValue?["usage"]?.objectValue {
            let input = usage["input_tokens"]?.intValue ?? 0
            let output = usage["output_tokens"]?.intValue ?? 0
            lines.append(AgentUI.dim("   [TypeSafe: \(input)+\(output) tokens]"))
        }
        return lines.joined(separator: "\n")
    }

    private static func formatAnswer(id: String, answer: JSONValue) -> String {
        guard let obj = answer.objectValue else { return "\(id): (unparseable)" }
        switch obj["type"]?.stringValue ?? "unknown" {
        case "noul":   return noulLine(id: id, obj)
        case "choice": return choiceLine(id: id, obj)
        case "score":  return scoreLine(id: id, obj)
        default:       return "\(id): \(obj)"
        }
    }

    private static func noulLine(id: String, _ obj: [String: JSONValue]) -> String {
        let probability = obj["noul"]?.doubleValue ?? 0
        let percent = Int((probability * 100).rounded())
        let probabilityText = String(format: "%.2f", probability)
        return "\(id) [yes/no]: \(probabilityText) — yes with \(percent)% probability"
    }

    private static func choiceLine(id: String, _ obj: [String: JSONValue]) -> String {
        let choice = obj["choice"]?.stringValue ?? "?"
        let confidenceText = String(format: "%.2f", obj["confidence"]?.doubleValue ?? 0)
        let probabilities = (obj["probabilities"]?.objectValue ?? [:])
            .map { (option: $0.key, probability: $0.value.doubleValue ?? 0) }
            .sorted { $0.probability > $1.probability }
            .map { "\($0.option) \(Int(($0.probability * 100).rounded()))%" }
            .joined(separator: ", ")
        return "\(id) [choice]: '\(choice)' (confidence \(confidenceText); \(probabilities))"
    }

    private static func scoreLine(id: String, _ obj: [String: JSONValue]) -> String {
        let scoreText = String(format: "%.2f", obj["score"]?.doubleValue ?? 0)
        let confidenceText = String(format: "%.2f", obj["confidence"]?.doubleValue ?? 0)
        let legendLevels = (obj["legend"]?.objectValue ?? [:])
            .map { (level: Int($0.key) ?? 0, label: $0.value.stringValue ?? "") }
            .sorted { $0.level < $1.level }
            .compactMap { $0.label }
            .joined(separator: " < ")
        return "\(id) [score]: \(scoreText) on \(legendLevels) (confidence \(confidenceText))"
    }
}
