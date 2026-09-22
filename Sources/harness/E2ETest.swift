import Foundation
import HarnessCore

// ---------------------------------------------------------------------------
// E2ETest.swift — LIVE verification legs only (network + real APIs).
//
// The OFFLINE layers (stub-model loop, compaction mid-task, sub-agent
// delegation) moved to Tests/HarnessTests — they're deterministic and run
// under `swift test`. This file keeps only what a stub can't verify:
//   * a live chat round-trip against the resolved provider
//   * the TypeSafe judge wire contract against the live API
// behind `--e2e`, because both cost real quota and need network.
// ---------------------------------------------------------------------------

enum E2ETest {
    static func run() async {
        print("e2e [live]: round-trip against the configured provider")
        var failures = await liveRoundTrip()

        print("e2e [live]: TypeSafe judge")
        failures += await liveTypeSafeJudge()

        print(failures == 0 ? "e2e: all passed" : AgentUI.errorText("e2e: \(failures) failure(s)"))
        exit(failures == 0 ? 0 : 1)
    }

    /// A real request against the configured provider. Deliberately tiny:
    /// one bash echo, expect the output somewhere in the conversation.
    private static func liveRoundTrip() async -> Int {
        var failures = 0
        let config = Config.resolve(arguments: [])
        var agent = Agent(config: config, model: OpenAICompatClient(config: config))
        var messages: [Message] = [.system(systemPrompt(for: config))]

        print(AgentUI.dim("  [\(config.provider) / \(config.model) @ \(config.baseURL)]"))
        do {
            try await agent.run(task: "Use bash to run exactly: echo e2e-live-ok", messages: &messages)
            let sawIt = messages.contains { $0.content?.contains("e2e-live-ok") ?? false }
            if sawIt {
                print("  ✓ live round-trip (tool ran, output reached the conversation)")
            } else {
                failures += 1
                print(AgentUI.errorText("  ✗ live round-trip: 'e2e-live-ok' never appeared"))
            }
        } catch {
            failures += 1
            print(AgentUI.errorText("  ✗ live round-trip failed: \(error)"))
            print(AgentUI.warn(
                "    is a provider reachable? set OLLAMA_API_KEY / OPENAI_API_KEY / ZAI_API_KEY or run a local server"
            ))
        }
        return failures
    }

    /// One real TypeSafe judgment (tiny, ~300 input tokens) — exercises the
    /// judge tool's wire contract against the live API. Skipped when no key.
    private static func liveTypeSafeJudge() async -> Int {
        var failures = 0
        guard let apiKey = Config.resolve(arguments: []).typesafeApiKey else {
            print(AgentUI.dim("  – TypeSafe judge skipped (TYPESAFE_API_KEY not set)"))
            return 0
        }
        do {
            let root = try await TypeSafeClient.evaluate(
                state: "Checkout has been broken since 6am; customers cannot complete orders.",
                questions: [TypeSafeQuestion(
                    id: "urgent", type: "noul",
                    instructions: "Is this situation urgent?",
                    criteria: .object([
                        "true": .string("Time-sensitive outage affecting customers"),
                        "false": .string("No urgency expressed"),
                    ]))],
                apiKey: apiKey)
            let rendered = TypeSafeClient.format(root)
            let firstLine = rendered.split(separator: "\n").first.map(String.init) ?? ""
            if rendered.contains("urgent") {
                print("  ✓ TypeSafe judge live — \(firstLine)")
            } else {
                failures += 1
                print(AgentUI.errorText("  ✗ TypeSafe judge live: unexpected answer — \(rendered)"))
            }
        } catch {
            failures += 1
            print(AgentUI.errorText("  ✗ TypeSafe judge live failed: \(error)"))
        }
        return failures
    }
}