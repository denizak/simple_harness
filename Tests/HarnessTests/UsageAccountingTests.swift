import Testing
import Foundation
@testable import HarnessCore

@Suite("Usage accounting")
struct UsageAccountingTests {
    private func makeAgent(provider: String, model: String) -> Agent {
        let config = Config.resolve(arguments: [], env: ["HARNESS_PROVIDER": provider,
                                                         "HARNESS_MODEL": model],
                                    pi: .init(), file: [:])
        return Agent(config: config, model: OpenAICompatClient(config: config))
    }

    @Test("usageSummary: totals accumulate, context is the last turn, reset clears")
    func totalsAndReset() {
        var agent = makeAgent(provider: "deepseek", model: "deepseek-flash")
        #expect(agent.usageSummary() == "0 tokens so far")  // no window → no ratio
        agent.recordUsage(promptTokens: 100, completionTokens: 10)
        agent.recordUsage(promptTokens: 130, completionTokens: 20)  // context resets, not sums
        #expect(agent.usageSummary() == "260 tokens so far")
        agent.resetUsage()
        #expect(agent.usageSummary() == "0 tokens so far")
    }

    @Test("usageSummary: known window shows context/max and warns past the compaction threshold")
    func knownWindow() {
        var agent = makeAgent(provider: "zai", model: "glm-4.6")
        agent.recordUsage(promptTokens: 99_000, completionTokens: 1_000)
        #expect(agent.usageSummary() == "100000 tokens so far — context 100000/200000 (50%)")
        agent.recordUsage(promptTokens: 170_000, completionTokens: 0)
        #expect(agent.usageSummary().hasSuffix("(85%) ⚠︎"))
    }

    @Test("HARNESS_CONTEXT_WINDOW overrides the catalog; 0 suppresses the ratio")
    func envOverride() {
        let base = ["HARNESS_PROVIDER": "zai"]
        var overriddenEnv = base
        overriddenEnv["HARNESS_CONTEXT_WINDOW"] = "123456"
        let overridden = Config.resolve(arguments: [], env: overriddenEnv, pi: .init(), file: [:])
        #expect(overridden.contextWindow == 123_456)

        var zeroEnv = base
        zeroEnv["HARNESS_CONTEXT_WINDOW"] = "0"
        let suppressed = Config.resolve(arguments: [], env: zeroEnv, pi: .init(), file: [:])
        #expect(suppressed.contextWindow == nil)

        let catalogDefault = Config.resolve(arguments: [], env: base, pi: .init(), file: [:])
        #expect(catalogDefault.contextWindow == 200_000)
        let notDocumented = Config.resolve(arguments: [], env: ["HARNESS_PROVIDER": "deepseek"],
                                           pi: .init(), file: [:])
        #expect(notDocumented.contextWindow == nil)
    }

    @Test("catalog windows: exact model match beats provider default; unknown model → nil")
    func catalogLookup() {
        let openai = Config.catalog["openai"]!
        #expect(openai.contextWindow(for: "gpt-4o") == 128_000)
        #expect(openai.contextWindow(for: "gpt-99") == nil)  // not documented → unknown
        let zai = Config.catalog["zai"]!
        #expect(zai.contextWindow(for: "glm-9.9") == 200_000)  // family default
    }
}
