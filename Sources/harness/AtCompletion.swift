import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// ---------------------------------------------------------------------------
// AtCompletion.swift — "@" file completion for the REPL prompt.
//
// readLine() can't react to individual keystrokes, so when stdin is a TTY we
// take the terminal into raw mode (ICANON+ECHO off — every byte is ours) and
// re-implement just enough line editing: append, backspace (UTF-8-aware),
// Ctrl-U/Ctrl-K (kill line), Ctrl-W (kill word), Tab (complete to the common
// prefix), Enter, Ctrl-C (cancel line), Ctrl-D (EOF). Arrows and other escape
// sequences are consumed and ignored.
//
// Raw mode also means the kernel no longer applies the line-discipline keys
// above, so they MUST be handled here: swallowing Ctrl-U, for instance, turns
// "@REA" + Ctrl-U + "/exit" into the literal task "@REA/exit".
//
// The completion rule: the text after the last unspaced "@" in the buffer is
// a file-token; matching files under the working directory are listed below
// the prompt and re-filtered on every keystroke (case-insensitive "contains"
// on path or filename). An empty token lists everything. No "@" → plain line
// editing, no list.
//
// Non-TTY stdin (pipes, --e2e, tests) falls back to plain readLine().
// ISIG stays ON, so Ctrl-C still raises SIGINT — if the process dies hard
// the tty can be left in raw mode; `stty sane` restores it.
// ---------------------------------------------------------------------------

enum AtCompletion {
    /// Directories whose contents never belong in the completion index.
    private static let skippedDirectories = [".git", ".build", ".zcode", "node_modules", "DerivedData"]
    private static let maxListed = 8
    private static let maxIndexedFiles = 5_000

    /// Replacement for readLine() in the REPL loop. Returns the finished line,
    /// or nil on EOF (Ctrl-D on an empty line).
    static func readLine(prompt: String) -> String? {
        guard isatty(STDIN_FILENO) == 1, enableRawMode() else {
            print(prompt, terminator: "")
            fflush(nil)  // fflush(NULL) flushes all streams; `stdout` is not concurrency-safe in Swift 6
            return Swift.readLine()
        }
        defer { disableRawMode() }

        var buffer: [UInt8] = []
        var listedLines = 0
        var selected = -1  // highlighted row in the completion list, -1 = none
        let files = fileIndex()
        write(prompt)

        while true {
            var byte: UInt8 = 0
            guard read(STDIN_FILENO, &byte, 1) == 1 else { write("\r\n"); return nil }
            var bufferChanged = false
            switch byte {
            case 0x03:  // Ctrl-C — abandon the line, stay in the REPL
                write("\r\n")
                return ""
            case 0x04:  // Ctrl-D — EOF only on an empty line
                if buffer.isEmpty { write("\r\n"); return nil }
            case 0x0A, 0x0D:  // Enter — with a highlighted row: accept it; otherwise accept the line
                let shown = shownMatches(files: files, buffer: buffer).shown
                if selected >= 0 && selected < shown.count,
                   let token = atToken(in: buffer) {
                    replace(token: token, in: &buffer, with: Array(shown[selected].utf8))
                    selected = -1
                    bufferChanged = true
                } else {
                    write("\r\n")
                    return String(decoding: buffer, as: UTF8.self)
                }
            case 0x7F:  // Backspace — drop the last (whole) UTF-8 character
                while let last = buffer.last, last & 0b1100_0000 == 0b1000_0000 {
                    buffer.removeLast()
                }
                if !buffer.isEmpty { buffer.removeLast() }
                bufferChanged = true
            case 0x15:  // Ctrl-U — kill the whole line
                buffer.removeAll()
                bufferChanged = true
            case 0x09:  // Tab — highlighted row: complete to it; otherwise to the common prefix
                if let token = atToken(in: buffer) {
                    let shown = shownMatches(files: files, buffer: buffer).shown
                    if selected >= 0 && selected < shown.count {
                        replace(token: token, in: &buffer, with: Array(shown[selected].utf8))
                    } else if let completion = commonPrefix(of: matching(files: files, token: token)) {
                        replace(token: token, in: &buffer, with: Array(completion.utf8))
                    }
                    bufferChanged = true
                }
            case 0x1B:  // ESC — control sequence: ↑/↓ move the highlight, others ignored
                var sequence = [UInt8](repeating: 0, count: 2)
                if read(STDIN_FILENO, &sequence, 2) == 2, sequence[0] == 0x5B {
                    let count = shownMatches(files: files, buffer: buffer).shown.count
                    switch sequence[1] {
                    case 0x41: selected = count == 0 ? -1 : max(selected - 1, -1)  // ↑
                    case 0x42: selected = count == 0 ? -1 : min(selected + 1, count - 1)  // ↓
                    default: break
                    }
                }
            case let printable where printable >= 0x20:
                buffer.append(printable)
                bufferChanged = true
            default:
                break  // other control bytes: ignore
            }
            if bufferChanged { selected = -1 }
            let shown = shownMatches(files: files, buffer: buffer)
            redraw(prompt: prompt, buffer: buffer, matches: shown.shown, total: shown.total,
                   selected: selected, listedLines: &listedLines)
        }
    }

    // -- rendering ----------------------------------------------------------

