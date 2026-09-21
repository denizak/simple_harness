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

        print(failures == 0 ? "selftest: all passed" : AgentUI.errorText("selftest: \(failures) failure(s)"))
        exit(failures == 0 ? 0 : 1)
    }

    /// Run one tool and turn any thrown error into a text report — the same
    /// contract the agent loop relies on (tools report; they don't throw).
    private static func runTool(_ body: () async throws -> String) async -> String {
        do { return try await body() } catch { return "error: \(error.localizedDescription)" }
    }
}