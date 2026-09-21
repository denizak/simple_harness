import Foundation

// ---------------------------------------------------------------------------
// Config.swift — where configuration comes from.
//
// A "provider" in a harness is just: base URL + API key + model id, all
// speaking the same OpenAI-compatible dialect. This file maps a few well-known
// providers to environment variables and resolves the final configuration.
//
// Resolution order (later wins):
//   1. hardcoded default (local Ollama)
//   2. pi's ~/.pi/agent/models.json (reuse a provider this machine has)
//   3. provider catalog via --provider flag
//   4. environment variables (OPENAI_API_KEY / ZAI_API_KEY / HARNESS_*)
//   5. command-line flags (--base-url/--api-key/--model)
//
// Supported providers out of the box:
//   ollama   local proxy (default; no key needed here)
//   openai   ChatGPT/OpenAI API   → set OPENAI_API_KEY
//   zai      Z.ai (Zhipu GLM)     → set ZAI_API_KEY
// ---------------------------------------------------------------------------

struct ProviderProfile: Sendable {
    var name: String
    var baseURL: String
    var envKeys: [String]        // env vars that hold this provider's API key
    var defaultModel: String

    func key(in env: [String: String]) -> String? {
        envKeys.compactMap { env[$0] }.first
    }
}

struct Config: Sendable {
    var provider: String
    var baseURL: String
    var apiKey: String
    var model: String
    var maxTokens: Int = 4096
    /// Hard cap on model turns per user task (loop safety belt).
    var maxTurns: Int = 25
    /// Truncation limit for tool output fed back to the model (chars).
    var maxToolOutput: Int = 20_000
    /// Compact the history when its byte estimate exceeds this (0 = never).
    /// ~4 bytes ≈ 1 token, so 100_000 ≈ 25k tokens of headroom spent.
    var compactAboveBytes: Int = 100_000
    /// How many recent messages to always keep verbatim when compacting.
    var compactKeepTail: Int = 8

    /// The well-known provider catalog. All of these speak the OpenAI
    /// Chat Completions dialect, so one client covers them all.
    static let catalog: [String: ProviderProfile] = [
        "openai": ProviderProfile(
            name: "openai",
            baseURL: "https://api.openai.com/v1",
            envKeys: ["OPENAI_API_KEY"],
            defaultModel: "gpt-4o-mini"
        ),
        "zai": ProviderProfile(
            name: "zai",
            baseURL: "https://api.z.ai/api/paas/v4",
            envKeys: ["ZAI_API_KEY", "Z_AI_API_KEY", "ZHIPU_API_KEY"],
            defaultModel: "glm-4.6"
        ),
        "ollama": ProviderProfile(
            name: "ollama",
            baseURL: "http://127.0.0.1:11434/v1",
            envKeys: ["HARNESS_API_KEY"],
            defaultModel: "glm-5.3-flash:cloud"
        ),
    ]

    static func resolve(arguments: [String]) -> Config {
        let env = ProcessInfo.processInfo.environment
        var config = Config(
            provider: "ollama",
            baseURL: "http://127.0.0.1:11434/v1",
            apiKey: "none",
            model: "glm-5.3-flash:cloud"
        )

        // 2. Borrow provider config from pi, if present.
        if let pi = piProviderConfig() {
            config = Config(provider: "pi", baseURL: pi.baseURL, apiKey: pi.apiKey, model: pi.model)
        }

        // 3. Provider catalog. --provider X wins; otherwise the first
        // provider with an API key in the environment wins (zai > openai here
        // only to make the order deterministic — set --provider to override).
        let requested = flagValue("--provider", in: arguments)
        if let name = requested ?? env["HARNESS_PROVIDER"], let profile = catalog[name.lowercased()] {
            config = Config(
                provider: profile.name,
                baseURL: profile.baseURL,
                apiKey: profile.key(in: env) ?? "none",
                model: profile.defaultModel
            )
        } else if requested == nil && env["HARNESS_PROVIDER"] == nil {
            if let zai = catalog["zai"], zai.key(in: env) != nil {
                config = apply(zai, env)
            } else if let openai = catalog["openai"], openai.key(in: env) != nil {
                config = apply(openai, env)
            }
        }

        // 4. Environment overrides.
        if let value = env["HARNESS_BASE_URL"] { config.baseURL = value }
        if let value = env["HARNESS_API_KEY"] { config.apiKey = value }
        if let value = env["HARNESS_MODEL"] { config.model = value }
        if let value = env["HARNESS_COMPACT_BYTES"], let parsed = Int(value) {
            config.compactAboveBytes = parsed
        }
        if let value = env["HARNESS_COMPACT_KEEP_TAIL"], let parsed = Int(value) {
            config.compactKeepTail = max(2, parsed)  // tail must stay splittable
        }

        // 5. Explicit flags always win: --base-url/--api-key/--model.
        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            func value(_ flag: String, _ current: String?) -> String? {
                guard arg == flag else { return current }
                return iterator.next() ?? current
            }
            config.model = value("--model", config.model) ?? config.model
            config.baseURL = value("--base-url", config.baseURL) ?? config.baseURL
            config.apiKey = value("--api-key", config.apiKey) ?? config.apiKey
        }
        return config
    }

    private static func apply(_ profile: ProviderProfile, _ env: [String: String]) -> Config {
        Config(
            provider: profile.name,
            baseURL: env["\(profile.name.uppercased())_BASE_URL"] ?? profile.baseURL,
            apiKey: profile.key(in: env) ?? "none",
            model: profile.defaultModel
        )
    }

    private static func flagValue(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Look inside ~/.pi/agent/models.json for the default (non-orca) provider.
    private struct PIProvider {
        var baseURL: String
        var apiKey: String
        var model: String
    }

    private static func piProviderConfig() -> PIProvider? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".pi/agent/models.json")
        guard let data = try? Data(contentsOf: path) else { return nil }
        guard let root = JSONValue.parse(String(data: data, encoding: .utf8) ?? ""),
              let providers = root.objectValue?["providers"]?.objectValue else { return nil }

        // Pick the first provider whose id doesn't start with "orca".
        let name = providers.keys.sorted().first { !$0.hasPrefix("orca") }
        guard let name, let provider = providers[name]?.objectValue,
              let base = provider["baseUrl"]?.stringValue else { return nil }
        let key = provider["apiKey"]?.stringValue ?? "none"
        let model = provider["models"]?.arrayValue?.first?.objectValue?["id"]?.stringValue ?? "default"
        return PIProvider(baseURL: base, apiKey: key, model: model)
    }
}