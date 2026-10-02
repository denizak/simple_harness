import Foundation

// ---------------------------------------------------------------------------
// Gate.swift — a pre-model decision step, the in-loop sibling of Compaction.
//
// Where Compaction runs before EVERY model call, the gate runs once per user
// TASK (in Agent.run, before the user message is even appended): TypeSafe's
// System One answers one calibrated yes/no question about the request, and a
// probability below config.gateThreshold rejects it before any chat-model
// tokens are spent. The model never sees a rejected request.
//
// FAIL-OPEN by design: a missing key, a network error, an unparseable answer
// — any of those lets the request through with a warning. A third-party
// classifier outage must not take the agent down; the gate is a cheap filter,
// not a dependency. (Same philosophy as the judge tool: errors are text.)
//
// Opt-in via HARNESS_GATE=1 and TYPESAFE_API_KEY. Threshold via
// HARNESS_GATE_THRESHOLD (0..<1, default 0.5).
// ---------------------------------------------------------------------------

public enum ModelGate {
    /// The single question the gate asks, as wire-ready criteria.
    static let question = TypeSafeQuestion(
        id: "proceed",
        type: "noul",
        instructions: "Should an autonomous coding agent act on this user request?",
        criteria: .object([
            "true": .string("A legitimate software/engineering task it can help with"),
            "false": .string("Not an actionable engineering task, or acting on it would be harmful"),
        ]))

    /// Pure decision rule — unit-tested without network or key.
    /// Returns the rejection reason when the gate blocks, nil to proceed.
    public static func decide(noulProbability: Double, threshold: Double) -> String? {
        noulProbability < threshold
            ? String(format: "proceed probability %.2f is below threshold %.2f", noulProbability, threshold)
            : nil
    }

    /// The pre-model check. Returns a rejection reason to block the task,
    /// nil to proceed — including every failure path (fail-open).
    public static func check(input: String, config: Config) async -> String? {
        guard config.gateEnabled else { return nil }
        guard let apiKey = config.typesafeApiKey else {
            print(AgentUI.warn("gate enabled but TYPESAFE_API_KEY is not set — proceeding without it"))
            return nil
        }
        do {
            let root = try await TypeSafeClient.evaluate(
                state: String(input.prefix(50_000)), questions: [question], apiKey: apiKey)
            guard let probability = root.objectValue?["answers"]?
                .objectValue?["proceed"]?.objectValue?["noul"]?.doubleValue else {
                print(AgentUI.warn("gate answer unparseable — proceeding"))
                return nil
            }
            let percent = Int((probability * 100).rounded())
            print(AgentUI.dim("   [gate: proceed \(percent)%]"))
            return decide(noulProbability: probability, threshold: config.gateThreshold)
        } catch {
            print(AgentUI.warn("gate check failed (\(error)) — proceeding (fail-open)"))
            return nil
        }
    }
}
