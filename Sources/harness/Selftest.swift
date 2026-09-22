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
        var output = await runTool { try await Tools.writeFile.run(content, testContext(".")) }
        check("write_file", output.contains("wrote"), output)

        output = await runTool { try await Tools.readFile.run(["path": .string(path)] as [String: JSONValue], testContext(".")) }
        check("read_file numbers lines", output.contains("1  alpha") && output.contains("3  gamma"), output)

        // offset is 1-based: reading from line 2 must skip "alpha".
        output = await runTool {
            try await Tools.readFile.run(["path": .string(path), "offset": .number(2)] as [String: JSONValue], testContext("."))
        }
        check("read_file offset", output.contains("2  beta") && !output.contains("alpha"), output)

        // ---- edit_file: unique replace, not-found, ambiguous ---------------
        output = await runTool {
            try await Tools.editFile.run(
                ["path": .string(path),
                 "old_text": .string("beta"),
                 "new_text": .string("BETA")] as [String: JSONValue], testContext("."))
        }
        check("edit_file unique replace", output.contains("edited"), output)

        output = await runTool {
            try await Tools.editFile.run(
                ["path": .string(path),
                 "old_text": .string("nope"),
                 "new_text": .string("x")] as [String: JSONValue], testContext("."))
        }
        check("edit_file rejects missing text", output.contains("not found"), output)

        // "a" appears twice ("alpha", "gamma") — must refuse without replace_all.
        output = await runTool {
            try await Tools.editFile.run(
                ["path": .string(path), "old_text": .string("a"), "new_text": .string("x")] as [String: JSONValue], testContext("."))
        }
        check("edit_file rejects ambiguous text", output.contains("appears"), output)

        // ---- bash: stdout capture, exit codes, watchdog timeout ------------
        output = await runTool {
            try await Tools.bash.run(
                ["command": .string("echo hello-selftest")] as [String: JSONValue], testContext("."))
        }
        check("bash stdout", output.contains("hello-selftest") && output.contains("exit code: 0"), output)

        output = await runTool { try await Tools.bash.run(["command": .string("exit 3")] as [String: JSONValue], testContext(".")) }
        check("bash exit code", output.contains("exit code: 3"), output)

        // sleep 5 with a 1s budget → the watchdog must terminate the child.
        output = await runTool {
            try await Tools.bash.run(
                ["command": .string("sleep 5"), "timeout_seconds": .number(1)] as [String: JSONValue], testContext("."))
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
                ["pattern": .string("needle"), "path": .string(grepDir)] as [String: JSONValue], testContext("."))
        }
        check("grep default (case-sensitive) misses NEEDLE", output.contains("a.txt:1") && !output.contains("b.md"), output)

        output = await runTool {
            try await Tools.grep.run(
                ["pattern": .string("needle"),
                 "path": .string(grepDir),
                 "ignore_case": .bool(true)] as [String: JSONValue], testContext("."))
        }
        check("grep ignore_case hits both files", output.contains("NEEDLE upper") && output.contains("a.txt:1"), output)

        output = await runTool {
            try await Tools.grep.run(
                ["pattern": .string("no-such-token"), "path": .string(grepDir)] as [String: JSONValue], testContext("."))
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

        // ---- config resolution: provider autodetect (pure, no API) ---------
        // Env is injected, so this never touches real secrets.
        let cloud = Config.resolve(arguments: [], env: ["OLLAMA_API_KEY": "stub-key"])
        check("ollama-cloud autodetect (OLLAMA_API_KEY)",
              cloud.provider == "ollama-cloud" && cloud.baseURL == "https://ollama.com/v1"
                  && cloud.model == "kimi-k2.7-code",
              "provider=\(cloud.provider) model=\(cloud.model)")
        let forced = Config.resolve(arguments: ["--provider", "openai"], env: ["OLLAMA_API_KEY": "a"])
        check("--provider overrides autodetect",
              forced.provider == "openai" && forced.baseURL == "https://api.openai.com/v1",
              "provider=\(forced.provider)")
        // Autodetect order: zai beats deepseek when both env keys exist.
        let both = Config.resolve(arguments: [], env: ["ZAI_API_KEY": "z", "DEEPSEEK_API_KEY": "d"])
        check("autodetect order (zai before deepseek)", both.provider == "zai", "provider=\(both.provider)")

        // GLM Coding Plan: opt-in endpoints (never autodetected — plan quota
        // must not be silently routed to).
        let codingCN = Config.resolve(arguments: ["--provider", "zai-coding-cn"], env: [:])
        check("zai-coding-cn (CN plan) endpoint",
              codingCN.provider == "zai-coding-cn"
                  && codingCN.baseURL == "https://open.bigmodel.cn/api/coding/paas/v4"
                  && codingCN.model == "glm-5.3",
              "provider=\(codingCN.provider) model=\(codingCN.model)")
        let codingIntl = Config.resolve(arguments: ["--provider", "zai-coding"], env: [:])
        check("zai-coding (international plan) endpoint",
              codingIntl.provider == "zai-coding"
                  && codingIntl.baseURL == "https://api.z.ai/api/coding/paas/v4",
              "provider=\(codingIntl.provider)")
        // Key borrowing from pi's auth.json is environment-dependent: assert
        // only when the file is actually there.
        if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.pi/agent/auth.json") {
            check("zai-coding-cn borrows pi's stored key", codingCN.apiKey != "none", "apiKey=none")
        }

        // ---- SSE assembler: delta stitching without any network -------------
        // These are the four shapes a streaming provider sends: text deltas,
        // tool_call fragments (name first, arguments appended across chunks),
        // the finish chunk, and a usage-only final chunk.
        var assembler = SSEAssembler()
        // Raw strings let the JSON keep its plain quotes; the \" sequences
        // inside "arguments" are the JSON-escaped quotes the fragment needs.
        let sseChunks = [
            #"{"choices":[{"delta":{"content":"Hel"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"ba","arguments":"{\"cmd\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"ls\"}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#,
        ]
        for chunk in sseChunks {
            guard let parsed = JSONValue.parse(chunk) else {
                check("SSE: chunk parses", false, chunk)
                continue
            }
            _ = assembler.ingest(parsed)
        }
        let assembled = assembler.assembled()
        check("SSE: text assembled from fragments", assembled.text == "Hel", assembled.text)
        check("SSE: tool_call assembled from deltas",
              assembled.toolCalls.count == 1 && assembled.toolCalls[0].function.name == "ba"
                  && assembled.toolCalls[0].function.arguments == "{\"cmd\":\"ls\"}"
                  && assembled.toolCalls[0].id == "c1",
              assembled.toolCalls.first.map { "\($0.function.name) \($0.function.arguments)" } ?? "none")
        check("SSE: finish reason + usage captured",
              assembled.finishReason == "tool_calls" && assembled.usage?.promptTokens == 10, "")

        // ---- spawn_agent: depth cap enforced textually ----------------------
        let capped = testContext(".", depth: 2)
        output = await runTool { try await Tools.spawnAgent.run(["task": .string("x")] as [String: JSONValue], capped) }
        check("spawn_agent refuses at depth cap", output.contains("depth limit"), output)

        // ---- DeepSeek: provider resolution with the env key -----------------
        let deepseek = Config.resolve(arguments: [], env: ["DEEPSEEK_API_KEY": "sk-test"])
        check("deepseek autodetect (DEEPSEEK_API_KEY)",
              deepseek.provider == "deepseek" && deepseek.baseURL == "https://api.deepseek.com"
                  && deepseek.model == "deepseek-flash",
              "provider=\(deepseek.provider) model=\(deepseek.model)")

        // ---- TypeSafe: request building + answer formatting (pure) ----------
        let judged = [
            TypeSafeQuestion(id: "urgent", type: "noul", instructions: "Is this urgent?",
                             criteria: .object(["true": .string("Time-sensitive"),
                                                "false": .string("No urgency")])),
            TypeSafeQuestion(id: "team", type: "choice", instructions: "Which team?",
                             criteria: .object(["billing": .string("Payments"),
                                                "tech": .string("Bugs")])),
            TypeSafeQuestion(id: "severity", type: "score", instructions: "How severe?",
                             criteria: .array([.string("Low"), .string("High")])),
        ]
        let safeRequest = TypeSafeClient.request(state: "server down", questions: judged)
        let requestFields = safeRequest.objectValue ?? [:]
        check("TypeSafe request shape",
              requestFields["model"]?.stringValue == "jev-latest"
                  && requestFields["state"]?.stringValue == "server down"
                  && requestFields["questions"]?.objectValue?.count == 3,
              "keys=\(requestFields.keys.sorted().joined(separator: ","))")
        check("TypeSafe noul criteria carried into the request",
              requestFields["questions"]?.objectValue?["urgent"]?.objectValue?["criteria"]?
                  .objectValue?["true"]?.stringValue == "Time-sensitive", "")
        // Formatting: the documented response shape renders model-readable lines.
        // Formatting: the documented response shape renders model-readable lines.
        let sampleJSON = #"{"model":"jev-1.13.0","answers":{"urgent":{"type":"noul","noul":0.95},"# +
            #""team":{"type":"choice","choice":"billing","probabilities":{"billing":0.88,"tech":0.12},"confidence":0.81}}}"#
        let sampleResponse = JSONValue.parse(sampleJSON) ?? .null
        let rendered = TypeSafeClient.format(sampleResponse)
        check("TypeSafe format renders probabilities",
              rendered.contains("95%") && rendered.contains("billing") && rendered.contains("0.81"),
              rendered.replacingOccurrences(of: "\n", with: " | "))

        // ---- reasoning_effort: provider quirk handling (pure) ---------------
        // Request building is pure, so the body can be inspected directly.
        let quirky = OpenAICompatClient(config: Config(
            provider: "quirky", baseURL: "https://example.com/v1", apiKey: "none", model: "gpt-5.6-luna"))
        do {
            let (plainBody, _) = try quirky.requestFor(
                messages: [.user("hi")], tools: [Tools.grep], streaming: false)
            check("reasoning_effort absent by default", plainBody["reasoning_effort"] == nil, "")
            let (overriddenBody, _) = try quirky.requestFor(
                messages: [.user("hi")], tools: [], streaming: false,
                overrides: ["reasoning_effort": .string("none")])
            check("reasoning_effort override lands in body",
                  overriddenBody["reasoning_effort"] == .string("none"), "")
        } catch {
            check("reasoning_effort request builds", false, "\(error)")
        }
        check("config-driven reasoning effort",
              Config.resolve(arguments: ["--reasoning", "high"], env: [:]).reasoningEffort == "high", "")
        let conflict = LLMError(status: 400, body:
            "Function tools with reasoning_effort are not supported for gpt-5.6-luna.")
        check("conflict detected for the self-healing retry",
              OpenAICompatClient.isReasoningToolConflict(conflict)
                  && OpenAICompatClient.shouldRetryWithNone(conflict, attempt: 0, sentEffort: true)
                  && !OpenAICompatClient.shouldRetryWithNone(conflict, attempt: 1, sentEffort: true)
                  && !OpenAICompatClient.shouldRetryWithNone(conflict, attempt: 0, sentEffort: false),
              "")

        // ---- provider quirks are data on the profile (modular config) ------
        let openaiQuirks = Config.resolve(arguments: [], env: ["OPENAI_API_KEY": "k"])
        check("openai quirk: max_completion_tokens",
              openaiQuirks.tokenLimitKey == "max_completion_tokens", openaiQuirks.tokenLimitKey)
        let cloudQuirks = Config.resolve(arguments: [], env: ["OLLAMA_API_KEY": "k"])
        check("ollama-cloud quirk: stream_options allowed", cloudQuirks.streamOptions, "")
        let zaiQuirks = Config.resolve(arguments: [], env: ["ZAI_API_KEY": "k"])
        check("zai quirk: no stream_options by default", zaiQuirks.streamOptions == false, "")

        print(failures == 0 ? "selftest: all passed" : AgentUI.errorText("selftest: \(failures) failure(s)"))
        exit(failures == 0 ? 0 : 1)
    }

    /// Run one tool and turn any thrown error into a text report — the same
    /// contract the agent loop relies on (tools report; they don't throw).
    private static func runTool(_ body: () async throws -> String) async -> String {
        do { return try await body() } catch { return "error: \(error.localizedDescription)" }
    }

    /// A ToolContext for direct tool calls in tests (dummy model — the tools
    /// under test here never touch it; only spawn_agent would).
    private static func testContext(_ cwd: String, depth: Int = 0) -> ToolContext {
        let config = Config(provider: "stub", baseURL: "stub://stub", apiKey: "none", model: "stub")
        return ToolContext(config: config, model: OpenAICompatClient(config: config), cwd: cwd, depth: depth)
    }
}