    /// The rows shown under the prompt (unstyled, for selection) and the
    /// total match count, for the "… +N more" overflow line.
    private static func shownMatches(files: [String], buffer: [UInt8]) -> (shown: [String], total: Int) {
        guard let token = atToken(in: buffer) else { return ([], 0) }
        let all = matching(files: files, token: token)
        return (Array(all.prefix(maxListed)), all.count)
    }

    /// Redraw the input line plus the match list below it, then put the
    /// cursor back where the user is typing. Clears stale list lines from
    /// the previous draw.
    private static func redraw(prompt: String, buffer: [UInt8], matches: [String], total: Int,
                               selected: Int, listedLines: inout Int) {
        var out = "\r\u{1B}[K" + prompt + String(decoding: buffer, as: UTF8.self)
        for (index, path) in matches.enumerated() {
            out += "\r\n\u{1B}[K"
            out += index == selected
                ? "\u{1B}[7m  \(path)\u{1B}[0m"
                : AgentUI.dim("  " + path)
        }
        if total > matches.count { out += "\r\n\u{1B}[K" + AgentUI.dim("  … +\(total - matches.count) more") }
        if matches.count < listedLines {
            for _ in 0..<(listedLines - matches.count) { out += "\r\n\u{1B}[K" }
        }
        let drawn = max(matches.count, listedLines)
        if drawn > 0 { out += "\u{1B}[\(drawn)A" }
        out += "\r"
        // Park the cursor after the last typed character, not at column 0.
        out += "\u{1B}[\(Self.displayWidth(of: prompt) + Self.displayWidth(of: String(decoding: buffer, as: UTF8.self)))C"
        listedLines = matches.count
        write(out)
    }

    private static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    /// Characters the terminal actually renders: ANSI escapes stripped,
    /// counting Unicode scalars (good enough for ASCII paths and prompts;
    /// CJK wide chars would still drift, but we don't emit those).
    private static func displayWidth(of text: String) -> Int {
        var width = 0
        var inEscape = false
        for scalar in text.unicodeScalars {
            if inEscape {
                if scalar == "m" { inEscape = false }
            } else if scalar == "\u{1B}" {
                inEscape = true
            } else {
                width += 1
            }
        }
        return width
    }

    // -- matching -----------------------------------------------------------

    /// The text after the last "@" in the buffer, if that "@" exists, has no
    /// space after it, and isn't itself part of an email-style word before it.
    /// nil = no active completion token.
    private static func atToken(in buffer: [UInt8]) -> String? {
        let text = String(decoding: buffer, as: UTF8.self)
        guard let at = text.lastIndex(of: "@") else { return nil }
        let token = String(text[text.index(after: at)...])
        let before = text[text.startIndex..<at].last ?? " "
        guard !token.contains(" "), before == " " || before == "\n" else { return nil }
        return token
    }

    /// Replace the trailing "@token" with "@replacement" (in raw bytes).
    private static func replace(token: String, in buffer: inout [UInt8], with replacement: [UInt8]) {
        buffer.removeLast(Array("@\(token)".utf8).count)
        buffer.append(contentsOf: Array("@".utf8))
        buffer.append(contentsOf: replacement)
    }

    /// Relative paths under the working directory, hidden entries included
    /// (so `.simple.h.conf` completes), junk directories excluded.
    static func fileIndex() -> [String] {
        var files: [String] = []
        guard let enumerator = FileManager.default.enumerator(atPath: ".") else { return files }
        while let path = enumerator.nextObject() as? String, files.count < maxIndexedFiles {
            if skippedDirectories.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                enumerator.skipDescendants()
                continue
            }
            files.append(path)
        }
        return files.sorted()
    }

    /// Case-insensitive "contains" match on filename or full relative path.
    static func matching(files: [String], token: String) -> [String] {
        let needle = token.lowercased()
        guard !needle.isEmpty else { return files }
        return files.filter { path in
            let lowered = path.lowercased()
            return lowered.contains(needle)
                || lowered.split(separator: "/").last?.contains(needle) == true
        }
    }

    private static func commonPrefix(of paths: [String]) -> String? {
        guard var prefix = paths.first else { return nil }
        for path in paths.dropFirst() {
            while !path.hasPrefix(prefix) {
                prefix = String(prefix.dropLast())
                if prefix.isEmpty { return nil }
            }
        }
        // A prefix that equals the only/matched value adds nothing to type.
        return prefix == paths.first && paths.count == 1 ? nil : prefix
    }

    // -- raw mode -----------------------------------------------------------

    // Raw mode is only ever toggled on the REPL's input thread.
    nonisolated(unsafe) private static var savedTermios: termios?

    private static func enableRawMode() -> Bool {
        var term = termios()
        guard tcgetattr(STDIN_FILENO, &term) == 0 else { return false }
        savedTermios = term
        #if canImport(Darwin)
        term.c_lflag &= ~UInt(ECHO | ICANON)
        #else
        term.c_lflag &= ~UInt32(ECHO | ICANON)
        #endif
        term.c_cc.17 = 1  // VMIN — read() returns per byte
        term.c_cc.18 = 0  // VTIME — no inter-byte timeout
        return tcsetattr(STDIN_FILENO, TCSANOW, &term) == 0
    }

    private static func disableRawMode() {
        if var term = savedTermios { tcsetattr(STDIN_FILENO, TCSANOW, &term) }
        savedTermios = nil
    }
}
