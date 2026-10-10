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
//   4. autodetect: env keys first; DeepSeek may use its opted-in borrowed key
//   5. environment variables (HARNESS_BASE_URL / HARNESS_API_KEY / …)
//   6. command-line flags (--base-url/--api-key/--model/--reasoning)
//
// Adding a provider = one entry in Config.catalog (Providers.swift). No
// switches, no string matching in the client.
// ---------------------------------------------------------------------------

public struct Config: Sendable {
    public var provider: String
    public var baseURL: String
    public var apiKey: String
    public var model: String
    /// JSONL session log path; nil = OFF (single-file /save stays the default).
    /// The agent appends one line per message as the run progresses, so a
    /// crash can lose at most the in-flight turn, never the whole transcript.
    public var sessionLog: String?
    public var maxTokens: Int = 4096
    /// Hard cap on model turns per user task (loop safety belt).
    public var maxTurns: Int = 25
    /// Truncation limit for tool output fed back to the model (chars).
    public var maxToolOutput: Int = 20_000
    /// Compact the history when its byte estimate exceeds this (0 = never).
    /// ~4 bytes ≈ 1 token, so 100_000 ≈ 25k tokens of headroom spent.
    public var compactAboveBytes: Int = 100_000
    /// How many recent messages to always keep verbatim when compacting.
    public var compactKeepTail: Int = 8
    /// Stream model responses (SSE) and print text as it arrives.
    public var streaming: Bool = true
    /// Optional reasoning effort for thinking models ("none", "low",
    /// "medium", "high", "max") — sent as "reasoning_effort" when set.
    /// Needed when a provider rejects function tools together with its own
    /// reasoning default (e.g. gpt-5.6-luna via /v1/chat/completions).
    public var reasoningEffort: String?
    /// How deep spawn_agent may nest: 0 = top agent, so 2 allows
    /// top → sub → sub-sub. At the cap the tool disappears entirely.
    public var maxAgentDepth: Int = 2
    /// TypeSafe API key (https://docs.typesafe.ai) — powers the `naluri` tool via the TypeSafe (Jev) backend.
    /// Read from the environment; optional — the tool reports its absence.
    public var typesafeApiKey: String?
    /// Which naluri backend answers: "typesafe" or a catalog provider id
    /// (deepseek, zai, …) for ChatNaluri. nil = typesafe when its key is set.
    public var naluriBackendName: String?
    /// Chat-model override for ChatNaluri (default: the provider's flash tier).
    public var naluriModel: String?
    /// Pre-model gate (Gate.swift): judge each user task with naluri before
    /// the first model call; reject below `gateThreshold`. Fail-open.
    public var gateEnabled: Bool = false
    /// Minimum "proceed" probability for the gate to let a task through.
    public var gateThreshold: Double = 0.5
    /// Tool-approval gate (Approval.swift): which tool calls need a human
    /// yes before running (never | dangerous | all). Fail-closed: with a
    /// demanding policy and no installed hook, calls are denied.
    public var approvalPolicy: ApprovalPolicy = .never
    /// Wire-format quirk resolved from the provider profile: which
    /// token-limit field the server accepts ("max_tokens" or, for newer
    /// OpenAI models, "max_completion_tokens").
    public var tokenLimitKey: String = "max_tokens"
    /// Wire-format quirk resolved from the provider profile: may the client
    /// send stream_options.include_usage while streaming? (Ollama-family
    /// servers accept it; some gateways validate strictly and reject it.)
    public var streamOptions: Bool = false


    /// Explicit init mirroring the memberwise one with defaults — cross-module
    /// construction (the thin executable, tests) needs public access.
    public init(
        provider: String,
        baseURL: String,
        apiKey: String,
        model: String,
        sessionLog: String? = nil,
        maxTokens: Int = 4096,
        maxTurns: Int = 25,
        maxToolOutput: Int = 20_000,
        compactAboveBytes: Int = 100_000,
        compactKeepTail: Int = 8,
        streaming: Bool = true,
        reasoningEffort: String? = nil,
        maxAgentDepth: Int = 2,
        typesafeApiKey: String? = nil,
        gateEnabled: Bool = false,
        gateThreshold: Double = 0.5,
        approvalPolicy: ApprovalPolicy = .never,
        tokenLimitKey: String = "max_tokens",
        streamOptions: Bool = false
    ) {
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.sessionLog = sessionLog
        self.maxTokens = maxTokens
        self.maxTurns = maxTurns
        self.maxToolOutput = maxToolOutput
        self.compactAboveBytes = compactAboveBytes
        self.compactKeepTail = compactKeepTail
        self.streaming = streaming
        self.reasoningEffort = reasoningEffort
        self.maxAgentDepth = maxAgentDepth
        self.typesafeApiKey = typesafeApiKey
        self.gateEnabled = gateEnabled
        self.gateThreshold = gateThreshold
        self.approvalPolicy = approvalPolicy
        self.tokenLimitKey = tokenLimitKey
        self.streamOptions = streamOptions
    }

