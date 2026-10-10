import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession lives here on Linux
#endif

// ---------------------------------------------------------------------------
// ChatNaluri.swift — naluri on a cheap chat model (deepseek-flash, glm-flash).
//
// A chat model is not a calibrated classifier, but its FIRST output token is
// one: constrain the answer to a single token (yes/no, an option letter, a
// level digit), ask the server for `logprobs` + `top_logprobs`, and normalise
// the probability mass over the allowed tokens. That yields a real
// distribution from one tiny request — no reasoning, no prose.
//
// One request per question (each has its own token set), run concurrently.
// If a provider returns no logprobs, the generated token is taken as a
// one-hot answer and flagged `uncalibrated` so the model reading it knows
// the number is a pick, not a probability.
//
// Output matches the shared naluri answer shape (see Naluri.swift).
// ---------------------------------------------------------------------------

struct ChatNaluri: NaluriBackend {
    let profile: ProviderProfile
    let model: String
    let apiKey: String

    // MARK: pure helpers (unit-tested)

    /// The prompt for one question plus the single-token answers it allows
    /// (lowercased, in option order).
    static func prompt(for question: NaluriQuestion, state: String) throws -> (text: String, candidates: [String]) {
        var lines = ["Text to evaluate:", "<<<", state, ">>>", "", "Question: \(question.instructions)"]
        let candidates: [String]
        switch question.type {
        case "noul":
            let yes = question.criteria?.objectValue?["true"]?.stringValue
            let no = question.criteria?.objectValue?["false"]?.stringValue
            if let yes { lines.append("yes means: \(yes)") }
            if let no { lines.append("no means: \(no)") }
            lines.append("Answer with exactly one word: yes or no.")
            candidates = ["yes", "no"]
        case "choice":
            let options = (question.criteria?.objectValue ?? [:]).sorted { $0.key < $1.key }
            guard (2...26).contains(options.count) else {
                throw LLMError(status: 0, body: "choice '\(question.id)' needs 2-26 options for the chat backend")
            }
            let letters = options.indices.map { String(UnicodeScalar(UInt8(97 + $0))) }
            for (letter, option) in zip(letters, options) {
                lines.append("\(letter.uppercased()). \(option.key) — \(option.value.stringValue ?? "")")
            }
            lines.append("Answer with exactly one letter.")
            candidates = letters
        case "score":
            let levels = question.criteria?.arrayValue ?? []
            guard (2...10).contains(levels.count) else {
                throw LLMError(status: 0, body: "score '\(question.id)' needs 2-10 levels for the chat backend")
            }
            for (index, level) in levels.enumerated() { lines.append("\(index) = \(level.stringValue ?? "")") }
            lines.append("Answer with exactly one digit.")
            candidates = levels.indices.map { String($0) }
        default:
            throw LLMError(status: 0, body: "unknown question type '\(question.type)'")
        }
        return (lines.joined(separator: "\n"), candidates)
    }

