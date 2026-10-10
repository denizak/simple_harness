import Foundation

// ---------------------------------------------------------------------------
// Gate.swift — a pre-model decision step, the in-loop sibling of Compaction.
//
// Where Compaction runs before EVERY model call, the gate runs once per user
// TASK (in Agent.run, before the user message is even appended): naluri
// answers one calibrated yes/no question about the request — "is
// this harmless?" — and a probability below config.gateThreshold (i.e. likely
// harmful) rejects it before any chat-model tokens are spent. The model never
// sees a rejected request. It is a SAFETY filter only: ordinary requests,
// relevant or not, should pass.
//
// FAIL-OPEN by design: a missing key, a network error, an unparseable answer
// — any of those lets the request through with a warning. A third-party
// classifier outage must not take the agent down; the gate is a cheap filter,
// not a dependency. (Same philosophy as the naluri tool: errors are text.)
//
// Opt-in via HARNESS_GATE=1 and a naluri backend key (TYPESAFE_API_KEY). Threshold via
// HARNESS_GATE_THRESHOLD (0..<1, default 0.5).
// ---------------------------------------------------------------------------

public enum ModelGate {
    /// The single question the gate asks, as wire-ready criteria: a SAFETY
    /// judgment only, not relevance or legitimacy — anything not clearly
    /// harmful should pass.
    static let question = NaluriQuestion(
        id: "harmless",
        type: "noul",
        instructions: "Is this user request harmless — safe for a coding agent to act on?",
        criteria: .object([
            "true": .string("An ordinary, legitimate request with no intent to harm"),
            "false": .string("Malicious or dangerous: malware, attacks, data theft, destruction, or clearly abusive content"),
        ]))

    /// Pure decision rule — unit-tested without network or key.
    /// Returns the rejection reason when the gate blocks, nil to proceed.
    public static func decide(noulProbability: Double, threshold: Double) -> String? {
        noulProbability < threshold
            ? String(format: "harmless probability %.2f is below threshold %.2f (likely harmful)",
                     noulProbability, threshold)
            : nil
    }

    /// The pre-model check. Returns a rejection reason to block the task,
    /// nil to proceed — including every failure path (fail-open).
    public static func check(input: String, config: Config) async -> String? {
        guard config.gateEnabled else { return nil }
        guard let backend = config.naluriBackend else {
            print(AgentUI.warn("gate enabled but \(config.naluriSetupHint) — proceeding without it"))
            return nil
        }
        do {
            let state = String(input.prefix(50_000))
            let request = TypeSafeClient.request(state: state, questions: [question])
            if let pretty = try? JSONEncoder().encode(request), let text = String(data: pretty, encoding: .utf8) {
                print(AgentUI.dim("   [gate →] \(text)"))
            }
            let root = try await backend.evaluate(state: state, questions: [question])
            if let pretty = try? JSONEncoder().encode(root), let text = String(data: pretty, encoding: .utf8) {
                print(AgentUI.dim("   [gate ←] \(text)"))
            }
            guard let probability = root.objectValue?["answers"]?
                .objectValue?[question.id]?.objectValue?["noul"]?.doubleValue else {
                print(AgentUI.warn("gate answer unparseable — proceeding"))
                return nil
            }
            let percent = Int((probability * 100).rounded())
            print(AgentUI.dim("   [gate: harmless \(percent)%]"))
            return decide(noulProbability: probability, threshold: config.gateThreshold)
        } catch {
            print(AgentUI.warn("gate check failed (\(error)) — proceeding (fail-open)"))
            return nil
        }
    }
}
