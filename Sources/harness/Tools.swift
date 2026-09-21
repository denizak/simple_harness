import Foundation

// ---------------------------------------------------------------------------
// Tools.swift — the hands of the agent.
//
// The model can only *reason*; tools are how it acts on the world. Four tools
// are enough for a coding agent (this is roughly pi's and Claude Code's core
// set):
//
//   bash        — run shell commands (build, test, ls, git, ...)
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
    static let all: [ToolSpec] = [bash, readFile, writeFile, editFile]

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
    ) { arguments, _ in
        guard let command = arguments["command"]?.stringValue, !command.isEmpty else {
            return "error: 'command' (string) is required"
        }
        let timeout = Double(arguments["timeout_seconds"]?.intValue ?? 120)
        return await runShell(command: command, timeout: timeout)
    }

    /// Spawn /bin/zsh -lc <cmd>, capture stdout+stderr, kill on timeout.
    /// Async + detached so a long command never blocks the cooperative pool.
    static func runShell(command: String, timeout: Double) async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath)

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
}