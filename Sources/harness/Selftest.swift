import Foundation

// ---------------------------------------------------------------------------
// Selftest.swift — verify the tool layer without an API call.
//
// A harness has two halves: the tool layer (deterministic, testable) and the
// model loop (stochastic). `harness --selftest` exercises the first half so
// you always know whether a failure is yours or the model's.
//
// Swift 6 note: `run()` is async because tools are async. We simply `await`
// them in sequence — no semaphores or DispatchQueue bridging, which would
// trip Swift 6's strict concurrency rules (mutation of captured vars across
// threads). One task, one thread, easy to reason about.
// ---------------------------------------------------------------------------

enum SelfTest {
    static func run() async {
        print("selftest: tool layer")
        var failures = 0

        // Local assertion helper: PASS/FAIL one check, count failures.
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            if condition {
                print("  ✓ \(name)")
            } else {
                failures += 1
                print(AgentUI.errorText("  ✗ \(name) \(detail)"))
            }
        }

        // ---- write_file / read_file roundtrip ------------------------------
        let path = NSTemporaryDirectory() + "harness-selftest-\(UUID().uuidString).txt"
        let content: [String: JSONValue] = ["path": .string(path), "content": .string("alpha\nbeta\ngamma")]
        var output = await runTool { try await Tools.writeFile.run(content, ".") }
        check("write_file", output.contains("wrote"), output)

        output = await runTool { try await Tools.readFile.run(["path": .string(path)] as [String: JSONValue], ".") }
        check("read_file numbers lines", output.contains("1  alpha") && output.contains("3  gamma"), output)

        // offset is 1-based: reading from line 2 must skip "alpha".
        output = await runTool {
            try await Tools.readFile.run(["path": .string(path), "offset": .number(2)] as [String: JSONValue], ".")
        }
        check("read_file offset", output.contains("2  beta") && !output.contains("alpha"), output)

        // ---- edit_file: unique replace, not-found, ambiguous ---------------
        output = await runTool {
            try await Tools.editFile.run(
                ["path": .string(path),
                 "old_text": .string("beta"),
                 "new_text": .string("BETA")] as [String: JSONValue], "."
            )
        }
        check("edit_file unique replace", output.contains("edited"), output)

        output = await runTool {
            try await Tools.editFile.run(
                ["path": .string(path),
                 "old_text": .string("nope"),
                 "new_text": .string("x")] as [String: JSONValue], "."
            )
        }
        check("edit_file rejects missing text", output.contains("not found"), output)

        // "a" appears twice ("alpha", "gamma") — must refuse without replace_all.
        output = await runTool {
            try await Tools.editFile.run(
                ["path": .string(path), "old_text": .string("a"), "new_text": .string("x")] as [String: JSONValue], "."
            )
        }
        check("edit_file rejects ambiguous text", output.contains("appears"), output)

        // ---- bash: stdout capture, exit codes, watchdog timeout ------------
        output = await runTool {
            try await Tools.bash.run(
                ["command": .string("echo hello-selftest")] as [String: JSONValue], "."
            )
        }
        check("bash stdout", output.contains("hello-selftest") && output.contains("exit code: 0"), output)

        output = await runTool { try await Tools.bash.run(["command": .string("exit 3")] as [String: JSONValue], ".") }
        check("bash exit code", output.contains("exit code: 3"), output)

        // sleep 5 with a 1s budget → the watchdog must terminate the child.
        output = await runTool {
            try await Tools.bash.run(
                ["command": .string("sleep 5"), "timeout_seconds": .number(1)] as [String: JSONValue], "."
            )
        }
        check("bash timeout kill", output.contains("signal") || output.contains("exit code: 15"), output)

        try? FileManager.default.removeItem(atPath: path)

        // ---- JSONValue roundtrip --------------------------------------------
        let parsed = JSONValue.parse(#"{"a": [1, "two", true], "b": null}"#)
        check("JSONValue.parse", parsed?.objectValue?["a"]?.arrayValue?.count == 3, "")

        // ---- grep: regex search across a small tree -------------------------
        // The tree mirrors real projects: nested dirs, mixed case, and a
        // subdirectory to prove the walk recurses.
        let grepDir = NSTemporaryDirectory() + "harness-grep-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: grepDir + "sub", withIntermediateDirectories: true)
        try? "needle here\nother line\n".write(toFile: grepDir + "a.txt", atomically: true, encoding: .utf8)
        try? "NEEDLE upper\n".write(toFile: grepDir + "sub/b.md", atomically: true, encoding: .utf8)

        output = await runTool {
            try await Tools.grep.run(
                ["pattern": .string("needle"), "path": .string(grepDir)] as [String: JSONValue], "."
            )
        }
        check("grep default (case-sensitive) misses NEEDLE", output.contains("a.txt:1") && !output.contains("b.md"), output)

        output = await runTool {
            try await Tools.grep.run(
                ["pattern": .string("needle"),
                 "path": .string(grepDir),
                 "ignore_case": .bool(true)] as [String: JSONValue], "."
            )
        }
        check("grep ignore_case hits both files", output.contains("NEEDLE upper") && output.contains("a.txt:1"), output)

        output = await runTool {
            try await Tools.grep.run(
                ["pattern": .string("no-such-token"), "path": .string(grepDir)] as [String: JSONValue], "."
            )
        }
        check("grep reports no matches", output.contains("no matches"), output)
        try? FileManager.default.removeItem(atPath: grepDir)

        // ---- compaction boundary math (pure functions, no API call) ---------
        // The tail must start at a plain user message so no tool_call loses
        // its tool result. History shape (indexes):
        //   0 system | 1 user | 2 assistant→tools | 3 tool | 4 assistant
        //   | 5 user | 6 assistant→tools | 7 tool | 8 assistant
        let fixtureCall = ToolCall(id: "call_1", type: "function", function: .init(name: "bash", arguments: "{}"))
        let assistantAsking = Message(role: "assistant", content: nil, toolCalls: [fixtureCall], toolCallId: nil, name: nil)
        let history: [Message] = [
            .system("sys"),
            .user("first task"),
            assistantAsking,
            .tool(result: "result text", for: fixtureCall),
            Message(role: "assistant", content: "done", toolCalls: nil, toolCallId: nil, name: nil),
            .user("second task"),
            assistantAsking,
            .tool(result: "second result", for: fixtureCall),
            Message(role: "assistant", content: "done again", toolCalls: nil, toolCallId: nil, name: nil),
        ]
        let start = Compaction.tailStart(in: history, keepTail: 3)
        let startLabel = start.map(String.init) ?? "nil"
        check("compaction tail starts mid-exchange (not on a tool result)", start == 6, "start=\(startLabel)")
        // pi-lens-ignore on the next line: SourceKit's in-session index went stale when
        // Compaction.swift was added mid-session (the server resolves it after a restart);
        // swiftc compiles clean, so the ignore comment only silences the lint gate.
        check("compaction boundary rejects tool results",
              !Compaction.isCleanBoundary(history[3]) && !Compaction.isCleanBoundary(history[7]), "")  // pi-lens-ignore: SourceKit:unknown
        check("compaction boundary accepts assistant tool_calls", Compaction.isCleanBoundary(history[6]), "")

        print(failures == 0 ? "selftest: all passed" : AgentUI.errorText("selftest: \(failures) failure(s)"))
        exit(failures == 0 ? 0 : 1)
    }

    /// Run one tool and turn any thrown error into a text report — the same
    /// contract the agent loop relies on (tools report; they don't throw).
    private static func runTool(_ body: () async throws -> String) async -> String {
        do { return try await body() } catch { return "error: \(error.localizedDescription)" }
    }
}