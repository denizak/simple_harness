import Foundation

// ---------------------------------------------------------------------------
// Tools.swift — the hands of the agent.
//
// The model can only *reason*; tools are how it acts on the world. Five tools
// are enough for a coding agent (this is roughly pi's and Claude Code's core
// set plus a native grep):
//
//   bash        — run shell commands (build, test, ls, git, ...)
//   grep        — regex search across files (faster than bash + grep:
//                  one tool round-trip instead of a subshell)
//   read_file   — read a file (with offset/limit for big files)
//   write_file  — create or overwrite a file
//   edit_file   — exact string replacement (the safe way to change code)
//
// Each tool is (name, description, JSON schema, executor). The executor gets
// the parsed arguments and returns a String that is fed back into the
// conversation as a `tool` message. Errors are *returned as text*, not
// thrown — the model should see the failure and retry intelligently.
// ---------------------------------------------------------------------------

enum Tools {
    static let all: [ToolSpec] = [bash, grep, readFile, writeFile, editFile, spawnAgent]

    /// Look up a tool by name; nil if the model invented one.
    static func named(_ name: String) -> ToolSpec? { all.first { $0.name == name } }

    // -----------------------------------------------------------------------
    // bash
    // -----------------------------------------------------------------------
    static let bash = ToolSpec(
        name: "bash",
        description: "Run a shell command (zsh). Use for listing files, running builds/tests, git, etc. " +
                     "Working directory is the harness cwd. Output is truncated. " +
                     "Prefer focused commands; avoid interactive commands.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("The shell command to run"),
                ]),
                "timeout_seconds": .object([
                    "type": .string("integer"),
                    "description": .string("Kill the command after this many seconds (default 120)"),
                ]),
            ]),
            "required": .array([.string("command")]),
        ])
    ) { arguments, context in
        guard let command = arguments["command"]?.stringValue, !command.isEmpty else {
            return "error: 'command' (string) is required"
        }
        let timeout = Double(arguments["timeout_seconds"]?.intValue ?? 120)
        return await runShell(command: command, cwd: context.cwd, timeout: timeout)
    }

    /// Spawn /bin/zsh -lc <cmd>, capture stdout+stderr, kill on timeout.
    /// Async + detached so a long command never blocks the cooperative pool.
    static func runShell(command: String, cwd: String, timeout: Double) async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do { try process.run() } catch {
                return "error spawning shell: \(error.localizedDescription)"
            }

            // Watchdog: after the deadline, terminate, then hard-kill.
            let deadline = Date().addingTimeInterval(timeout)
            DispatchQueue.global().async {
                while process.isRunning && Date() < deadline {
                    usleep(100_000)
                }
                if process.isRunning {
                    process.terminate()
                    usleep(500_000)
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }

            // Reading to EOF blocks until the child closes its pipes (i.e. it
            // exits or is killed by the watchdog above) — do this BEFORE
            // waitUntilExit to avoid the classic pipe-buffer deadlock.
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let out = String(data: outData, encoding: .utf8) ?? "<binary stdout>"
            let err = String(data: errData, encoding: .utf8) ?? "<binary stderr>"
            let code = Int(process.terminationStatus)

            var report = "exit code: \(code)"
            if process.terminationReason == .uncaughtSignal {
                report += " (killed by signal — timeout?)"
            }
            if !out.isEmpty { report += "\nstdout:\n\(out)" }
            if !err.isEmpty { report += "\nstderr:\n\(err)" }
            if out.isEmpty && err.isEmpty && code == 0 { report += " (no output)" }
            return report
        }.value
    }

    // -----------------------------------------------------------------------
    // grep — native regex search (no subshell needed).
    //
    // Why not just `bash grep`? A dedicated tool is ONE round-trip (no
    // subshell + shell-quoting pitfalls), and the model gets a predictable
    // output shape: `path:line: text`. pi ships the same idea (its `fff`
    // search). Implementation: NSRegularExpression + a FileManager
    // enumerator that skips noisy directories and binary-looking files.
    // -----------------------------------------------------------------------
    /// Directories that never contain useful source.
    private static let grepSkippedDirs: Set<String> = [
        ".git", ".build", ".harness", ".swiftpm", "node_modules",
    ]
    /// Files larger than this are presumed binary/huge and skipped.
    private static let grepMaxFileBytes = 1_000_000

    static let grep = ToolSpec(
        name: "grep",
        description: "Search file contents with a regular expression (ICU syntax, case-sensitive like " +
                     "real grep). Searches one file or recursively from a directory; matches come back " +
                     "as path:line: text. Prefer this over running grep in bash — faster, predictable shape.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "description": .string("Regular expression to search for"),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("File or directory to search (default: current directory)"),
                ]),
                "ignore_case": .object([
                    "type": .string("boolean"),
                    "description": .string("Case-insensitive matching, like grep -i (default false)"),
                ]),
                "max_matches": .object([
                    "type": .string("integer"),
                    "description": .string("Stop after this many matches (default 50)"),
                ]),
            ]),
            "required": .array([.string("pattern")]),
        ])
    ) { arguments, context in
        guard let pattern = arguments["pattern"]?.stringValue, !pattern.isEmpty else {
            return "error: 'pattern' (string) is required"
        }
        let ignoreCase = arguments["ignore_case"]?.boolValue ?? false
        let maxMatches = arguments["max_matches"]?.intValue ?? 50

        var regexOptions: NSRegularExpression.Options = []
        if ignoreCase { regexOptions.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else {
            return "error: invalid regular expression '\(pattern)'"
        }

        // Resolve the search root (absolute paths ignore `relativeTo`).
        let cwdURL = URL(fileURLWithPath: context.cwd)
        let baseURL = URL(fileURLWithPath: arguments["path"]?.stringValue ?? ".",
                          relativeTo: cwdURL).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: baseURL.path, isDirectory: &isDirectory) else {
            return "error: no such path: \(baseURL.path)"
        }

        // Collect candidate files. For directories, walk with an enumerator
        // and prune noisy trees with skipDescendants() so we never descend
        // into .build or node_modules at all.
        let files: [URL]
        if isDirectory.boolValue {
            let enumerator = FileManager.default.enumerator(
                at: baseURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
            )
            var collected: [URL] = []
            while let url = enumerator?.nextObject() as? URL {
                if grepSkippedDirs.contains(url.lastPathComponent) {
                    enumerator?.skipDescendants()
                    continue
                }
                collected.append(url)
            }
            files = collected
        } else {
            files = [baseURL]
        }

        var matches: [String] = []
        for file in files {
            guard matches.count < maxMatches else { break }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile != false else { continue }  // dirs, symlinks to dirs
            if let bytes = values?.fileSize, bytes > grepMaxFileBytes { continue }
            // String(contentsOf:) fails on binary data — that failure is our
            // free "is this text?" filter, so a failed decode just skips the file.
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }

            let displayPath = file.path.hasPrefix(cwdURL.path + "/")
                ? String(file.path.dropFirst(cwdURL.path.count + 1))
                : file.path
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: String(line), range: fullRange) != nil {
                    matches.append("\(displayPath):\(index + 1): \(line.prefix(200))")
                    if matches.count >= maxMatches { break }
                }
            }
        }

        if matches.isEmpty { return "no matches for '\(pattern)'" }
        var report = matches.joined(separator: "\n")
        if matches.count >= maxMatches { report += "\n… stopped at \(maxMatches) matches" }
        return report
    }

    // -----------------------------------------------------------------------
    // read_file
    // -----------------------------------------------------------------------
    static let readFile = ToolSpec(
        name: "read_file",
        description: "Read a text file. Returns numbered lines. Use offset/limit for large files " +
                     "(default: first 2000 lines).",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("File path (relative or absolute)"),
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "description": .string("1-based first line to read"),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max lines to return (default 2000)"),
                ]),
            ]),
            "required": .array([.string("path")]),
        ])
    ) { arguments, _ in
        guard let path = arguments["path"]?.stringValue else {
            return "error: 'path' (string) is required"
        }
        let offset = max(1, arguments["offset"]?.intValue ?? 1)
        let limit = arguments["limit"]?.intValue ?? 2000

        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard offset <= lines.count else {
                return "file has \(lines.count) lines; offset \(offset) is past the end"
            }
            let slice = lines.dropFirst(offset - 1).prefix(limit)
            let numbered = slice.enumerated().map { index, line in
                String(format: "%6d  %@", offset + index, String(line))
            }.joined(separator: "\n")
            let more = offset - 1 + slice.count < lines.count
                ? "\n... (file has \(lines.count) lines; use offset/limit to read more)"
                : ""
            return numbered + more
        } catch {
            return "error reading \(path): \(error.localizedDescription)"
        }
    }

    // -----------------------------------------------------------------------
    // write_file
    // -----------------------------------------------------------------------
    static let writeFile = ToolSpec(
        name: "write_file",
        description: "Create or overwrite a file with the given content. " +
                     "Parent directories are created if missing.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string"), "description": .string("File path")]),
                "content": .object(["type": .string("string"), "description": .string("Full file content")]),
            ]),
            "required": .array([.string("path"), .string("content")]),
        ])
    ) { arguments, _ in
        guard let path = arguments["path"]?.stringValue else { return "error: 'path' (string) is required" }
        guard let content = arguments["content"]?.stringValue else { return "error: 'content' (string) is required" }

        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return "wrote \(content.utf8.count) bytes to \(path)"
        } catch {
            return "error writing \(path): \(error.localizedDescription)"
        }
    }

    // -----------------------------------------------------------------------
    // edit_file
    // -----------------------------------------------------------------------
    static let editFile = ToolSpec(
        name: "edit_file",
        description: "Replace an exact string in a file. old_text must match exactly and be unique in the " +
                     "file (set replace_all=true to replace every occurrence). If it is not found or " +
                     "appears more than once, the file is left unchanged and you get an error back — " +
                     "read_file first, then retry with more surrounding context.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object(["type": .string("string"), "description": .string("File path")]),
                "old_text": .object([
                    "type": .string("string"),
                    "description": .string("Exact text to find (must be unique unless replace_all)"),
                ]),
                "new_text": .object(["type": .string("string"), "description": .string("Replacement text")]),
                "replace_all": .object([
                    "type": .string("boolean"),
                    "description": .string("Replace every occurrence (default false)"),
                ]),
            ]),
            "required": .array([.string("path"), .string("old_text"), .string("new_text")]),
        ])
    ) { arguments, _ in
        guard let path = arguments["path"]?.stringValue else { return "error: 'path' (string) is required" }
        guard let oldText = arguments["old_text"]?.stringValue else { return "error: 'old_text' (string) is required" }
        guard let newText = arguments["new_text"]?.stringValue else { return "error: 'new_text' (string) is required" }
        let replaceAll = arguments["replace_all"]?.boolValue ?? false

        do {
            let original = try String(contentsOfFile: path, encoding: .utf8)
            guard original.contains(oldText) else {
                return "error: old_text not found in \(path). read_file and retry with the exact text."
            }
            if !replaceAll {
                let count = original.components(separatedBy: oldText).count - 1
                guard count == 1 else {
                    return "error: old_text appears \(count) times in \(path); " +
                           "include more surrounding context to make it unique."
                }
            }
            let updated = original.replacingOccurrences(of: oldText, with: newText)
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
            return "edited \(path)"
        } catch {
            return "error editing \(path): \(error.localizedDescription)"
        }
    }

    // -----------------------------------------------------------------------
    // spawn_agent — orchestration.
    //
    // The model can delegate a self-contained subtask to a FRESH agent (same
    // provider and tools, but an empty conversation). Why? Bulk work —
    // "read these 12 files and summarize" — would flood this conversation;
    // a sub-agent burns its own context and returns only the report. This is
    // pi's sub-agents in miniature, with the same two guardrails:
    //   * depth cap (config.maxAgentDepth) so recursion terminates
    //   * failures are TEXT — the parent reads the failure and adapts
    // -----------------------------------------------------------------------
    static let spawnAgent = ToolSpec(
        name: "spawn_agent",
        description: "Delegate a focused, self-contained subtask to a fresh sub-agent. " +
                     "It runs with the same provider, tools and working directory but an empty " +
                     "conversation, and returns only its final report. Use it for research or " +
                     "bulk work that would flood this conversation; do NOT use it for trivial steps.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "task": .object([
                    "type": .string("string"),
                    "description": .string("Complete, self-contained instructions (the sub-agent sees nothing else)"),
                ]),
            ]),
            "required": .array([.string("task")]),
        ])
    ) { arguments, context in
        guard let task = arguments["task"]?.stringValue, !task.isEmpty else {
            return "error: 'task' (string) is required"
        }
        guard context.depth < context.config.maxAgentDepth else {
            return "error: spawn depth limit reached (\(context.config.maxAgentDepth)). " +
                   "No more nesting — do the remaining work yourself."
        }
        print(AgentUI.dim("  \u{27F3} spawning sub-agent (depth \(context.depth + 1))"))

        var subConfig = context.config
        subConfig.maxTurns = min(subConfig.maxTurns, 15)  // tighter cap than the parent
        var subMessages: [Message] = [
            .system("You are a sub-agent spawned for one delegated task. Complete it in the " +
                    "current working directory using the tools, then reply with a concise " +
                    "final report. Current directory: \(context.cwd)")
        ]
        var subAgent = Agent(config: subConfig, model: context.model, depth: context.depth + 1)
        do {
            try await subAgent.run(task: task, messages: &subMessages)
        } catch {
            return "sub-agent failed: \(error)"
        }
        let report = subMessages.last?.content ?? "(sub-agent returned no text)"
        return "SUB-AGENT REPORT:\n\(report)"
    }
}