import Foundation
import HarnessCore

// `harness --eval-naluri [backends]` — compare naluri backends on Evals/naluri.json.
//   --eval-naluri typesafe,deepseek,zai   (default: all three; backends without a key are skipped)
//   --eval-cases PATH                     (default Evals/naluri.json)
//   --eval-budget USD                     (default 1.00 — hard stop, estimated spend)
//   --eval-limit N                        (first N cases only, for a cheap smoke run)
// Live network calls: costs real quota, so it is never part of `swift test`.
enum EvalCommand {
    static func run(arguments: [String]) async {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        var backends = ["typesafe", "deepseek", "zai"]
        if let list = value("--eval-naluri"), !list.hasPrefix("--") {
            backends = list.split(separator: ",").map { $0.lowercased() }
        }
        let budget = value("--eval-budget").flatMap(Double.init) ?? 1.0
        let casesPath = value("--eval-cases") ?? "Evals/naluri.json"
        var cases: [NaluriEvalCase]
        do { cases = try NaluriEvalCase.load(path: casesPath) } catch {
            print(AgentUI.errorText("cannot load cases from \(casesPath): \(error)"))
            exit(2)
        }
        if let limit = value("--eval-limit").flatMap(Int.init), limit > 0 { cases = Array(cases.prefix(limit)) }

        print("naluri eval: \(cases.count) cases × \(backends.joined(separator: ", ")) — budget cap $\(budget)")
        let (report, skipped) = await NaluriEval.run(cases: cases, backendNames: backends, budgetUSD: budget)
        for name in skipped { print(AgentUI.warn("skipped \(name): no credentials found")) }
        guard !report.summaries.isEmpty else {
            print(AgentUI.errorText("no backend had credentials — set TYPESAFE_API_KEY / DEEPSEEK_API_KEY / ZAI_API_KEY"))
            exit(1)
        }
        print(NaluriEval.table(report))

        let dir = "Evals/results"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stamp = report.date.replacingOccurrences(of: ":", with: "-")
        let path = "\(dir)/naluri-\(stamp).json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) { try? data.write(to: URL(fileURLWithPath: path)) }
        print(AgentUI.dim("full per-case results: \(path)"))
    }
}
