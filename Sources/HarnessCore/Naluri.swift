import Foundation

// ---------------------------------------------------------------------------
// Naluri.swift — fast, typed gut-calls as a tool primitive.
//
// "Naluri" (Indonesian: instinct) is the System One of Kahneman's pair: quick,
// intuitive judgment, as opposed to the deliberate System Two of the chat
// loop. A naluri call answers typed questions about a `state` with
// probabilities — e.g. "is this log urgent? 0.95" or "which team should handle
// this? billing (88%)". Code owns the workflow; naluri supplies programmable
// common sense. It is NOT a ChatModel: it is a TOOL (NaluriTool.swift) and a
// pre-model gate (Gate.swift).
//
// Backends answer in one shared wire shape (the TypeSafe one):
//   { "answers": { <id>: {"type":"noul","noul":0.95} | {"type":"choice",…} | {"type":"score",…} },
//     "usage": {...} }
// so the formatter, tool and gate are backend-agnostic.
// ---------------------------------------------------------------------------

/// Anything that can answer naluri questions in the shared answer shape.
public protocol NaluriBackend: Sendable {
    func evaluate(state: String, questions: [NaluriQuestion]) async throws -> JSONValue
}

extension Config {
    /// The configured naluri backend, or nil when none has credentials.
    ///   typesafe (default when TYPESAFE_API_KEY is set) — Jev, calibrated.
    ///   <catalog provider id> (deepseek, zai, …)         — a cheap chat model
    ///     answering through logprobs (ChatNaluri).
    /// Select with HARNESS_NALURI / --naluri / "naluri" in the config file;
    /// the chat model defaults per provider, override with HARNESS_NALURI_MODEL.
    var naluriBackend: NaluriBackend? {
        let name = naluriBackendName ?? (typesafeApiKey != nil ? "typesafe" : nil)
        guard let name else { return nil }
        if name == "typesafe" { return typesafeApiKey.map { TypeSafeBackend(apiKey: $0) } }
        guard let profile = Config.catalog[name], profile.name != "anthropic" else { return nil }
        // The provider's own env key wins: the main config's apiKey may come
        // from a config file written for a different purpose (or be stale).
        let key = profile.key(in: ProcessInfo.processInfo.environment)
            ?? (provider == name ? apiKey : nil)
        guard let key, !key.isEmpty, key != "none" else { return nil }
        return ChatNaluri(profile: profile, model: naluriModel ?? ChatNaluri.defaultModel(for: profile), apiKey: key)
    }

    /// Why no backend resolved — shown by the tool and gate.
    var naluriSetupHint: String {
        "no naluri backend configured (set TYPESAFE_API_KEY, or HARNESS_NALURI=deepseek|zai with that provider's key)"
    }
}

/// One typed question, normalized from tool arguments.
public struct NaluriQuestion: Sendable {
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

/// Renders the answer map into compact, model-readable lines.
/// Split into tiny per-answer functions: one big function made the Swift
/// type-checker blow its time budget (each optional-chain + interpolation
/// accumulates). Small functions type-check in microseconds.
public enum NaluriFormat {
    /// Render the answer map into compact, model-readable lines.
    /// Split into tiny per-answer functions: one big `format` made the Swift
    /// type-checker blow its time budget (each optional-chain + interpolation
    /// accumulates). Small functions type-check in microseconds.
    public static func render(_ root: JSONValue) -> String {
        guard let answers = root.objectValue?["answers"]?.objectValue else {
            return "naluri returned no answers"
        }
        var lines: [String] = []
        for (id, answer) in answers.sorted(by: { $0.key < $1.key }) {
            lines.append(formatAnswer(id: id, answer: answer))
        }
        if let usage = root.objectValue?["usage"]?.objectValue {
            let input = usage["input_tokens"]?.intValue ?? 0
            let output = usage["output_tokens"]?.intValue ?? 0
            lines.append(AgentUI.dim("   [naluri: \(input)+\(output) tokens]"))
        }
        return lines.joined(separator: "\n")
    }

    private static func formatAnswer(id: String, answer: JSONValue) -> String {
        guard let obj = answer.objectValue else { return "\(id): (unparseable)" }
        let note = obj["uncalibrated"]?.boolValue == true ? " [uncalibrated: no logprobs, a pick not a probability]" : ""
        switch obj["type"]?.stringValue ?? "unknown" {
        case "noul":   return noulLine(id: id, obj) + note
        case "choice": return choiceLine(id: id, obj) + note
        case "score":  return scoreLine(id: id, obj) + note
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
