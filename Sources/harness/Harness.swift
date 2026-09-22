import Foundation

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
    /retry            re-send the last task (e.g. after an API error)
    /exit             quit (also: Ctrl-D)
    Anything else you type becomes the next task for the agent.
    End a line with \\ to continue on the next line.
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
                  --once TASK       run a single task non-interactively, then exit
                  --reasoning EFF   reasoning effort for thinking models (none|low|medium|high|max)
                  --selftest        exercise the tool layer without any API call
                  --e2e             stub-model loop tests + a live round-trip
                  --version         print the version and exit
            """)
            return
        }

        let config = Config.resolve(arguments: arguments)
        banner(config)

        var messages: [Message] = [.system(systemPrompt(for: config))]
        var agent = Agent(config: config, model: OpenAICompatClient(config: config))

        // Non-interactive single task (handy for testing and scripting):
        //   harness --once "build and test"
        // Runs ONE task through the loop, then exits. The & passes let the
        // agent mutate the conversation history in place.
        if let taskIndex = arguments.firstIndex(of: "--once"),
           arguments.indices.contains(taskIndex + 1) {
            await runTask(arguments[taskIndex + 1], with: &agent, messages: &messages)
            return
        }

        // ---- Interactive REPL ------------------------------------------------
        // readLine() only delivers ONE line, so multi-line input uses a
        // continuation rule: a trailing backslash splices the next line in.
        // `input` accumulates the splice; the loop resets it after dispatch.
        var input = ""
        while true {
            let prompt = input.isEmpty ? "\(AgentUI.bold)you › \(AgentUI.reset)" : "  … › "
            print(prompt, terminator: "")
            fflush(stdout)  // prompt has no newline — flush it explicitly
            guard let line = readLine() else { print(); break }  // Ctrl-D = EOF
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
                await handleCommand(text, &agent, &messages)
            } else {
                await runTask(text, with: &agent, messages: &messages)
            }
        }
    }

    /// Drive one task through the loop and autosave the session afterwards.
    /// Errors (API down, turn cap hit) are printed but do NOT kill the REPL —
    /// the history is preserved so /retry can re-send the last task.
    static func runTask(_ task: String, with agent: inout Agent, messages: inout [Message]) async {
        do {
            try await agent.run(task: task, messages: &messages)
            try? agent.saveSession(messages: messages)  // best-effort autosave
        } catch {
            print(AgentUI.errorText("error: \(error)"))
        }
    }

    /// Slash commands. Note how little state a REPL needs: the conversation
    /// (messages) + configuration (agent). Everything else is derivable.
    static func handleCommand(_ input: String, _ agent: inout Agent, _ messages: inout [Message]) async {
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
            print(AgentUI.dim("conversation reset"))
        case "/model":
            if argument.isEmpty {
                print(AgentUI.dim("model: \(agent.config.model)"))
            } else {
                agent.config.model = argument
                print(AgentUI.dim("model → \(argument)"))
            }
        case "/tools":
            for tool in Tools.all { print(AgentUI.dim("  \(tool.name) — \(tool.description)")) }
        case "/models":
            // Lists what the CURRENT provider offers (GET {baseURL}/models) —
            // with Ollama Cloud that's the whole cloud catalog.
            do {
                let models = try await OpenAICompatClient(config: agent.config).listModels()
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
                agent.config.model = session.model
                print(AgentUI.dim("loaded \(session.messages.count) messages (\(session.model))"))
            } catch { print(AgentUI.errorText("error: \(error)")) }
        case "/retry":
            // Drop the trailing user message (if any) and re-run the last task.
            if let last = messages.last, last.role == "user", last.content != nil {
                messages.removeLast()
                let task = last.content ?? ""
                print(AgentUI.dim("retrying: \(task)"))
                await runTask(task, with: &agent, messages: &messages)
            } else {
                print(AgentUI.warn("nothing to retry"))
            }
        default:
            print(AgentUI.warn("unknown command \(command); /help for commands"))
        }
    }
}