    /// True when a response ran out of tokens before producing any visible
    /// answer — a thinking model spent the whole budget reasoning.
    static func needsMoreTokens(content: String, finishReason: String?) -> Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && finishReason == "length"
    }

    /// Probability per candidate from top_logprobs, normalised over the
    /// candidates only. Tokens match after trimming whitespace and lowercasing
    /// (" Yes", "yes" and "YES" are the same answer). nil when no candidate
    /// appears at all.
    static func distribution(top: [(token: String, logprob: Double)], candidates: [String]) -> [Double]? {
        var mass = [Double](repeating: 0, count: candidates.count)
        for entry in top {
            let token = entry.token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let index = candidates.firstIndex(of: token) { mass[index] += exp(entry.logprob) }
        }
        let total = mass.reduce(0, +)
        return total > 0 ? mass.map { $0 / total } : nil
    }

    /// Build the shared-shape answer from a candidate distribution.
    static func answer(for question: NaluriQuestion, probabilities: [Double], calibrated: Bool) -> JSONValue {
        var entry: [String: JSONValue]
        switch question.type {
        case "noul":
            entry = ["type": .string("noul"), "noul": .number(probabilities[0])]
        case "choice":
            let names = (question.criteria?.objectValue ?? [:]).keys.sorted()
            let best = probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0
            entry = [
                "type": .string("choice"),
                "choice": .string(names[best]),
                "probabilities": .object(Dictionary(uniqueKeysWithValues:
                    zip(names, probabilities.map { JSONValue.number($0) }))),
                "confidence": .number(probabilities[best]),
            ]
        default:
            let levels = question.criteria?.arrayValue ?? []
            let expected = probabilities.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element }
            entry = [
                "type": .string("score"),
                "score": .number(expected),
                "confidence": .number(probabilities.max() ?? 0),
                "legend": .object(Dictionary(uniqueKeysWithValues:
                    levels.enumerated().map { (String($0.offset), $0.element) })),
            ]
        }
        if !calibrated { entry["uncalibrated"] = .bool(true) }
        return .object(entry)
    }

    // MARK: backend

    func evaluate(state: String, questions: [NaluriQuestion]) async throws -> JSONValue {
        var answers: [String: JSONValue] = [:]
        var inputTokens = 0
        var outputTokens = 0
        try await withThrowingTaskGroup(of: (String, JSONValue, Int, Int).self) { group in
            for question in questions {
                group.addTask { try await self.ask(question, state: state) }
            }
            for try await (id, answer, input, output) in group {
                answers[id] = answer
                inputTokens += input
                outputTokens += output
            }
        }
        return .object([
            "model": .string(model),
            "answers": .object(answers),
            "usage": .object(["input_tokens": .number(Double(inputTokens)),
                              "output_tokens": .number(Double(outputTokens))]),
        ])
    }

    private func ask(_ question: NaluriQuestion, state: String) async throws -> (String, JSONValue, Int, Int) {
        let (text, candidates) = try Self.prompt(for: question, state: state)
        var maxTokens = profile.naluriMaxTokens ?? 4
        var inputTotal = 0
        var outputTotal = 0
        // One retry with a much larger budget if a thinking model ran out of
        // tokens before answering (empty content, finish_reason "length").
        for attempt in 0..<2 {
            var body: [String: JSONValue] = [
                "model": .string(model),
                "messages": .array([
                    .object(["role": .string("system"), "content": .string(
                        "You are a fast classifier. Reply with the single answer token only — no explanation.")]),
                    .object(["role": .string("user"), "content": .string(text)]),
                ]),
                profile.tokenLimitField.rawValue: .number(Double(maxTokens)),
                "temperature": .number(0),
                "logprobs": .bool(true),
                "top_logprobs": .number(20),
                // Reasoning would burn the token budget before the answer token.
                "thinking": .object(["type": .string("disabled")]),
            ]
            var root = try await post(body)
            if root == nil {  // 400: this server rejects `thinking` — retry without it
                body["thinking"] = nil
                root = try await post(body)
            }
            guard let response = root?.objectValue,
                  let choice = response["choices"]?.arrayValue?.first?.objectValue else {
                throw LLMError(status: 0, body: "no choices in naluri response for '\(question.id)'")
            }
            let usage = response["usage"]?.objectValue
            inputTotal += usage?["prompt_tokens"]?.intValue ?? 0
            outputTotal += usage?["completion_tokens"]?.intValue ?? 0

            let first = choice["logprobs"]?.objectValue?["content"]?.arrayValue?.first?.objectValue
            let top = (first?["top_logprobs"]?.arrayValue ?? []).compactMap { item -> (String, Double)? in
                guard let token = item.objectValue?["token"]?.stringValue,
                      let logprob = item.objectValue?["logprob"]?.doubleValue else { return nil }
                return (token, logprob)
            }
            if let probabilities = Self.distribution(top: top, candidates: candidates) {
                return (question.id, Self.answer(for: question, probabilities: probabilities, calibrated: true),
                        inputTotal, outputTotal)
            }
            // No usable logprobs: fall back to the generated token, one-hot.
            let content = choice["message"]?.objectValue?["content"]?.stringValue ?? ""
            if attempt == 0, Self.needsMoreTokens(content: content, finishReason: choice["finish_reason"]?.stringValue) {
                maxTokens = min(max(maxTokens, 4) * 16, 4096)
                continue
            }
            let token = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let index = candidates.firstIndex(where: { token.hasPrefix($0) }) else {
                throw LLMError(status: 0, body: "naluri answer for '\(question.id)' was not one of \(candidates): '\(content.prefix(40))'")
            }
            var probabilities = [Double](repeating: 0, count: candidates.count)
            probabilities[index] = 1
            return (question.id, Self.answer(for: question, probabilities: probabilities, calibrated: false),
                    inputTotal, outputTotal)
        }
        throw LLMError(status: 0, body: "naluri retry exhausted for '\(question.id)'")
    }

    /// POST one completion. Returns nil on HTTP 400 so the caller can retry
    /// without optional fields; 429/529 back off; anything else throws.
    private func post(_ body: [String: JSONValue]) async throws -> JSONValue? {
        var request = URLRequest(url: URL(string: profile.baseURL + "/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        for attempt in 0..<3 {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 429 can mean "out of balance" (z.ai code 1113), which no amount
            // of backing off fixes — only retry real rate limiting.
            let outOfBalance = String(data: data, encoding: .utf8)?.lowercased().contains("balance") == true
            if (status == 429 || status == 529), attempt < 2, !outOfBalance {
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000) * UInt64(attempt + 1))
                continue
            }
            if status == 400, body["thinking"] != nil { return nil }
            guard (200..<300).contains(status) else {
                throw LLMError(status: status, body: String(data: data, encoding: .utf8) ?? "<binary>")
            }
            guard let root = JSONValue.parse(String(data: data, encoding: .utf8) ?? "") else {
                throw LLMError(status: status, body: "naluri response was not valid JSON")
            }
            return root
        }
        throw LLMError(status: 0, body: "naluri retry loop exhausted")
    }
}
