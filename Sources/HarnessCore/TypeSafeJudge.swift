import Foundation

// ---------------------------------------------------------------------------
// TypeSafeJudge.swift — the `judge` tool.
//
// Split out of Tools.swift: the enum there outgrew its lint budget, and this
// tool COHESIVELY pairs with TypeSafe.swift (the wire contract it calls).
// Registered in Tools.all as TypeSafeJudge.tool.
//
// A DIFFERENT primitive than the chat loop: Jev answers typed questions
// about a state with calibrated probabilities, not prose. Use when a
// decision wants a number or a selection with confidence — urgency,
// routing, classification, severity — instead of generated text. The
// request/response contract is in TypeSafe.swift; failures are text.
// ---------------------------------------------------------------------------

enum TypeSafeJudge {
    static let tool = ToolSpec(
        name: "judge",
        description: "Ask TypeSafe's System One model (Jev) for typed judgments with probabilities, " +
                     "not prose. One call answers several questions against the same text: " +
                     "noul = yes/no probability, choice = pick one option (returns distribution + confidence), " +
                     "score = rate on a rubric (2-10 levels). Use when a calibrated number or selection " +
                     "is more useful than generated text — urgency, routing, classification, severity.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "state": .object([
                    "type": .string("string"),
                    "description": .string("The text to evaluate (email, log, document, chat transcript)"),
                ]),
                "questions": .object([
                    "type": .string("array"),
                    "description": .string("1-8 typed questions, all judged against the same state"),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "id": .object([
                                "type": .string("string"),
                                "description": .string("Name you choose; the answer is returned under it"),
                            ]),
                            "type": .object([
                                "type": .string("string"),
                                "description": .string("noul (yes/no) | choice (pick one) | score (rate on levels)"),
                            ]),
                            "question": .object([
                                "type": .string("string"),
                                "description": .string("What to judge about the state"),
                            ]),
                            "true_means": .object([
                                "type": .string("string"),
                                "description": .string("noul only: what YES means (optional)"),
                            ]),
                            "false_means": .object([
                                "type": .string("string"),
                                "description": .string("noul only: what NO means (optional)"),
                            ]),
                            "options": .object([
                                "type": .string("object"),
                                "description": .string("choice only: map of option -> description (max 255)"),
                            ]),
                            "levels": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                                "description": .string("score only: ordered level descriptions (2-10)"),
                            ]),
                        ]),
                        "required": .array([.string("id"), .string("type"), .string("question")]),
                    ]),
                ]),
            ]),
            "required": .array([.string("state"), .string("questions")]),
        ])
    ) { arguments, context in
        guard let state = arguments["state"]?.stringValue, !state.isEmpty else {
            return "error: 'state' (string) is required"
        }
        guard let questionArgs = arguments["questions"]?.arrayValue, !questionArgs.isEmpty else {
            return "error: 'questions' (array) is required"
        }
        var questions: [TypeSafeQuestion] = []
        for (index, raw) in questionArgs.enumerated() {
            guard let spec = raw.objectValue, let id = spec["id"]?.stringValue,
                  let type = spec["type"]?.stringValue,
                  let question = spec["question"]?.stringValue else {
                return "error: questions[\(index)] needs id, type and question (strings)"
            }
            switch type {
            case "noul":
                var criteria: [String: JSONValue] = [:]
                if let yes = spec["true_means"]?.stringValue { criteria["true"] = .string(yes) }
                if let no = spec["false_means"]?.stringValue { criteria["false"] = .string(no) }
                questions.append(TypeSafeQuestion(
                    id: id, type: "noul", instructions: question,
                    criteria: criteria.isEmpty ? nil : .object(criteria)))
            case "choice":
                guard let options = spec["options"]?.objectValue else {
                    return "error: choice question '\(id)' needs 'options' (map of option -> description)"
                }
                questions.append(TypeSafeQuestion(
                    id: id, type: "choice", instructions: question, criteria: .object(options)))
            case "score":
                guard let levels = spec["levels"]?.arrayValue else {
                    return "error: score question '\(id)' needs 'levels' (ordered array of descriptions)"
                }
                questions.append(TypeSafeQuestion(
                    id: id, type: "score", instructions: question, criteria: .array(levels)))
            default:
                return "error: unknown type '\(type)' in '\(id)' (use noul, choice or score)"
            }
        }
        guard let apiKey = context.config.typesafeApiKey else {
            return "error: TYPESAFE_API_KEY is not set — judge cannot reach TypeSafe"
        }
        do {
            let root = try await TypeSafeClient.evaluate(
                state: String(state.prefix(50_000)), questions: questions, apiKey: apiKey)
            return TypeSafeClient.format(root)
        } catch {
            return "error: TypeSafe call failed — \(error)"
        }
    }
}
