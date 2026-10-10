import Foundation
import HarnessCore

// `harness --eval-agent` — run the agent on real tasks and grade the outcome.
//   --eval-agent                 run (LIVE: real model calls, real shell tools)
//   --eval-validate              offline: prove every check fails on the seed and passes
//                                with the reference solution (no model, no spend)
//   --eval-cases PATH            default Evals/agent.json
//   --eval-runs N                runs per case (default 1; use 3+ — results are noisy)
//   --eval-parallel N            concurrent runs (default 2)
//   --eval-budget USD            hard stop on ESTIMATED spend (default 1.00)
//   --eval-only id,id            run just these cases
//   --eval-no-config             do not forward ./.simple.h.conf (default: forwarded, so
//                                the agent runs as you run it; --no-gate/--approval never
//                                are always forced)
// Forwarded to every run: --provider --model --reasoning --base-url --config.
enum AgentEvalCommand {
    static func run(arguments: [String]) async {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let path = value("--eval-cases") ?? "Evals/agent.json"
        var cases: [AgentEvalCase]
        do { cases = try AgentEvalCase.load(path: path) } catch {
            print(AgentUI.errorText("cannot load cases from \(path): \(error)"))
            exit(2)
        }
        if let only = value("--eval-only") {
            let wanted = Set(only.split(separator: ",").map(String.init))
            cases = cases.filter { wanted.contains($0.id) }
        }
        guard !cases.isEmpty else { print(AgentUI.errorText("no cases selected")); exit(2) }

        if arguments.contains("--eval-validate") {
            print("validating \(cases.count) cases (offline, no model)…")
            let problems = await AgentEval.validate(cases: cases)
            problems.forEach { print(AgentUI.errorText("  ✗ \($0)")) }
            print(problems.isEmpty ? "all \(cases.count) cases sound" : "\(problems.count) problem(s)")
            exit(problems.isEmpty ? 0 : 1)
        }

        var forwarded: [String] = []
        for flag in ["--provider", "--model", "--reasoning", "--base-url"] {
            if let flagValue = value(flag) { forwarded += [flag, flagValue] }
        }
        let configPath = value("--config")
            ?? (FileManager.default.fileExists(atPath: ".simple.h.conf") ? ".simple.h.conf" : nil)
        if let configPath, !arguments.contains("--eval-no-config") {
            forwarded += ["--config", URL(fileURLWithPath: configPath).standardizedFileURL.path]
        }
        // What the runs will actually use. Without a forwarded config file the
        // child resolves its own defaults, so don't claim the parent's.
        let usesConfig = forwarded.contains("--config")
        let resolved = Config.resolve(arguments: arguments)
        let providerName = value("--provider") ?? (usesConfig ? resolved.provider : "(autodetect)")
        let modelName = value("--model") ?? (usesConfig ? resolved.model : "(provider default)")
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let runs = value("--eval-runs").flatMap(Int.init) ?? 1
        let budget = value("--eval-budget").flatMap(Double.init) ?? 1.0
        let parallel = value("--eval-parallel").flatMap(Int.init) ?? 2

        print("agent eval: \(cases.count) cases × \(runs) run(s), \(providerName) / \(modelName), "
            + "parallel \(parallel), budget cap $\(budget)")
        print(AgentUI.warn("the agent runs REAL shell commands with approvals off — temp dirs are a start "
            + "point, not a sandbox. Only run cases you have reviewed."))
        let report = await AgentEval.run(
            cases: cases, executable: executable, forwardedFlags: forwarded, provider: providerName,
            model: modelName, runsPerCase: runs, parallel: parallel, budgetUSD: budget,
            progress: { print($0) })
        print(AgentEval.table(report))
        for run in report.runs where run.artifactDir != nil {
            print(AgentUI.dim("  kept for debugging: \(run.artifactDir ?? "")  (\(run.caseID) #\(run.run))"))
        }

        let dir = "Evals/results"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let resultPath = "\(dir)/agent-\(report.date.replacingOccurrences(of: ":", with: "-")).json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) { try? data.write(to: URL(fileURLWithPath: resultPath)) }
        print(AgentUI.dim("full per-run results: \(resultPath)"))
    }
}
