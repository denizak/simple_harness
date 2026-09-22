import Foundation

// ---------------------------------------------------------------------------
// Config.swift — runtime configuration and its resolution.
//
// A "provider" in a harness is just: base URL + API key + model id, all
// speaking the same OpenAI-compatible dialect. WHICH providers exist and
// what wire quirks each one has lives in Providers.swift — as data on the
// profile. This file only RESOLVES the final configuration:
//
// Resolution order (later wins):
//   1. hardcoded default (local Ollama)
//   2. pi's ~/.pi/agent/models.json (reuse a provider this machine has)
//   3. provider catalog via --provider flag (may borrow a pi-stored key)
//   4. autodetect: first profile in autodetectOrder with an env key
//   5. environment variables (HARNESS_BASE_URL / HARNESS_API_KEY / …)
//   6. command-line flags (--base-url/--api-key/--model/--reasoning)
//
// Adding a provider = one entry in Config.catalog (Providers.swift). No
// switches, no string matching in the client.
// ---------------------------------------------------------------------------

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
    /// Stream model responses (SSE) and print text as it arrives.
    var streaming: Bool = true
    /// Optional reasoning effort for thinking models ("none", "low",
    /// "medium", "high", "max") — sent as "reasoning_effort" when set.
    /// Needed when a provider rejects function tools together with its own
    /// reasoning default (e.g. gpt-5.6-luna via /v1/chat/completions).
    var reasoningEffort: String?
    /// How deep spawn_agent may nest: 0 = top agent, so 2 allows
    /// top → sub → sub-sub. At the cap the tool disappears entirely.
    var maxAgentDepth: Int = 2
    /// TypeSafe API key (https://docs.typesafe.ai) — powers the `judge` tool.
    /// Read from the environment; optional — the tool reports its absence.
    var typesafeApiKey: String?
    /// Wire-format quirk resolved from the provider profile: which
    /// token-limit field the server accepts ("max_tokens" or, for newer
    /// OpenAI models, "max_completion_tokens").
    var tokenLimitKey: String = "max_tokens"
    /// Wire-format quirk resolved from the provider profile: may the client
    /// send stream_options.include_usage while streaming? (Ollama-family
    /// servers accept it; some gateways validate strictly and reject it.)
    var streamOptions: Bool = false

    static func resolve(arguments: [String]) -> Config {
        resolve(arguments: arguments, env: ProcessInfo.processInfo.environment)
    }

    /// Injectable-environment variant so the selftest can verify provider
    /// selection without touching real secrets.
    static func resolve(arguments: [String], env: [String: String]) -> Config {
        var config = Config(
            provider: "ollama",
            baseURL: "http://127.0.0.1:11434/v1",
            apiKey: "none",
            model: "glm-5.3-flash:cloud"
        )

        // 2. Borrow provider config from pi, if present.
        if let pi = piProviderConfig() {
            config = Config(provider: "pi", baseURL: pi.baseURL, apiKey: pi.apiKey, model: pi.model)
            // The borrowed provider may be the local Ollama proxy, which
            // accepts stream_options (it IS the Ollama server).
            config.streamOptions = pi.baseURL.contains("11434")
        }

        // 3. Provider catalog. --provider X wins; otherwise the first profile
        // in autodetectOrder with an API key in the environment wins.
        // Autodetect uses ENV KEYS ONLY: a pi-stored borrowed key must never
        // outrank an explicit env key or silently move the default to a paid
        // cloud API. Borrowing applies when the user names the provider.
        let requested = flagValue("--provider", in: arguments)
        if let name = requested ?? env["HARNESS_PROVIDER"], let profile = Config.catalog[name.lowercased()] {
            config = apply(profile, env)
            config.apiKey = resolvedKey(profile: profile, env: env, allowBorrow: true, current: config.apiKey)
        } else if requested == nil && env["HARNESS_PROVIDER"] == nil {
            for name in Config.autodetectOrder {
                guard let profile = Config.catalog[name], profile.key(in: env) != nil else { continue }
                config = apply(profile, env)
                break
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
        if let value = env["HARNESS_STREAMING"],
           ["0", "false", "no", "off"].contains(value.lowercased()) {
            config.streaming = false
        }
        if let value = env["HARNESS_REASONING"], !value.isEmpty {
            config.reasoningEffort = value
        }
        // Optional integrations (nil when unset).
        config.typesafeApiKey = env["TYPESAFE_API_KEY"]

        // 5. Explicit flags always win: --base-url/--api-key/--model/--reasoning.
        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            func value(_ flag: String, _ current: String?) -> String? {
                guard arg == flag else { return current }
                return iterator.next() ?? current
            }
            config.model = value("--model", config.model) ?? config.model
            config.baseURL = value("--base-url", config.baseURL) ?? config.baseURL
            config.apiKey = value("--api-key", config.apiKey) ?? config.apiKey
            config.reasoningEffort = value("--reasoning", config.reasoningEffort) ?? config.reasoningEffort
        }
        return config
    }

    private static func apply(_ profile: ProviderProfile, _ env: [String: String]) -> Config {
        var config = Config(
            provider: profile.name,
            baseURL: env["\(profile.name.uppercased())_BASE_URL"] ?? profile.baseURL,
            apiKey: profile.key(in: env) ?? "none",
            model: profile.defaultModel
        )
        // Wire quirks travel with the profile — the client never string-matches.
        config.tokenLimitKey = profile.tokenLimitField.rawValue
        config.streamOptions = profile.sendsStreamOptions || config.baseURL.contains("11434")
        return config
    }

    /// Key resolution for one profile: env keys first; then (when borrowing
    /// is allowed) a pi-stored key from auth.json.
    private static func resolvedKey(
        profile: ProviderProfile, env: [String: String], allowBorrow: Bool, current: String
    ) -> String {
        if let envKey = profile.key(in: env) { return envKey }
        guard allowBorrow else { return current }
        return profile.borrowedKey() ?? current
    }

    private static func flagValue(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}