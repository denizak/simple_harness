import Testing
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@testable import HarnessCore

@Suite("Bounded shell runner")
struct ShellRunnerTests {
    @Test("stderr is drained while stdout remains open")
    func concurrentDrain() async {
        let result = await Tools.runShell(command: "yes x | head -c 1000000 >&2; echo stdout-after", cwd: ".", timeout: 8)
        #expect(result.contains("stdout-after"))
        #expect(result.contains("stderr truncated; discarded"))
        #expect(result.contains("exit code: 0"))
    }

    @Test("stdout and stderr retention are bounded with byte counts")
    func boundedOutput() async {
        let result = await Tools.runShell(command: "yes o | head -c 200000; yes e | head -c 200000 >&2", cwd: ".", timeout: 8)
        #expect(result.contains("stdout truncated; discarded"))
        #expect(result.contains("stderr truncated; discarded"))
        #expect(result.utf8.count < 140_000)
    }

    @Test("timeout kills shell process group, including ordinary child")
    func processGroupTimeout() async {
        let marker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let command = "sleep 20 & child=$!; echo $child > '\(marker.path)'; wait"
        let start = Date()
        let result = await Tools.runShell(command: command, cwd: ".", timeout: 1)
        #expect(result.contains("timed out"))
        #expect(Date().timeIntervalSince(start) < 5)
        if let pidText = try? String(contentsOf: marker, encoding: .utf8), let child = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            #expect(kill(child, 0) != 0)
        }
        try? FileManager.default.removeItem(at: marker)
    }

    @Test("TERM-resistant shell reaches KILL and invalid cwd reports a spawn error")
    func hardKillAndSpawnFailure() async {
        let start = Date()
        let resistant = await Tools.runShell(command: "trap '' TERM; sleep 20", cwd: ".", timeout: 1)
        #expect(resistant.contains("timed out"))
        #expect(Date().timeIntervalSince(start) < 5)
        let badCwd = await Tools.runShell(command: "echo no", cwd: "/definitely/not/a/real/directory", timeout: 1)
        #expect(badCwd.contains("error spawning shell"))
    }
}
