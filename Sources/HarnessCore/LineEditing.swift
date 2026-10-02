import Foundation

// ---------------------------------------------------------------------------
// LineEditing.swift — pure buffer edits for the REPL's raw-mode line editor.
//
// AtCompletion.readLine() disables ICANON/ECHO and re-implements line editing
// byte by byte, which means the kernel's line-discipline keys (Ctrl-U, Ctrl-W,
// …) no longer happen on their own — the editor must honour them. Keeping the
// edits here as pure [UInt8] transforms makes them unit-testable without a TTY
// (the executable target itself cannot be imported by tests).
//
// The editor has no cursor: input is always appended at, and edited from, the
// end of the line. "Kill" therefore means "discard the tail".
// ---------------------------------------------------------------------------

public enum LineEditing {
    /// Drop the last whole UTF-8 scalar — a continuation byte alone would leave
    /// invalid UTF-8 behind, so back up over the whole sequence.
    public static func deleteBackward(_ buffer: inout [UInt8]) {
        while let last = buffer.last, last & 0b1100_0000 == 0b1000_0000 {
            buffer.removeLast()
        }
        if !buffer.isEmpty { buffer.removeLast() }
    }

    /// Ctrl-U (unix-line-discard) / Ctrl-K: discard the line. With the cursor
    /// pinned to the end, both are "clear the buffer".
    public static func killLine(_ buffer: inout [UInt8]) {
        buffer.removeAll()
    }

    /// Ctrl-W (unix-word-rubout): drop trailing blanks, then the word before
    /// them. A no-op on an empty or all-blank line.
    public static func killWord(_ buffer: inout [UInt8]) {
        while let last = buffer.last, isBlank(last) { buffer.removeLast() }
        while let last = buffer.last, !isBlank(last) { buffer.removeLast() }
    }

    private static func isBlank(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }
}
