import Foundation

// ---------------------------------------------------------------------------
// NaluriEval.swift — measure naluri backends on a labelled case set.
//
// Question answered: for the same cases, how accurate and how well calibrated
// are TypeSafe (Jev), deepseek-flash and glm-flash — and at what cost/latency?
//
// Each case is ONE typed question against one text with a known expected
// answer. A backend answers through the shared NaluriBackend contract, so the
// scoring below never knows which vendor it is judging.
//
// SPEND CAP: the run tracks an ESTIMATED dollar cost from reported token usage
// × the assumed per-million prices below (deliberately on the high side) and
// stops issuing calls once the budget is reached; remaining cases are marked
// skipped. A naluri call is ~300 tokens, so the full 40-case set across three
// backends costs a few cents — the cap is a seat belt, not a constraint.
// ---------------------------------------------------------------------------

public struct NaluriEvalCase: Codable, Sendable {
    public var id: String
    public var group: String
    public var state: String
    public var type: String
    public var instructions: String
    public var criteria: JSONValue?
    /// noul: "yes"/"no" · choice: option name · score: 0-based level index
    public var expected: String

    public var question: NaluriQuestion {
        NaluriQuestion(id: id, type: type, instructions: instructions, criteria: criteria)
    }

    public static func load(path: String) throws -> [NaluriEvalCase] {
        try JSONDecoder().decode([NaluriEvalCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

/// How one case came out.
public struct NaluriEvalResult: Codable, Sendable {
    public var caseID: String
    public var group: String
    public var predicted: String?
    public var expected: String
    public var correct: Bool
    /// Probability the backend put on its own pick (nil on error/skip).
    public var confidence: Double?
    /// Brier score over the answer classes (nil for score questions / errors).
    public var brier: Double?
    /// Score questions only: |predicted level − expected level| ≤ 1.
    public var withinOne: Bool?
    public var uncalibrated: Bool
    public var latencyMs: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var error: String?
    public var skipped: Bool
}

public enum NaluriEvalScoring {
    /// Pure: grade one backend answer (the shared answer shape) against a case.
    public static func grade(_ testCase: NaluriEvalCase, root: JSONValue) -> NaluriEvalResult {
        var result = NaluriEvalResult(
            caseID: testCase.id, group: testCase.group, predicted: nil, expected: testCase.expected,
            correct: false, confidence: nil, brier: nil, withinOne: nil, uncalibrated: false,
            latencyMs: 0, inputTokens: 0, outputTokens: 0, error: nil, skipped: false)
        let usage = root.objectValue?["usage"]?.objectValue
        result.inputTokens = usage?["input_tokens"]?.intValue ?? 0
        result.outputTokens = usage?["output_tokens"]?.intValue ?? 0
        guard let answer = root.objectValue?["answers"]?.objectValue?[testCase.id]?.objectValue else {
            result.error = "no answer for case"
            return result
        }
        result.uncalibrated = answer["uncalibrated"]?.boolValue == true
        switch testCase.type {
        case "noul": gradeNoul(testCase, answer, into: &result)
        case "choice": gradeChoice(testCase, answer, into: &result)
        case "score": gradeScore(testCase, answer, into: &result)
        default: result.error = "unknown type \(testCase.type)"
        }
        return result
    }

    private static func gradeNoul(_ testCase: NaluriEvalCase, _ answer: [String: JSONValue],
                                  into result: inout NaluriEvalResult) {
        guard let pYes = answer["noul"]?.doubleValue else { result.error = "no noul value"; return }
        let predictedYes = pYes >= 0.5
        result.predicted = predictedYes ? "yes" : "no"
        result.correct = result.predicted == testCase.expected
        result.confidence = max(pYes, 1 - pYes)
        let yesTruth = testCase.expected == "yes" ? 1.0 : 0.0
        result.brier = pow(pYes - yesTruth, 2) + pow((1 - pYes) - (1 - yesTruth), 2)
    }

    private static func gradeChoice(_ testCase: NaluriEvalCase, _ answer: [String: JSONValue],
                                    into result: inout NaluriEvalResult) {
        guard let picked = answer["choice"]?.stringValue else { result.error = "no choice value"; return }
        result.predicted = picked
        result.correct = picked == testCase.expected
        let probabilities = answer["probabilities"]?.objectValue?.compactMapValues { $0.doubleValue } ?? [:]
        result.confidence = probabilities[picked] ?? answer["confidence"]?.doubleValue
        let options = testCase.criteria?.objectValue?.keys.sorted() ?? []
        result.brier = options.reduce(0.0) { sum, option in
            sum + pow((probabilities[option] ?? 0) - (option == testCase.expected ? 1 : 0), 2)
        }
    }

    private static func gradeScore(_ testCase: NaluriEvalCase, _ answer: [String: JSONValue],
                                   into result: inout NaluriEvalResult) {
        guard let score = answer["score"]?.doubleValue, let expectedIndex = Int(testCase.expected) else {
            result.error = "no score value"
            return
        }
        // The legend's keys name the backend's own level numbering (0- or
        // 1-based); map our 0-based expected index through it.
        let keys = (answer["legend"]?.objectValue?.keys.compactMap { Int($0) } ?? []).sorted()
        let offset = keys.first ?? 0
        let predictedIndex = Int(score.rounded()) - offset
        result.predicted = String(predictedIndex)
        result.correct = predictedIndex == expectedIndex
        result.withinOne = abs(predictedIndex - expectedIndex) <= 1
        result.confidence = answer["confidence"]?.doubleValue
    }
}

/// Aggregate over one backend's results.
public struct NaluriEvalSummary: Codable, Sendable {
    public var backend: String
    public var model: String
    public var graded: Int
    public var correct: Int
    public var errors: Int
    public var skipped: Int
    public var accuracy: Double
    public var meanBrier: Double?
    /// mean confidence − accuracy over graded cases: > 0 = overconfident.
    public var overconfidence: Double?
    public var meanConfidenceWhenWrong: Double?
    public var uncalibrated: Int
    public var meanLatencyMs: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var estimatedCostUSD: Double
    public var accuracyByGroup: [String: Double]

    public static func summarize(backend: String, model: String, results: [NaluriEvalResult],
                                 costUSD: Double) -> NaluriEvalSummary {
        let ran = results.filter { !$0.skipped }
        let graded = ran.filter { $0.error == nil }
        let correct = graded.filter(\.correct).count
        let accuracy = graded.isEmpty ? 0 : Double(correct) / Double(graded.count)
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        let confidences = graded.compactMap(\.confidence)
        var groups: [String: Double] = [:]
        for group in Set(graded.map(\.group)) {
            let inGroup = graded.filter { $0.group == group }
            groups[group] = Double(inGroup.filter(\.correct).count) / Double(inGroup.count)
        }
        return NaluriEvalSummary(
            backend: backend, model: model, graded: graded.count, correct: correct,
            errors: ran.count - graded.count, skipped: results.count - ran.count, accuracy: accuracy,
            meanBrier: mean(graded.compactMap(\.brier)),
            overconfidence: mean(confidences).map { $0 - accuracy },
            meanConfidenceWhenWrong: mean(graded.filter { !$0.correct }.compactMap(\.confidence)),
            uncalibrated: graded.filter(\.uncalibrated).count,
            meanLatencyMs: ran.isEmpty ? 0 : ran.map(\.latencyMs).reduce(0, +) / ran.count,
            inputTokens: ran.map(\.inputTokens).reduce(0, +),
            outputTokens: ran.map(\.outputTokens).reduce(0, +),
            estimatedCostUSD: costUSD, accuracyByGroup: groups)
    }
}

/// ASSUMED prices, USD per million tokens (input, output). Deliberately
/// conservative so the cap trips early rather than late; not billing data.
public enum NaluriEvalPricing {
    public static func perMillion(backend: String) -> (input: Double, output: Double) {
        switch backend {
        case "deepseek": return (0.30, 0.60)
        case "zai": return (0.30, 0.60)
        default: return (1.00, 3.00)  // typesafe: unknown, assume mid-priced
        }
    }

    public static func cost(backend: String, input: Int, output: Int) -> Double {
        let price = perMillion(backend: backend)
        return (Double(input) * price.input + Double(output) * price.output) / 1_000_000
    }
}

public struct NaluriEvalReport: Codable, Sendable {
    public var date: String
    public var budgetUSD: Double
    public var totalCostUSD: Double
    public var summaries: [NaluriEvalSummary]
    public var results: [String: [NaluriEvalResult]]
}

public enum NaluriEval {
    /// Run every case against each named backend, stopping at the budget.
    public static func run(
        cases: [NaluriEvalCase], backendNames: [String], budgetUSD: Double
    ) async -> (report: NaluriEvalReport, skippedBackends: [String]) {
        var spent = 0.0
        var summaries: [NaluriEvalSummary] = []
        var allResults: [String: [NaluriEvalResult]] = [:]
        var skippedBackends: [String] = []

        for name in backendNames {
            guard let (backend, model) = makeBackend(named: name) else {
                skippedBackends.append(name)
                continue
            }
            var results: [NaluriEvalResult] = []
            var backendCost = 0.0
            for testCase in cases {
                if spent >= budgetUSD {
                    var skipped = NaluriEvalScoring.grade(testCase, root: .null)
                    skipped.skipped = true
                    skipped.error = nil
                    results.append(skipped)
                    continue
                }
                let started = Date()
                var result: NaluriEvalResult
                do {
                    let root = try await backend.evaluate(state: testCase.state, questions: [testCase.question])
                    result = NaluriEvalScoring.grade(testCase, root: root)
                } catch {
                    result = NaluriEvalScoring.grade(testCase, root: .null)
                    result.error = String(describing: error).prefix(160).description
                }
                result.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
                let cost = NaluriEvalPricing.cost(
                    backend: name, input: result.inputTokens, output: result.outputTokens)
                backendCost += cost
                spent += cost
                results.append(result)
            }
            summaries.append(.summarize(backend: name, model: model, results: results, costUSD: backendCost))
            allResults[name] = results
        }
        let report = NaluriEvalReport(
            date: ISO8601DateFormatter().string(from: Date()), budgetUSD: budgetUSD,
            totalCostUSD: spent, summaries: summaries, results: allResults)
        return (report, skippedBackends)
    }

    /// Resolve a backend by name using the normal config path (env keys,
    /// --provider key borrowing). nil when no credentials are available.
    static func makeBackend(named name: String) -> (NaluriBackend, String)? {
        var config = Config.resolve(arguments: name == "typesafe" ? [] : ["--provider", name])
        config.naluriBackendName = name
        guard let backend = config.naluriBackend else { return nil }
        let model = (backend as? ChatNaluri)?.model ?? "jev-latest"
        return (backend, model)
    }

    /// Fixed-width comparison table for the terminal.
    public static func table(_ report: NaluriEvalReport) -> String {
        func pct(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "–" }
        func num(_ value: Double?, _ places: Int = 3) -> String {
            value.map { String(format: "%.\(places)f", $0) } ?? "–"
        }
        var lines = ["backend     model             acc    brier  overconf  conf@wrong  uncal  err  ms     $est"]
        for s in report.summaries {
            let name = s.backend.padding(toLength: 11, withPad: " ", startingAt: 0)
            let model = s.model.padding(toLength: 17, withPad: " ", startingAt: 0)
            lines.append("\(name) \(model) \(pct(s.accuracy).padding(toLength: 6, withPad: " ", startingAt: 0))"
                + "\(num(s.meanBrier).padding(toLength: 7, withPad: " ", startingAt: 0))"
                + "\(num(s.overconfidence, 2).padding(toLength: 10, withPad: " ", startingAt: 0))"
                + "\(num(s.meanConfidenceWhenWrong, 2).padding(toLength: 12, withPad: " ", startingAt: 0))"
                + "\(String(s.uncalibrated).padding(toLength: 7, withPad: " ", startingAt: 0))"
                + "\(String(s.errors).padding(toLength: 5, withPad: " ", startingAt: 0))"
                + "\(String(s.meanLatencyMs).padding(toLength: 7, withPad: " ", startingAt: 0))"
                + String(format: "%.4f", s.estimatedCostUSD))
            let groups = s.accuracyByGroup.sorted { $0.key < $1.key }
                .map { "\($0.key) \(pct($0.value))" }.joined(separator: ", ")
            lines.append("            by group: \(groups)"
                + (s.skipped > 0 ? "  [\(s.skipped) skipped: budget]" : ""))
        }
        lines.append(String(format: "total est. cost $%.4f of $%.2f cap (prices are assumed, not billed)",
                            report.totalCostUSD, report.budgetUSD))
        return lines.joined(separator: "\n")
    }
}
