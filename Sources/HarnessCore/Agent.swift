import Foundation

// ---------------------------------------------------------------------------
// Agent.swift — THE LOOP. This is the part that makes it an "agent".
// (Compaction of the history is Compaction.swift; this file only triggers it.)
//
// Every agent harness (pi, Claude Code, aider, ...) is some variation of:
//
//     loop:
//         turn = model(messages, tools)
//         if turn has tool calls:
//             for each call: execute it, append a tool result message
//             continue          <-- feed results back, model decides next move
//         else:
//             return turn.text  <-- model is done, hand control to the user
//
// That's it. No magic. The interesting engineering lives in the edges:
// truncating tool output, capping turns (runaway loops), rendering progress,
// persisting sessions, and handling API errors gracefully.
//
// Key invariant: the model NEVER executes anything itself. It only emits
// *requests* (tool_calls). The harness executes and reports back. The model
// can be wrong; the tools are the source of truth. That boundary is what
// makes the loop safe and debuggable.
// ---------------------------------------------------------------------------

public struct AgentRunError: Error, CustomStringConvertible {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

public struct Agent {
    public var config: Config
    public var model: ChatModel
    /// How deep this agent is in the spawn chain (top agent = 0). Tools that
    /// can recurse (spawn_agent) are removed once the next spawn would hit
    /// config.maxAgentDepth, so the recursion always terminates.
    public var depth: Int = 0

    /// The tools THIS agent may use. At the depth cap, spawn_agent disappears
    /// entirely — cleaner than letting the model attempt a doomed spawn.
    // pi-lens-ignore on the next line: SourceKit's in-session index went stale
    // when maxAgentDepth was added to Config mid-session (a server restart
    // resolves it); swiftc type-checks clean — this only silences the gate.
    public var availableTools: [ToolSpec] {  // pi-lens-ignore: SourceKit:unknown
        depth < config.maxAgentDepth
            ? Tools.all
            : Tools.all.filter { $0.name != "spawn_agent" }
    }

    public init(config: Config, model: ChatModel, depth: Int = 0) {
        self.config = config
        self.model = model
        self.depth = depth
    }

    // ---- Tool-approval gate (Approval.swift) ------------------------------
    // Ownership: the *policy* lives in Config; the *decider* is injected
    // here. A nil decider under a demanding policy (dangerous/all) must
    // deny — fail-closed — never execute.
    /// The injected human decision; nil means "no authority to ask".
    public var approvalHook: ApprovalHook?
    /// Task-scoped "always allow" memory, shared with spawned sub-agents.
    /// Nil means "not recording" — the rule still consults policy each time.
    public var approvalState: ApprovalState?

    /// Opt-in append-only transcript (JSONLSession.swift). Created from
    /// config when nil: every append/replace below also journals here, so a
    /// crash can lose at most the in-flight turn. Failure to open is a
    /// no-op, never a run-stopper.
    private var log: JSONLSessionLog? {
        get { _log ?? config.sessionLog.flatMap { try? JSONLSessionLog(path: $0) } }
        set { _log = newValue }
    }
    private var _log: JSONLSessionLog?

    /// Per-top-level-task: start with a clean "always allow" slate. A new
    /// `run(task:)` must re-prompt for everything the previous task approved;
    /// `/retry` goes through continueRun instead, so a retry of the same
    /// task keeps what the user already approved.
    public mutating func resetApprovalState() {
        approvalState = ApprovalState()
    }

    /// Runtime settings and the client built from them must change together;
    /// otherwise a REPL model switch updates saved metadata but sends requests
    /// through a stale value-type client configuration.
    public mutating func reconfigure(
        _ update: (inout Config) -> Void,
        makeModel: (Config) -> ChatModel
    ) {
        update(&config)
        model = makeModel(config)
    }

    public mutating func selectModel(
        _ modelID: String,
        makeModel: (Config) -> ChatModel
    ) {
        reconfigure({ $0.model = modelID }, makeModel: makeModel)
    }

    /// Run one user task to completion: call the model, execute tools, repeat
    /// until the model answers with plain text (or the turn cap is hit).
    /// Mutates `messages` in place so the REPL can persist the session.
    public mutating func run(task input: String, messages: inout [Message]) async throws {
        // ---- Pre-model gate (once per task, not per turn) ----------------
        // A rejected request never reaches the model OR the history, so a
        // blocked task leaves nothing to /retry. Fail-open: check() returns
        // nil on every error path.
        if let rejection = await ModelGate.check(input: input, config: config) {
            print(AgentUI.warn("[gate] task rejected — \(rejection)"))
            return
        }
        // Only a TOP-LEVEL task starts a fresh "always" slate. Sub-agents
        // arrive via run() too; resetting here would wipe the parent's
        // approvals out from under the shared state.
        if depth == 0 { resetApprovalState() }
        messages.append(.user(input))
        log?.append(message: .user(input))
        try await continueRun(messages: &messages)
    }

