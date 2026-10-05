import Foundation
import HarnessCore

// Version reported by --version; bump when the harness changes shape.
let harnessVersion = "0.2.0"

// ---------------------------------------------------------------------------
// main.swift — the REPL (the skin around the loop).
//
// Flow: parse args → resolve config → seed system prompt → read user input →
// hand each task to Agent.run() → persist the session. Slash commands manage
// the loop's state machine (reset/save/load/model).
// ---------------------------------------------------------------------------

func systemPrompt(for config: Config) -> String {
    let cwd = FileManager.default.currentDirectoryPath
    return """
    You are a coding agent running inside `simple_harness`, a minimal agent harness.
    Accomplish the user's task in the current working directory using the provided tools.
    Work step by step: inspect before editing, verify after (run builds/tests when relevant).
    Prefer one focused tool call per turn. Tool failures are text — read them and adapt.
    When the task is done, stop and reply in plain text with a brief summary.
    Current directory: \(cwd)
    """
}

func banner(_ config: Config) {
    print("""
    \(AgentUI.bold)simple_harness\(AgentUI.reset) — a minimal agent harness in Swift
      provider : \(config.provider)
      model    : \(config.model)
      endpoint : \(config.baseURL)
      tools    : \(Tools.all.map { $0.name }.joined(separator: ", "))
      type /help for commands
    """)
}

func helpText() {
    print("""
    /reset            start a fresh conversation (keeps the session file)
    /model [id]       show or switch the model (e.g. /model gpt-4o-mini)
    /models           list models offered by the current provider
    /tools            list available tools
    /save [file]      save the session (default .harness/session.json)
    /load [file]      load a session
    /retry            continue the current task after an API or turn-cap failure
    /exit             quit (also: Ctrl-D)
    Anything else you type becomes the next task for the agent.
    End a line with \\ to continue on the next line.

    Approval gate (--approval dangerous|all, or env HARNESS_APPROVAL): gated
    tool calls ask y/n/a here first (a = always for this task). Fail-closed:
    when no human can be asked (--once), the call is denied — the opposite of
    the pre-model classifier gate, which fails open on errors.
    """)
}

@main
struct HarnessMain {
    static func main() async {
        let arguments = CommandLine.arguments

        if arguments.contains("--version") || arguments.contains("-V") {
            print("simple_harness \(harnessVersion)")
            return
        }
        if arguments.contains("--e2e") {
            await E2ETest.run()
            return
        }
        if arguments.contains("--selftest") {
            await SelfTest.run()
            return
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            print("""
            usage: harness [options] [--once "task"]
                  --provider NAME   ollama | ollama-cloud | zai | zai-coding | zai-coding-cn |
                                    deepseek | openai
                  --model ID        model id override
                  --base-url URL    API endpoint override (OpenAI-compatible /chat/completions)
                  --api-key KEY     API key override
                  --config PATH     JSON config file (default ./.simple.h.conf;
                                    env HARNESS_CONFIG; env vars and flags still win)
                  --gate            enable the pre-model gate (TypeSafe; needs TYPESAFE_API_KEY)
                  --no-gate         disable it (overrides file/env)
                  --gate-threshold P   minimum proceed probability (0..<1, default 0.5)
                  --approval POLICY   never | dangerous | all — ask y/n/a before
                                      gated tool calls (default never; env
                                      HARNESS_APPROVAL; REPL-only prompts)
                  --no-streaming    disable SSE streaming
                  --session-log PATH  append a JSONL transcript line-by-line
                                      (crash-safe; off by default — /save
                                      remains the way to resume a session)
                  --no-session-log  disable it (overrides file/env)
                  --max-turns N     turn cap per task (default 25)
                  --typesafe-key KEY   TypeSafe API key override
                  --once TASK       run one task non-interactively (nonzero exit on failure)
                  --reasoning EFF   reasoning effort for thinking models (none|low|medium|high|max)
                  --selftest        exercise the tool layer without any API call
                  --e2e             stub-model loop tests + a live round-trip
                  --version         print the version and exit
            """)
            return
        }

        let config = Config.resolve(arguments: arguments)
        banner(config)

        // ---- Approval-gate notice + hook installation -----------------------
        // The notice prints for ANY policy, so a silent environment override
        // (HARNESS_APPROVAL) is never invisible. The hook (the real y/n/a
        // prompt) is installed ONLY in interactive mode: --once has no human
        // at the keyboard, and a nil hook under a demanding policy denies —
        // fail-closed by construction.
        if config.approvalPolicy != .never {
            print(AgentUI.warn(
                "[approval] policy '\(config.approvalPolicy.rawValue)' active — " +
                "gated tool calls ask before running (fail-closed without a prompt)"))
        }

        var messages: [Message] = [.system(systemPrompt(for: config))]
        var agent = Agent(config: config, model: makeChatModel(for: config))

        var retryAvailable = false

        // Non-interactive single task (handy for testing and scripting):
        //   harness --once "build and test"
        // Runs ONE task through the loop, then exits. The & passes let the
        // agent mutate the conversation history in place.
        if let taskIndex = arguments.firstIndex(of: "--once"),
           arguments.indices.contains(taskIndex + 1) {
            let succeeded = await runTask(arguments[taskIndex + 1], with: &agent, messages: &messages,
                                          retryAvailable: &retryAvailable)
            exit(succeeded ? 0 : 1)
        }

        // ---- Interactive REPL ------------------------------------------------
        // Interactive only: install the human y/n/a approval prompt. --once
        // exited above with a nil hook, so a demanding policy denies there.
        agent.approvalHook = promptForApproval
        // readLine() only delivers ONE line, so multi-line input uses a
        // continuation rule: a trailing backslash splices the next line in.
        // `input` accumulates the splice; the loop resets it after dispatch.
        var input = ""
        while true {
            let prompt = input.isEmpty ? "\(AgentUI.bold)you › \(AgentUI.reset)" : "  … › "
            // TTY input goes through the raw-mode reader so "@" completes
            // file paths as you type (AtCompletion.swift); pipes fall back
            // to plain readLine() inside it.
            guard let line = AtCompletion.readLine(prompt: prompt) else { print(); break }  // Ctrl-D = EOF
            if line.hasSuffix("\\") {
                input += String(line.dropLast()) + "\n"
                continue
            }
            input += line

            let text = input.trimmingCharacters(in: .whitespaces)
            input = ""

            guard !text.isEmpty else { continue }

            // Dispatch: slash commands manipulate harness state; anything else
            // becomes a task and drives the agent loop until it finishes.
            if text.hasPrefix("/") {
                await handleCommand(text, &agent, &messages, retryAvailable: &retryAvailable)
            } else {
                _ = await runTask(text, with: &agent, messages: &messages, retryAvailable: &retryAvailable)
            }
        }
    }

