import Foundation

// ---------------------------------------------------------------------------
// AgentEval.swift — does the whole agent finish real tasks?
//
// Where NaluriEval grades one classifier answer, this grades OUTCOMES: each
// case seeds a fresh temp directory, runs `harness --once "<task>"` as a real
// subprocess in it (the actual binary, config and tools — no stub), then runs
// a shell `check` in that directory. Exit 0 = pass. Judging the filesystem,
// not the model's prose, keeps grading deterministic and cheap.
//
// Every case ships a reference `solution` too. `validate` proves, WITHOUT any
// model, that the check fails on the untouched files and passes after the
// solution — so a green case can't be vacuous and a red one isn't a broken
// check. That runs under `swift test`; the live run does not.
//
// SAFETY: the agent runs with approvals off and a real `bash` tool; the temp
// directory is where it STARTS, not a sandbox. Only run cases you wrote or
// reviewed, ideally in a container/CI.
//
// SPEND CAP: tokens come from the usage log (UsageLog.swift) × ASSUMED prices
// (conservative, not billing data); no new run starts once the cap is reached.
// ---------------------------------------------------------------------------

public struct AgentEvalCase: Codable, Sendable {
    public var id: String
    public var group: String
    public var task: String
    /// Relative path → contents, written before the run.
    public var files: [String: String]?
    /// Shell command run in the work dir afterwards; exit 0 = pass.
    public var check: String
    /// Reference solution (shell, run in the work dir) — used by `validate` only.
    public var solution: String
    public var timeoutSec: Int?
    public var maxTurns: Int?

