import Foundation
import ShellProcess
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private final class BoundedPipeReader: @unchecked Sendable {
    private let descriptor: Int32
    private let limit: Int
    private let lock = NSLock()
    private(set) var data = Data()
    private(set) var discarded = 0
    let finished = DispatchSemaphore(value: 0)

    init(descriptor: Int32, limit: Int) {
        self.descriptor = descriptor
        self.limit = limit
    }

    func start() {
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { finished.signal() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = buffer.withUnsafeMutableBytes { raw in
                    read(descriptor, raw.baseAddress, raw.count)
                }
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                append(buffer, count)
            }
        }
    }

    private func append(_ buffer: [UInt8], _ count: Int) {
        lock.lock()
        let retained = min(count, max(0, limit - data.count))
        if retained > 0 { data.append(contentsOf: buffer.prefix(retained)) }
        discarded += count - retained
        lock.unlock()
    }

    func snapshot() -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        return (data, discarded)
    }

    /// Drain whatever the async reader hasn't consumed yet. Called on the
    /// runner thread after the process group is dead: the writers are gone,
    /// so the pipe holds a finite buffer. This keeps output capture
    /// deterministic even when the QoS-starved dispatch queue never got
    /// scheduled inside the join timeout (seen on loaded CI runners).
    /// Flipping the fd to non-blocking also stops the async reader cleanly;
    /// a concurrent read() on a pipe is safe (reads are atomic per chunk).
    func drainRemaining() {
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }
            if count > 0 { append(buffer, count); continue }
            // EINTR: a delivered signal must not end the drain — retry.
            // EAGAIN: the async reader consumed the rest; EOF: done.
            if count < 0 && errno == EINTR { continue }
            break
        }
    }
}

/// Runs one shell in its own POSIX process group. Output is drained from both
/// pipes concurrently and only a bounded prefix is retained.
public enum ShellRunner {
    private static let outputLimit = 64 * 1024

    public static func run(command: String, cwd: String, timeout: Double) async -> String {
        await Task.detached { runSynchronously(command: command, cwd: cwd, timeout: timeout) }.value
    }

    private static func runSynchronously(command: String, cwd: String, timeout: Double) -> String {
        #if os(Linux)
        let shell = "/bin/bash"
        #else
        let shell = "/bin/zsh"
        #endif
        var pid: pid_t = 0
        var outFD: Int32 = -1
        var errFD: Int32 = -1
        let spawnStatus = shell.withCString { shellPtr in
            cwd.withCString { cwdPtr in
                command.withCString { commandPtr in
                    harness_spawn_shell(shellPtr, cwdPtr, commandPtr, &pid, &outFD, &errFD)
                }
            }
        }
        guard spawnStatus == 0 else {
            return "error spawning shell: \(String(cString: strerror(spawnStatus)))"
        }

        let stdout = BoundedPipeReader(descriptor: outFD, limit: outputLimit)
        let stderr = BoundedPipeReader(descriptor: errFD, limit: outputLimit)
        stdout.start()
        stderr.start()

        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        var timedOut = false
        var childExited = false
        while !childExited {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                childExited = true
            } else if result < 0 && errno != EINTR {
                childExited = true
            } else if Date() >= deadline {
                timedOut = true
                _ = kill(-pid, SIGTERM)
                let graceDeadline = Date().addingTimeInterval(0.5)
                while Date() < graceDeadline {
                    if waitpid(pid, &status, WNOHANG) == pid { childExited = true; break }
                    usleep(20_000)
                }
                _ = kill(-pid, SIGKILL)
                if !childExited {
                    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                    childExited = true
                }
            } else {
                usleep(20_000)
            }
        }

        // The leader may have exited while a background descendant still
        // holds the pipes. Clean up only this run's process group.
        if !timedOut {
            _ = kill(-pid, SIGTERM)
            usleep(50_000)
            _ = kill(-pid, SIGKILL)
        }
        // Brief courtesy join for the async pump; anything it didn't get to
        // is recovered by the deterministic sync drain below, so a starved
        // dispatch queue only costs a fraction of a second, never output.
        _ = stdout.finished.wait(timeout: .now() + 0.25)
        _ = stderr.finished.wait(timeout: .now() + 0.25)
        stdout.drainRemaining()
        stderr.drainRemaining()
        close(outFD)
        close(errFD)

        let outSnapshot = stdout.snapshot()
        let errSnapshot = stderr.snapshot()
        let out = String(data: outSnapshot.0, encoding: .utf8) ?? "<binary stdout>"
        let err = String(data: errSnapshot.0, encoding: .utf8) ?? "<binary stderr>"
        let exitCode = (status & 0x7f) == 0 ? Int((status >> 8) & 0xff) : -1
        let signal = Int(status & 0x7f)

        var report = "exit code: \(exitCode)"
        if timedOut { report += " (timed out)" }
        if signal != 0 && signal != 0x7f { report += " (killed by signal \(signal))" }
        if !out.isEmpty { report += "\nstdout:\n\(out)" }
        if outSnapshot.1 > 0 { report += "\n...[stdout truncated; discarded \(outSnapshot.1) bytes]" }
        if !err.isEmpty { report += "\nstderr:\n\(err)" }
        if errSnapshot.1 > 0 { report += "\n...[stderr truncated; discarded \(errSnapshot.1) bytes]" }
        if out.isEmpty && err.isEmpty && exitCode == 0 { report += " (no output)" }
        return report
    }
}