    /// Continue the existing, already-recorded task after a model failure or
    /// turn cap. Does not append another user message, so completed tool calls
    /// are not replayed when the API is explicitly retried.
    public mutating func continueRun(messages: inout [Message]) async throws {
        guard config.maxTurns > 0 else {
            throw AgentRunError(description: "turn cap must be greater than zero")
        }
        for turnIndex in 1...config.maxTurns {
            // ---- 0. Keep the context bounded --------------------------------
            // Cheap size check before every model call; only when the history
            // exceeds config.compactAboveBytes does it summarize older turns
            // (see Compaction.swift). No-op for short sessions.
            await Compaction.compactIfNeeded(&messages, config: config, model: model, journal: log)

            // ---- 1. Ask the model for its next move (streamed when on) ------
            // With streaming, visible text is printed fragment-by-fragment as
            // it arrives; the assembled turn comes back exactly like the
            // one-shot path, so everything below is unchanged.
            let turn: AssistantTurn
            do {
                if config.streaming {
                    turn = try await model.stream(messages, tools: availableTools) { fragment in
                        AgentUI.printStreaming(fragment)
                    }
                    if !turn.text.isEmpty { print() }  // close the streamed line
                } else {
                    turn = try await model.complete(messages, tools: availableTools)
                }
            } catch let error as LLMError {
                // Surface API errors with context; keep the history intact so
                // the user can /retry or /save.
                throw AgentRunError(description: "model call failed — \(error)")
            }

            // ---- 2. Record the assistant's turn -----------------------------
            let assistantMessage = Message(
                role: "assistant",
                content: turn.text.isEmpty ? nil : turn.text,
                toolCalls: turn.wantsTools ? turn.toolCalls : nil,
                toolCallId: nil,
                name: nil
            )
            messages.append(assistantMessage)
            log?.append(message: assistantMessage)

            UsageLog.append(path: config.usageLog, depth: depth, usage: turn.usage, finish: turn.finishReason)
            if let usage = turn.usage {
                let tokens = usage.promptTokens + usage.completionTokens
                let summary = "   [turn \(turnIndex): \(tokens) tokens, finish=\(turn.finishReason)]"
                print(AgentUI.dim(summary))
            }

            // ---- 3. Plain text → task complete, back to the user ------------
            guard turn.wantsTools else {
                if turn.text.isEmpty {
                    print(AgentUI.warn("(model returned no text)"))
                } else if !config.streaming {
                    // Non-streaming path: the text hasn't been shown yet.
                    print(AgentUI.assistant(turn.text))
                }
                // (streaming path: text is already on screen above)
                return
            }

            // ---- 4. Execute each requested tool, append its result ----------
            for call in turn.toolCalls {
                let result = await execute(call)
                messages.append(.tool(result: result, for: call))
                log?.append(message: .tool(result: result, for: call))
            }
            // (All results go in before the next model call — the wire format
            // wants every tool_call answered exactly once.)
        }
        throw AgentRunError(
            description: "hit the turn cap (\(config.maxTurns)); the model may be looping. Use /reset or /retry."
        )
    }

    /// Execute one tool call, pretty-print what happened, return the text
    /// that goes back to the model. Tool failures become *text*, not throws —
    /// the model should see the error and adapt.
    private func execute(_ call: ToolCall) async -> String {
        print(AgentUI.toolCall(call))
        guard let tool = availableTools.first(where: { $0.name == call.function.name }) else {
            let available = availableTools.map { $0.name }.joined(separator: ", ")
            let error = "error: tool '\(call.function.name)' is unavailable to this agent. available: \(available)"
            print(AgentUI.toolResult(error, isError: true))
            return error
        }

        guard let arguments = JSONValue.parse(call.function.arguments)?.objectValue else {
            let error = "error: could not parse tool arguments as a JSON object: " +
                        "'\(call.function.arguments.prefix(200))'"
            print(AgentUI.toolResult(error, isError: true))
            return error
        }

        // ---- 3.5 Approval gate: after parsing, before execution -----------
        // Malformed arguments died above as parse errors; a denial returns a
        // tool-result error without running the tool or mutating any file.
        let toolName = tool.name
        if config.approvalPolicy != .never {
            // "always allow" memory is shared with spawned sub-agents; a nil
            // state simply means nothing is pre-approved.
            let alreadyApproved: Bool
            if let approvalState {
                alreadyApproved = await approvalState.isAlwaysApproved(tool: toolName)
            } else {
                alreadyApproved = false
            }
            if config.approvalPolicy.requiresApproval(tool: toolName, alreadyApproved: alreadyApproved) {
                // Fail-closed: no hook installed (--once, or a test with no
                // scripted hook) means there is no human to consent, so the
                // call is denied. Deliberately opposite of the fail-open
                // classifier gate: an unreachable classifier is an outage,
                // an unreachable human is not consent.
                guard let hook = approvalHook else {
                    let error = "error: \(toolName) requires approval " +
                                "(policy: \(config.approvalPolicy.rawValue)) but no " +
                                "approval hook is installed; the tool was not run."
                    print(AgentUI.toolResult(error, isError: true))
                    return error
                }
                let summary = approvalArgumentSummary(call.function.arguments)
                switch await hook(toolName, summary) {
                case .deny:
                    // One tool result, no execution. The model reads the
                    // denial and can adapt on its next turn; the denial
                    // consuming a turn is inherent to results-as-text.
                    let error = approvalDeniedText(tool: toolName)
                    print(AgentUI.toolResult(error, isError: true))
                    return error
                case .approveAlways:
                    await approvalState?.recordAlways(tool: toolName)
                case .approve:
                    break  // run this call once
                }
            }
        }

        let output: String
        do {
            output = try await tool.run(arguments, ToolContext(
                config: config,
                model: model,
                cwd: FileManager.default.currentDirectoryPath,
                depth: depth,
                approvalHook: approvalHook,
                approvalState: approvalState
            ))
        } catch {
            output = "error: \(error.localizedDescription)"
        }

        // Cap what we feed back to the model — a 50 MB build log is not context,
        // it's a bill. (pi does the same thing.)
        let truncated = output.count > config.maxToolOutput
            ? String(output.prefix(config.maxToolOutput))
                + "\n...[truncated \(output.count - config.maxToolOutput) chars]"
            : output

        print(AgentUI.toolResult(truncated, isError: truncated.hasPrefix("error")))
        return truncated
    }
}