    public static func load(path: String) throws -> [AgentEvalCase] {
        try JSONDecoder().decode([AgentEvalCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

public struct AgentEvalRun: Codable, Sendable {
    public var caseID: String
    public var group: String
    public var run: Int
    public var passed: Bool
    /// Exit status of `harness --once` (nonzero = error or turn cap).
    public var harnessExit: Int
    public var timedOut: Bool
    public var turns: Int
    public var toolCalls: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var wallMs: Int
    public var costUSD: Double
    /// Kept (not deleted) for failed runs: workdir + transcript for debugging.
    public var artifactDir: String?
    public var checkOutput: String?
}

public enum AgentEvalSupport {
    /// "exit code: 3 (timed out)\n…" → 3. Missing/garbled → -1.
    public static func exitCode(of report: String) -> Int {
        let first = report.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        guard first.hasPrefix("exit code: ") else { return -1 }
        return Int(first.dropFirst("exit code: ".count).prefix { $0.isNumber || $0 == "-" }) ?? -1
    }

    public static func timedOut(_ report: String) -> Bool {
        (report.split(separator: "\n").first.map(String.init) ?? "").contains("(timed out)")
    }

    /// Write a case's seed files under `directory`.
    public static func setUp(_ testCase: AgentEvalCase, in directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (path, contents) in testCase.files ?? [:] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// POSIX single-quote escaping for embedding a value in a shell command.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Assistant tool calls in a JSONL session log (the transcript).
    public static func toolCallCount(sessionLogPath: String) -> Int {
        guard let text = try? String(contentsOfFile: sessionLogPath, encoding: .utf8) else { return 0 }
        var count = 0
        for line in text.split(separator: "\n") {
            guard let event = JSONValue.parse(String(line))?.objectValue,
                  let message = event["message"]?.objectValue,
                  message["role"]?.stringValue == "assistant" else { continue }
            count += message["tool_calls"]?.arrayValue?.count ?? 0
        }
        return count
    }
}

/// ASSUMED prices (USD per million tokens), deliberately on the high side.
public enum AgentEvalPricing {
    public static func perMillion(provider: String) -> (input: Double, output: Double) {
        switch provider {
        case "deepseek": return (0.30, 0.60)
        case "zai", "zai-coding", "zai-coding-cn": return (0.60, 2.20)
        case "ollama": return (0, 0)
        case "openai": return (2.50, 10.0)
        default: return (3.00, 15.00)  // anthropic / openrouter / unknown
        }
    }

    public static func cost(provider: String, input: Int, output: Int) -> Double {
        let price = perMillion(provider: provider)
        return (Double(input) * price.input + Double(output) * price.output) / 1_000_000
    }
}

public struct AgentEvalCaseSummary: Codable, Sendable {
    public var caseID: String
    public var group: String
    public var runs: Int
    public var passes: Int
    public var meanTurns: Double
    public var meanToolCalls: Double
    public var meanTokens: Int
    public var meanSeconds: Double
}

public struct AgentEvalReport: Codable, Sendable {
    public var date: String
    public var provider: String
    public var model: String
    public var runsPerCase: Int
    public var budgetUSD: Double
    public var totalCostUSD: Double
    public var skippedRuns: Int
    public var cases: [AgentEvalCaseSummary]
    public var runs: [AgentEvalRun]
}

public enum AgentEval {
    // MARK: validation (offline — no model)

    /// Problems found, empty when every case is sound: its check FAILS on the
    /// untouched seed and PASSES after the reference solution.
    public static func validate(cases: [AgentEvalCase]) async -> [String] {
        var problems: [String] = []
        var seen = Set<String>()
        for testCase in cases {
            if !seen.insert(testCase.id).inserted { problems.append("\(testCase.id): duplicate id") }
            let root = NSTemporaryDirectory() + "harness-agent-validate-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: root) }
            do { try AgentEvalSupport.setUp(testCase, in: root) } catch {
                problems.append("\(testCase.id): cannot seed files (\(error))")
                continue
            }
            let before = await ShellRunner.run(command: testCase.check, cwd: root, timeout: 60)
            if AgentEvalSupport.exitCode(of: before) == 0 {
                problems.append("\(testCase.id): check already PASSES on the untouched files (vacuous)")
            }
            _ = await ShellRunner.run(command: testCase.solution, cwd: root, timeout: 60)
            let after = await ShellRunner.run(command: testCase.check, cwd: root, timeout: 60)
            if AgentEvalSupport.exitCode(of: after) != 0 {
                problems.append("\(testCase.id): check still FAILS after the reference solution — \(after.prefix(200))")
            }
        }
        return problems
    }

    // MARK: live run

    /// `executable` is the harness binary; `forwardedFlags` (provider/model/
    /// config…) are appended to every `--once` invocation.
    public static func run(
        cases: [AgentEvalCase], executable: String, forwardedFlags: [String], provider: String,
        model: String, runsPerCase: Int, parallel: Int, budgetUSD: Double, progress: @Sendable (String) -> Void
    ) async -> AgentEvalReport {
        let jobs = cases.flatMap { testCase in (1...max(1, runsPerCase)).map { (testCase, $0) } }
        let scratch = NSTemporaryDirectory() + "harness-agent-eval-\(UUID().uuidString)"
        var results: [AgentEvalRun] = []
        var spent = 0.0
        var index = 0
        while index < jobs.count, spent < budgetUSD {
            let chunk = Array(jobs[index..<min(index + max(1, parallel), jobs.count)])
            index += chunk.count
            let finished = await withTaskGroup(of: AgentEvalRun.self) { group in
                for (testCase, runNumber) in chunk {
                    group.addTask {
                        await execute(testCase, run: runNumber, scratch: scratch, executable: executable,
                                      forwardedFlags: forwardedFlags, provider: provider)
                    }
                }
                var collected: [AgentEvalRun] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for result in finished {
                spent += result.costUSD
                progress("  \(result.passed ? "✓" : "✗") \(result.caseID) #\(result.run)  "
                    + "\(result.turns) turns, \(result.inputTokens + result.outputTokens) tok, \(result.wallMs / 1000)s")
            }
            results += finished
        }
        // Passes leave nothing behind; failures keep their dirs for debugging.
        if !results.contains(where: { $0.artifactDir != nil }) { try? FileManager.default.removeItem(atPath: scratch) }
        results.sort { ($0.caseID, $0.run) < ($1.caseID, $1.run) }
        return AgentEvalReport(
            date: ISO8601DateFormatter().string(from: Date()), provider: provider, model: model,
            runsPerCase: runsPerCase, budgetUSD: budgetUSD, totalCostUSD: spent,
            skippedRuns: jobs.count - results.count, cases: summarize(results), runs: results)
    }

    private static func execute(
        _ testCase: AgentEvalCase, run runNumber: Int, scratch: String, executable: String,
        forwardedFlags: [String], provider: String
    ) async -> AgentEvalRun {
        let root = "\(scratch)/\(testCase.id)-\(runNumber)"
        let work = root + "/work"
        let meta = root + "/meta"
        var result = AgentEvalRun(
            caseID: testCase.id, group: testCase.group, run: runNumber, passed: false, harnessExit: -1,
            timedOut: false, turns: 0, toolCalls: 0, inputTokens: 0, outputTokens: 0, wallMs: 0,
            costUSD: 0, artifactDir: nil, checkOutput: nil)
        do {
            try AgentEvalSupport.setUp(testCase, in: work)
            try FileManager.default.createDirectory(atPath: meta, withIntermediateDirectories: true)
            try testCase.task.write(toFile: meta + "/task.txt", atomically: true, encoding: .utf8)
        } catch {
            result.checkOutput = "setup failed: \(error)"
            result.artifactDir = root
            return result
        }
        let usagePath = meta + "/usage.jsonl"
        let transcript = meta + "/transcript.jsonl"
        let q = AgentEvalSupport.shellQuote
        let command = "HARNESS_USAGE_LOG=\(q(usagePath)) \(q(executable)) --once \"$(cat \(q(meta + "/task.txt")))\""
            + " --no-gate --approval never --no-streaming --session-log \(q(transcript))"
            + " --max-turns \(testCase.maxTurns ?? 25) " + forwardedFlags.map(q).joined(separator: " ")

        let started = Date()
        let report = await ShellRunner.run(command: command, cwd: work, timeout: Double(testCase.timeoutSec ?? 300))
        result.wallMs = Int(Date().timeIntervalSince(started) * 1000)
        result.harnessExit = AgentEvalSupport.exitCode(of: report)
        result.timedOut = AgentEvalSupport.timedOut(report)

        let totals = UsageLog.totals(path: usagePath)
        result.turns = totals.turns
        result.inputTokens = totals.prompt
        result.outputTokens = totals.completion
        result.toolCalls = AgentEvalSupport.toolCallCount(sessionLogPath: transcript)
        result.costUSD = AgentEvalPricing.cost(provider: provider, input: totals.prompt, output: totals.completion)

        let check = await ShellRunner.run(command: testCase.check, cwd: work, timeout: 60)
        result.passed = AgentEvalSupport.exitCode(of: check) == 0
        if !result.passed {
            result.checkOutput = String(check.prefix(400))
            result.artifactDir = root
            try? report.write(toFile: meta + "/stdout.txt", atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: root)
        }
        return result
    }

    // MARK: reporting

    public static func summarize(_ runs: [AgentEvalRun]) -> [AgentEvalCaseSummary] {
        var order: [String] = []
        var byCase: [String: [AgentEvalRun]] = [:]
        for run in runs {
            if byCase[run.caseID] == nil { order.append(run.caseID) }
            byCase[run.caseID, default: []].append(run)
        }
        return order.map { id in
            let group = byCase[id] ?? []
            let count = Double(group.count)
            return AgentEvalCaseSummary(
                caseID: id, group: group.first?.group ?? "", runs: group.count,
                passes: group.filter(\.passed).count,
                meanTurns: Double(group.map(\.turns).reduce(0, +)) / count,
                meanToolCalls: Double(group.map(\.toolCalls).reduce(0, +)) / count,
                meanTokens: group.map { $0.inputTokens + $0.outputTokens }.reduce(0, +) / group.count,
                meanSeconds: Double(group.map(\.wallMs).reduce(0, +)) / count / 1000)
        }
    }

    public static func table(_ report: AgentEvalReport) -> String {
        var lines = ["case                      group       pass   turns  tools  tokens   sec"]
        for item in report.cases {
            lines.append(item.caseID.padding(toLength: 25, withPad: " ", startingAt: 0) + " "
                + item.group.padding(toLength: 11, withPad: " ", startingAt: 0) + " "
                + "\(item.passes)/\(item.runs)".padding(toLength: 6, withPad: " ", startingAt: 0) + " "
                + String(format: "%-6.1f %-6.1f %-8d %.0f", item.meanTurns, item.meanToolCalls,
                         item.meanTokens, item.meanSeconds))
        }
        let total = report.runs.count
        let passed = report.runs.filter(\.passed).count
        var byGroup: [String: (Int, Int)] = [:]
        for run in report.runs { byGroup[run.group, default: (0, 0)].1 += 1; if run.passed { byGroup[run.group]!.0 += 1 } }
        let groups = byGroup.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.0)/\($0.value.1)" }.joined(separator: ", ")
        lines.append("pass rate: \(passed)/\(total)" + (total > 0 ? String(format: " (%.0f%%)", Double(passed) / Double(total) * 100) : "")
            + "  —  \(groups)")
        let timeouts = report.runs.filter(\.timedOut).count
        let capped = report.runs.filter { !$0.passed && $0.harnessExit != 0 && !$0.timedOut }.count
        lines.append("failed runs that timed out: \(timeouts); ended with a harness error/turn cap: \(capped)"
            + (report.skippedRuns > 0 ? "; \(report.skippedRuns) runs skipped (budget)" : ""))
        lines.append(String(format: "total est. cost $%.4f of $%.2f cap (assumed prices, not billed)  —  %@ / %@",
                            report.totalCostUSD, report.budgetUSD, report.provider, report.model))
        return lines.joined(separator: "\n")
    }
}
