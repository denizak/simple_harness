import Foundation

// ---------------------------------------------------------------------------
// UsageLog.swift — machine-readable per-turn usage, opt-in.
//
// The loop prints token usage for humans ("[turn 3: 812 tokens …]") and then
// forgets it. A caller that needs the numbers (the agent eval, scripts around
// `harness --once`) sets `usageLog` / HARNESS_USAGE_LOG, and every model turn
// — including sub-agents, which share the config — appends one JSON line:
//
//   {"depth":0,"prompt":812,"completion":40,"finish":"tool_calls"}
//
// One O_APPEND write per line is atomic, so parent and sub-agents (and
// concurrent processes) can share a file. Failure to write is silent: losing
// a usage line must never stop a run.
// ---------------------------------------------------------------------------

public enum UsageLog {
    public static func append(path: String?, depth: Int, usage: Usage?, finish: String) {
        guard let path else { return }
        let line: [String: JSONValue] = [
            "depth": .number(Double(depth)),
            "prompt": .number(Double(usage?.promptTokens ?? 0)),
            "completion": .number(Double(usage?.completionTokens ?? 0)),
            "finish": .string(finish),
        ]
        guard var data = try? JSONEncoder().encode(JSONValue.object(line)) else { return }
        data.append(0x0A)
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        data.withUnsafeBytes { raw in _ = write(descriptor, raw.baseAddress, raw.count) }
    }

    /// Turns and token totals across every line of a usage log (missing file = zeros).
    public static func totals(path: String) -> (turns: Int, prompt: Int, completion: Int) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return (0, 0, 0) }
        var turns = 0, prompt = 0, completion = 0
        for line in text.split(separator: "\n") {
            guard let object = JSONValue.parse(String(line))?.objectValue else { continue }
            turns += 1
            prompt += object["prompt"]?.intValue ?? 0
            completion += object["completion"]?.intValue ?? 0
        }
        return (turns, prompt, completion)
    }
}