    /// Run a new task and persist its transcript on both success and failure.
    /// The retry flag tracks only an incomplete task from this process.
    @discardableResult
    static func runTask(
        _ task: String, with agent: inout Agent, messages: inout [Message], retryAvailable: inout Bool
    ) async -> Bool {
        var taskSucceeded = false
        do {
            try await agent.run(task: task, messages: &messages)
            taskSucceeded = true
            retryAvailable = false
        } catch {
            retryAvailable = true
            print(AgentUI.errorText("error: \(error)"))
        }
        do {
            try agent.saveSession(messages: messages)
        } catch {
            print(AgentUI.errorText("warning: could not save session: \(error)"))
            return false
        }
        return taskSucceeded
    }

    /// Continue a failed task from its recorded transcript; never re-append
    /// the prompt or replay a completed tool result.
    static func retryTask(with agent: inout Agent, messages: inout [Message], retryAvailable: inout Bool) async {
        guard retryAvailable else {
            print(AgentUI.warn("nothing to retry"))
            return
        }
        retryAvailable = false
        do {
            try await agent.continueRun(messages: &messages)
        } catch {
            retryAvailable = true
            print(AgentUI.errorText("error: \(error)"))
        }
        do {
            try agent.saveSession(messages: messages)
        } catch {
            print(AgentUI.errorText("warning: could not save session: \(error)"))
        }
    }

    /// Slash commands. Note how little state a REPL needs: the conversation
    /// (messages) + configuration (agent) + one retry-eligibility bit.
    static func handleCommand(
        _ input: String, _ agent: inout Agent, _ messages: inout [Message], retryAvailable: inout Bool
    ) async {
        var parts = input.split(separator: " ").map(String.init)
        let command = parts.removeFirst()
        let argument = parts.joined(separator: " ")

        switch command {
        case "/help", "/?":
            helpText()
        case "/exit", "/quit":
            exit(0)
        case "/reset":
            messages = [.system(systemPrompt(for: agent.config))]
            retryAvailable = false
            print(AgentUI.dim("conversation reset"))
        case "/model":
            if argument.isEmpty {
                print(AgentUI.dim("model: \(agent.config.model)"))
            } else {
                agent.selectModel(argument) { makeChatModel(for: $0) }
                print(AgentUI.dim("model → \(argument)"))
            }
        case "/tools":
            for tool in Tools.all { print(AgentUI.dim("  \(tool.name) — \(tool.description)")) }
        case "/models":
            // Lists what the CURRENT provider offers (GET {baseURL}/models) —
            // with Ollama Cloud that's the whole cloud catalog.
            do {
                let models = try await makeChatModel(for: agent.config).listModels()
                print(AgentUI.dim(models.joined(separator: "\n")))
            } catch {
                print(AgentUI.errorText("error: \(error)"))
            }
        case "/save":
            do {
                let url = argument.isEmpty ? nil : URL(fileURLWithPath: argument)
                try agent.saveSession(messages: messages, to: url)
                print(AgentUI.dim("saved \(url?.path ?? Session.defaultPath.path)"))
            } catch { print(AgentUI.errorText("error: \(error)")) }
        case "/load":
            do {
                let url = argument.isEmpty ? nil : URL(fileURLWithPath: argument)
                let session = try Session.load(from: url)
                messages = session.messages
                retryAvailable = false
                // Precedence policy lives on Session.restoreModel — the model
                // applies only when the session ran on the same endpoint.
                if let restored = session.restoreModel(activeBaseURL: agent.config.baseURL) {
                    agent.selectModel(restored) { makeChatModel(for: $0) }
                    print(AgentUI.dim("loaded \(session.messages.count) messages (\(restored))"))
                } else {
                    print(AgentUI.warn(
                        "session was created on a different endpoint — keeping current model " +
                        "\(agent.config.model); only the conversation was restored"))
                }
            } catch { print(AgentUI.errorText("error: \(error)")) }
        case "/retry":
            await retryTask(with: &agent, messages: &messages, retryAvailable: &retryAvailable)
        default:
            print(AgentUI.warn("unknown command \(command); /help for commands"))
        }
    }
}