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

struct AgentRunError: Error, CustomStringConvertible {
    let description: String
}

struct Agent {
    var config: Config
    var model: ChatModel
    /// How deep this agent is in the spawn chain (top agent = 0). Tools that
    /// can recurse (spawn_agent) are removed once the next spawn would hit
    /// config.maxAgentDepth, so the recursion always terminates.
    var depth: Int = 0

    /// The tools THIS agent may use. At the depth cap, spawn_agent disappears
    /// entirely — cleaner than letting the model attempt a doomed spawn.
    var availableTools: [ToolSpec] {
        depth + 1 < config.maxAgentDepth
            ? Tools.all
            : Tools.all.filter { $0.name != "spawn_agent" }
    }

    /// Run one user task to completion: call the model, execute tools, repeat
    /// until the model answers with plain text (or the turn cap is hit).
    /// Mutates `messages` in place so the REPL can persist the session.
    mutating func run(task input: String, messages: inout [Message]) async throws {
        messages.append(.user(input))

        for turnIndex in 1...config.maxTurns {
            // ---- 0. Keep the context bounded --------------------------------
            // Cheap size check before every model call; only when the history
            // exceeds config.compactAboveBytes does it summarize older turns
            // (see Compaction.swift). No-op for short sessions.
            await Compaction.compactIfNeeded(&messages, config: config, model: model)

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
        guard let tool = Tools.named(call.function.name) else {
            let available = Tools.all.map { $0.name }.joined(separator: ", ")
            let error = "error: unknown tool '\(call.function.name)'. available: \(available)"
            print(AgentUI.toolResult(error, isError: true))
            return error
        }

        guard let arguments = JSONValue.parse(call.function.arguments)?.objectValue else {
            let error = "error: could not parse tool arguments as a JSON object: " +
                        "'\(call.function.arguments.prefix(200))'"
            print(AgentUI.toolResult(error, isError: true))
            return error
        }

        let output: String
        do {
            output = try await tool.run(arguments, ToolContext(
                config: config,
                model: model,
                cwd: FileManager.default.currentDirectoryPath,
                depth: depth
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