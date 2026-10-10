import Foundation

// ---------------------------------------------------------------------------
// Approval.swift — the tool-approval gate (README "Where to go next" #2).
//
// The pre-model ModelGate judges whole *tasks* before any model call; nothing
// stood between a model's decision and a destructive tool run. This gate is
// that missing authority: one optional human y/n/a decision inserted at the
// single execution choke point (Agent.execute, after argument parsing and
// before tool.run) — the same "errors are text" seam the rest of the loop
// uses, so a denial is just another tool result the model can read and adapt
// to on its next turn.
//
// Fail-closed, deliberately the opposite of the classifier gate's fail-open:
// an unreachable classifier is an outage (keep going), an unreachable human
// is not consent (deny). Policy `never` — the default — skips every check
// below, so current behavior and all existing tests are unchanged.
//
// Ownership: the *policy* lives in Config (resolved from env/flag like
// HARNESS_GATE); the *decider* is injected per agent as `approvalHook` —
// a nil decider under a demanding policy must deny, never execute. The
// task-scoped "always allow" bookkeeping travels in the same shared actor so
// a parent's approval covers the sub-agents it spawns (see ToolContext).
// ---------------------------------------------------------------------------

/// Which tools need a human yes before running.
///   never     — current behavior; nothing is gated (default).
///   dangerous — the mutating/executing set: bash, write_file, edit_file.
///               (grep, read_file, naluri, spawn_agent are read-only or
///               delegation: they cannot change the world, so no prompt.)
///   all       — every tool call is gated.
public enum ApprovalPolicy: String, Sendable, CaseIterable {
    case never
    case dangerous
    case all

    /// Resolve from text ("never" | "dangerous" | "all"); nil when unknown.
    public static func parse(_ text: String) -> ApprovalPolicy? {
        ApprovalPolicy(rawValue: text.lowercased())
    }

    /// The one pure rule: does this call need to be asked about first?
    /// Unit-testable without I/O; `alreadyApproved` carries the task-scoped
    /// "always allow" state so a remembered tool skips the prompt.
    public func requiresApproval(tool name: String, alreadyApproved: Bool) -> Bool {
        if self == .never || alreadyApproved { return false }
        switch self {
        case .all: return true
        case .dangerous: return Self.dangerousTools.contains(name)
        case .never: return false  // unreachable; keeps the switch exhaustive
        }
    }

    /// The mutating/executing set for `dangerous`.
    public static let dangerousTools: Set<String> = ["bash", "write_file", "edit_file"]
}

/// One human decision about one tool call.
public enum ApprovalDecision: Equatable, Sendable {
    case approve        // run this call once
    case approveAlways  // run it, and remember for the rest of this task
    case deny           // return a tool-result error; the tool never runs
}

/// Task-scoped "always allow" memory, shared by an agent and every sub-agent
/// it spawns (ToolContext hands the same instance down, next to config and
/// model). An actor because parent and child loops live on different tasks;
/// it holds only this set, so a fresh task is a fresh instance and `/retry`
/// of the same task keeps it (continueRun must not re-prompt what the user
/// already approved).
public actor ApprovalState: Sendable {
    private var alwaysAllowed: Set<String> = []

    public init() {}

    public func recordAlways(tool: String) {
        alwaysAllowed.insert(tool)
    }

    public func isAlwaysApproved(tool: String) -> Bool {
        alwaysAllowed.contains(tool)
    }
}

/// The injected decider: given a tool name and a one-line summary of its
/// arguments, return the human's (or a scripted test's) decision. Sendable
/// because it is called from the agent loop and forwarded to sub-agents.
public typealias ApprovalHook = @Sendable (String, String) async -> ApprovalDecision

/// Text returned for a denied call: names the tool so the model can adapt
/// (propose something else) on its next turn — exactly the T3
/// unavailable-tool shape. The tool never ran; nothing was mutated.
public func approvalDeniedText(tool name: String) -> String {
    "error: approval denied — the \(name) tool was not run. " +
    "Do not retry the same call; propose a different approach or ask the user."
}

/// One-line, truncated summary of the raw JSON arguments for the prompt.
/// Pure string shaping — malformed JSON still yields something readable,
/// because the prompt is for a human scanning intent, not a parser.
public func approvalArgumentSummary(_ arguments: String) -> String {
    let oneLine = arguments
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespaces)
    let summary = oneLine.isEmpty ? "{}" : oneLine
    guard summary.count > 80 else { return summary }
    return String(summary.prefix(77)) + "..."
}

// ---- The interactive prompt (REPL only) ------------------------------------
// Installed as the hook by Harness in interactive mode only. `--once` never
// installs a hook, and a nil hook under a demanding policy denies — fail-
// closed. stdin is a shared stream, so reads are serialized through an actor:
// a parent prompting while a sub-agent's loop also prompts must not race on
// readLine(). Exercised only by the selftest's scripted stdin path.

extension ApprovalDecision {
    /// Parse one stdin line: y/yes → approve, a/always → approveAlways,
    /// anything else (including EOF) → deny. EOF denying is the fail-closed
    /// path: an absent human is not consent.
    public static func parse(line: String?) -> ApprovalDecision {
        switch line?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "y", "yes": return .approve
        case "a", "always": return .approveAlways
        default: return .deny
        }
    }
}

/// Serializes blocking stdin reads across concurrent agent loops.
final class SerialStdin: @unchecked Sendable {
    static let shared = SerialStdin()
    private let lock = NSLock()
    func readLine() -> String? { lock.withLock { Swift.readLine() } }
}

/// The real prompt. Printed to stdout (the REPL owns the terminal); the
/// answer comes from stdin via SerialStdin so parent/child prompts queue.
public func promptForApproval(tool name: String, summary: String) async -> ApprovalDecision {
    print(AgentUI.warn("approve \(name)? \(summary)  [y/n/a]"), terminator: "")
    // fflush not portable-critical here, but prompt visibility matters more
    // than micro latency on the blocking read.
    FileHandle.standardOutput.synchronizeFile()
    return ApprovalDecision.parse(line: SerialStdin.shared.readLine())
}