    public static func resolve(arguments: [String]) -> Config {
        resolve(arguments: arguments, env: ProcessInfo.processInfo.environment)
    }

    /// Injectable-environment variant so the selftest can verify provider
    /// selection without touching real secrets.
    public static func resolve(arguments: [String], env: [String: String]) -> Config {
        resolve(arguments: arguments, env: env, pi: .loadFromHome(), file: nil)
    }

    /// Pure resolution entry point. No filesystem access occurs when the
    /// snapshot is supplied, which makes precedence deterministic in tests.
    /// `file: nil` means "read the JSON config file from disk"; passing `[:]`
    /// (the default here) suppresses file loading entirely for tests.
    public static func resolve(
        arguments: [String], env: [String: String], pi: PIConfigSnapshot,
        file: [String: JSONValue]? = [:]
    ) -> Config {
        var config = Config(
            provider: "ollama",
            baseURL: "http://127.0.0.1:11434/v1",
            apiKey: "none",
            model: "glm-5.3-flash:cloud"
        )

        // 2. Borrow provider config from pi, if present.
        if let borrowedProvider = pi.provider {
            config = Config(provider: "pi", baseURL: borrowedProvider.baseURL,
                            apiKey: borrowedProvider.apiKey, model: borrowedProvider.model)
            // The borrowed provider may be the local Ollama proxy, which
            // accepts stream_options (it IS the Ollama server).
            config.streamOptions = borrowedProvider.baseURL.contains("11434")
        }

        // 2.5 JSON config file. Path: --config flag > HARNESS_CONFIG env >
        // .simple.h.conf in the working directory (missing default file is
        // normal, silent). A file "provider" participates in catalog
        // selection below, but env and --provider outrank it.
        let fileEntries = file ?? configFileEntries(
            explicitPath: flagValue("--config", in: arguments), env: env)

        // 3. Provider catalog. --provider X wins; otherwise the first profile
        // in autodetectOrder with an API key in the environment wins.
        // Autodetect checks env keys first, so a borrowed key never outranks
        // an explicit env key. DeepSeek alone opts into a borrowed-key fallback;
        // other profiles borrow only when explicitly selected.
        let requested = flagValue("--provider", in: arguments)
            ?? env["HARNESS_PROVIDER"]
            ?? fileEntries["provider"]?.stringValue
        if let name = requested ?? env["HARNESS_PROVIDER"], let profile = Config.catalog[name.lowercased()] {
            config = apply(profile, env)
            config.apiKey = resolvedKey(profile: profile, env: env, current: config.apiKey, pi: pi)
        } else if requested == nil && env["HARNESS_PROVIDER"] == nil {
            // Two passes, so priority is by KEY KIND, not catalog position:
            //   pass 1 — explicit env keys ALWAYS beat borrowed keys
            //   pass 2 — profiles whose policy opted into autodetect
            //            borrowing (deepseek), only if pass 1 found nothing
            // (A single pass with hasEnvKey || canBorrow let deepseek's
            // borrowed key outrank an explicit OPENAI_API_KEY — caught by
            // the quirk selftest.)
            var matched = false
            for name in Config.autodetectOrder {
                guard let profile = Config.catalog[name], profile.key(in: env) != nil else { continue }
                config = apply(profile, env)
                config.apiKey = resolvedKey(profile: profile, env: env, current: config.apiKey, pi: pi)
                matched = true
                break
            }
            if !matched {
                for name in Config.autodetectOrder {
                    guard let profile = Config.catalog[name],
                          profile.keyResolution.borrowsForAutodetect,
                          pi.borrowedKey(for: profile) != nil else { continue }
                    config = apply(profile, env)
                    config.apiKey = resolvedKey(profile: profile, env: env, current: config.apiKey, pi: pi)
                    break
                }
            }
        }

        // 3.5 Remaining JSON config file values. Known keys only, each
        // optional; env overrides (step 4) and flags (step 5) still win.
        if !fileEntries.isEmpty {
            applyFileEntries(fileEntries, to: &config)
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
        // Optional integrations (nil when unset — but only when env is unset,
        // so a config-file value survives; later sources must not clobber it).
        if let value = env["TYPESAFE_API_KEY"] { config.typesafeApiKey = value }
        if let value = env["HARNESS_NALURI"], !value.isEmpty { config.naluriBackendName = value.lowercased() }
        if let value = env["HARNESS_NALURI_MODEL"], !value.isEmpty { config.naluriModel = value }
        if let value = env["HARNESS_GATE"],
           ["1", "true", "yes", "on"].contains(value.lowercased()) {
            config.gateEnabled = true
        }
        if let value = env["HARNESS_GATE_THRESHOLD"], let parsed = Double(value),
           parsed > 0, parsed < 1 {
            config.gateThreshold = parsed
        }
        // Tool-approval policy: dangerous/all install the gate; anything else
        // (including an unrecognized word, which warns) stays `never`.
        if let value = env["HARNESS_APPROVAL"] {
            if let policy = ApprovalPolicy.parse(value) {
                config.approvalPolicy = policy
            } else {
                print(AgentUI.warn(
                    "HARNESS_APPROVAL='\(value)' is not one of never|dangerous|all — using never"))
            }
        }

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
            config.typesafeApiKey = value("--typesafe-key", config.typesafeApiKey) ?? config.typesafeApiKey
            config.naluriBackendName = value("--naluri", config.naluriBackendName)?.lowercased() ?? config.naluriBackendName
            config.naluriModel = value("--naluri-model", config.naluriModel) ?? config.naluriModel
            if let raw = value("--max-turns", nil), let parsed = Int(raw), parsed > 0 {
                config.maxTurns = parsed
            }
            if let raw = value("--session-log", nil), !raw.isEmpty {
                config.sessionLog = raw
            }
            if arguments.contains("--no-session-log") { config.sessionLog = nil }
            if let raw = value("--gate-threshold", nil), let parsed = Double(raw),
               parsed > 0, parsed < 1 {
                config.gateThreshold = parsed
            }
            if let raw = value("--approval", nil), let parsed = ApprovalPolicy.parse(raw) {
                config.approvalPolicy = parsed
            }
            // Presence flags for the settings a one-off run most often flips.
            if arguments.contains("--gate") { config.gateEnabled = true }
            if arguments.contains("--no-gate") { config.gateEnabled = false }
            if arguments.contains("--no-streaming") { config.streaming = false }
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

    /// Key resolution for one profile: env keys first; then the profile's
    /// own policy decides whether a pi-stored key may be borrowed.
    private static func resolvedKey(
        profile: ProviderProfile, env: [String: String], current: String,
        pi: PIConfigSnapshot
    ) -> String {
        if let envKey = profile.key(in: env) { return envKey }
        return pi.borrowedKey(for: profile) ?? current
    }

    private static func flagValue(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Locate and parse the JSON config file, if any. A missing DEFAULT file
    /// is normal and silent; an explicit path (--config / HARNESS_CONFIG) that
    /// can't be read or parsed warns and continues — the file is a
    /// convenience, not a dependency.
    private static func configFileEntries(
        explicitPath: String?, env: [String: String]
    ) -> [String: JSONValue] {
        let path: String
        let explicit: Bool
        if let explicitPath {
            path = explicitPath; explicit = true
        } else if let fromEnv = env["HARNESS_CONFIG"] {
            path = fromEnv; explicit = true
        } else {
            path = FileManager.default.currentDirectoryPath + "/.simple.h.conf"
            explicit = false
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            if explicit { print(AgentUI.warn("config file not found at \(path) — ignoring")) }
            return [:]
        }
        guard let parsed = JSONValue.parse(String(data: data, encoding: .utf8) ?? ""),
              let entries = parsed.objectValue else {
            print(AgentUI.warn("config file at \(path) is not a JSON object — ignoring"))
            return [:]
        }
        return entries
    }

    /// Overlay a parsed config file onto the config. Only keys actually
    /// present change anything; unknown keys are ignored. "provider" is
    /// consumed earlier (catalog selection) and intentionally not re-read.
    private static func applyFileEntries(_ entries: [String: JSONValue], to config: inout Config) {
        func string(_ key: String) -> String? { entries[key]?.stringValue }
        if let value = string("baseURL") { config.baseURL = value }
        if let value = string("apiKey") { config.apiKey = value }
        if let value = string("model") { config.model = value }
        if let value = entries["maxTurns"]?.intValue { config.maxTurns = value }
        if let value = entries["maxToolOutput"]?.intValue { config.maxToolOutput = value }
        if let value = entries["compactAboveBytes"]?.intValue { config.compactAboveBytes = value }
        if let value = entries["compactKeepTail"]?.intValue { config.compactKeepTail = max(2, value) }
        if let value = entries["maxAgentDepth"]?.intValue { config.maxAgentDepth = value }
        if let value = entries["streaming"]?.boolValue { config.streaming = value }
        if let value = string("reasoningEffort") { config.reasoningEffort = value }
        if let value = string("typesafeApiKey") { config.typesafeApiKey = value }
        if let value = string("naluri") { config.naluriBackendName = value.lowercased() }
        if let value = string("naluriModel") { config.naluriModel = value }
        if let value = entries["gate"]?.boolValue { config.gateEnabled = value }
        if let value = entries["gateThreshold"]?.doubleValue, value > 0, value < 1 {
            config.gateThreshold = value
        }
        if let value = string("approvalPolicy"), let policy = ApprovalPolicy.parse(value) {
            config.approvalPolicy = policy
        }
    }
}