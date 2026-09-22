import Foundation

// ---------------------------------------------------------------------------
// Providers.swift — the provider catalog as DATA.
//
// Earlier versions hardcoded per-provider behavior in three places: a key-
// borrowing switch in Config.resolve, and baseURL string-matching inside the
// client (max_completion_tokens, stream_options). That scales badly — every
// new provider touched three files. Now each profile DECLARES its own:
//
//   * key sources       — env keys + (optionally) which entry to borrow from
//                         pi's ~/.pi/agent/auth.json
//   * borrow behavior   — opt-in only, except profiles that explicitly opt
//                         into autodetect borrowing (deepseek, shipped)
//   * wire quirks       — which token-limit field the server accepts, and
//                         whether stream_options may be sent
//
// Adding a provider is ONE catalog entry. No switches, no string matching.
// ---------------------------------------------------------------------------

/// How a provider obtains its API key — the *policy* lives on the profile
/// as data, so the resolver has one switch instead of interpreting flags:
///   envOnly                      env keys, nothing else (local servers that
///                                ignore keys land here too)
///   envThenBorrow(entry)         env keys first; otherwise borrow pi's
///                                auth.json entry — applied only when the
///                                user explicitly names the provider
///   envThenBorrowForAutodetect   same, and a borrowed key also satisfies
///                                AUTODETECT (only deepseek: its zero-setup
///                                default is shipped behavior)
enum KeyResolution: Sendable {
    case envOnly
    case envThenBorrow(piAuthEntry: String)
    case envThenBorrowForAutodetect(piAuthEntry: String)

    /// The pi auth.json entry to borrow, if this policy borrows at all.
    var borrowEntry: String? {
        switch self {
        case .envOnly: return nil
        case .envThenBorrow(let entry): return entry
        case .envThenBorrowForAutodetect(let entry): return entry
        }
    }

    /// Whether a borrowed key may satisfy AUTODETECT (not just --provider).
    var borrowsForAutodetect: Bool {
        if case .envThenBorrowForAutodetect = self { return true }
        return false
    }
}

/// Which token-limit field the server accepts (a per-provider quirk):
/// newer OpenAI models reject `max_tokens` and want `max_completion_tokens`.
enum TokenLimitField: String, Sendable {
    case maxTokens = "max_tokens"
    case maxCompletionTokens = "max_completion_tokens"
}

struct ProviderProfile: Sendable {
    var name: String
    var baseURL: String
    /// Environment variables that may hold this provider's API key.
    var envKeys: [String]
    var defaultModel: String
    /// Key-acquisition policy — see KeyResolution.
    var keyResolution: KeyResolution
    /// Token-limit field quirk (see TokenLimitField).
    var tokenLimitField: TokenLimitField
    /// May the client send stream_options.include_usage while streaming?
    var sendsStreamOptions: Bool

    /// Explicit init with defaults so catalog entries only declare their
    /// differences (the synthesized memberwise init would demand every
    /// parameter — Swift doesn't apply property defaults to it).
    init(
        name: String,
        baseURL: String,
        envKeys: [String],
        defaultModel: String,
        keyResolution: KeyResolution = .envOnly,
        tokenLimitField: TokenLimitField = .maxTokens,
        sendsStreamOptions: Bool = false
    ) {
        self.name = name
        self.baseURL = baseURL
        self.envKeys = envKeys
        self.defaultModel = defaultModel
        self.keyResolution = keyResolution
        self.tokenLimitField = tokenLimitField
        self.sendsStreamOptions = sendsStreamOptions
    }

    /// First env key present in the given environment.
    func key(in env: [String: String]) -> String? {
        envKeys.compactMap { env[$0] }.first
    }

    /// Key borrowed from pi's stored auth, when this profile's policy
    /// borrows at all.
    func borrowedKey() -> String? {
        guard let entry = keyResolution.borrowEntry else { return nil }
        return piAuthApiKey(entry)
    }
}

extension Config {
    /// The well-known provider catalog. All of these speak the OpenAI
    /// Chat Completions dialect, so one client covers them all.
    static let catalog: [String: ProviderProfile] = [
        "openai": ProviderProfile(
            name: "openai",
            baseURL: "https://api.openai.com/v1",
            envKeys: ["OPENAI_API_KEY"],
            defaultModel: "gpt-4o-mini",
            tokenLimitField: .maxCompletionTokens
        ),
        "zai": ProviderProfile(
            name: "zai",
            baseURL: "https://api.z.ai/api/paas/v4",
            envKeys: ["ZAI_API_KEY", "Z_AI_API_KEY", "ZHIPU_API_KEY"],
            defaultModel: "glm-4.6",
            keyResolution: .envThenBorrow(piAuthEntry: "zai")
        ),
        // GLM Coding Plan (https://docs.z.ai/devpack/quick-start): the plan
        // has its OWN endpoints, separate from the standard platform API.
        // Opt-in only (--provider) — a coding plan's quota must not be
        // silently routed to by autodetect. Keys may borrow from pi's
        // auth.json (zai for international, zai-coding-cn for the CN plan).
        "zai-coding": ProviderProfile(
            name: "zai-coding",
            baseURL: "https://api.z.ai/api/coding/paas/v4",
            envKeys: ["ZAI_CODING_API_KEY"],
            defaultModel: "glm-4.6",
            keyResolution: .envThenBorrow(piAuthEntry: "zai")
        ),
        // China-region coding plan (matches pi's zai-coding-cn provider).
        "zai-coding-cn": ProviderProfile(
            name: "zai-coding-cn",
            baseURL: "https://open.bigmodel.cn/api/coding/paas/v4",
            envKeys: ["ZAI_CODING_CN_API_KEY"],
            defaultModel: "glm-5.3",
            keyResolution: .envThenBorrow(piAuthEntry: "zai-coding-cn")
        ),
        // DeepSeek: OpenAI-compatible at the root (the client appends
        // /chat/completions). Models per docs: deepseek-flash, deepseek-v4-pro.
        "deepseek": ProviderProfile(
            name: "deepseek",
            baseURL: "https://api.deepseek.com",
            envKeys: ["DEEPSEEK_API_KEY"],
            defaultModel: "deepseek-flash",
            keyResolution: .envThenBorrowForAutodetect(piAuthEntry: "deepseek")
        ),
        // Ollama Cloud: same OpenAI-compatible API as the local server, but
        // models run in Ollama's datacenter. Model ids are the raw tags from
        // https://ollama.com/api/tags — the ":cloud" suffix is only for a
        // signed-in LOCAL server proxying to the cloud.
        // Docs: https://docs.ollama.com/cloud
        "ollama-cloud": ProviderProfile(
            name: "ollama-cloud",
            baseURL: "https://ollama.com/v1",
            envKeys: ["OLLAMA_API_KEY"],
            defaultModel: "kimi-k2.7-code",
            sendsStreamOptions: true
        ),
        // Local Ollama server. Its key is optional ("required but ignored"
        // per the OpenAI-compat docs), so no borrowing is needed.
        "ollama": ProviderProfile(
            name: "ollama",
            baseURL: "http://127.0.0.1:11434/v1",
            envKeys: ["HARNESS_API_KEY"],
            defaultModel: "glm-5.3-flash:cloud",
            sendsStreamOptions: true
        ),
    ]

    /// Provider ids checked, in order, when no --provider flag is given:
    /// the first one with an API key in the environment wins. Coding-plan
    /// profiles are deliberately absent — their quota is opt-in only.
    static let autodetectOrder = ["ollama-cloud", "zai", "deepseek", "openai"]
}

// ---------------------------------------------------------------------------
// pi fallbacks — reusing credentials/config this machine already has.
// ---------------------------------------------------------------------------

/// API key stored by pi in ~/.pi/agent/auth.json for a provider, if present.
/// Only "api_key"-typed entries are used (OAuth tokens are not plain keys).
func piAuthApiKey(_ provider: String) -> String? {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/auth.json")
    guard let data = try? Data(contentsOf: path),
          let root = JSONValue.parse(String(data: data, encoding: .utf8) ?? ""),
          let entry = root.objectValue?[provider]?.objectValue else { return nil }
    let type = entry["type"]?.stringValue ?? ""
    let key = entry["key"]?.stringValue ?? ""
    return type.lowercased() == "api_key" && !key.isEmpty ? key : nil
}

/// Provider borrowed from pi's ~/.pi/agent/models.json, if present. Lets the
/// harness reuse whatever provider this machine already configured for pi.
struct PIProvider {
    var name: String
    var baseURL: String
    var apiKey: String
    var model: String
}

func piProviderConfig() -> PIProvider? {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".pi/agent/models.json")
    guard let data = try? Data(contentsOf: path),
          let root = JSONValue.parse(String(data: data, encoding: .utf8) ?? ""),
          let providers = root.objectValue?["providers"]?.objectValue else { return nil }

    // Pick the first provider whose id doesn't start with "orca".
    let name = providersKey(providers) ?? "ollama"
    guard let provider = providers[name]?.objectValue,
          let base = provider["baseUrl"]?.stringValue else { return nil }
    let key = provider["apiKey"]?.stringValue ?? "none"
    let model = provider["models"]?.arrayValue?.first?.objectValue?["id"]?.stringValue ?? "default"
    return PIProvider(name: name, baseURL: base, apiKey: key, model: model)
}

private func providersKey(_ providers: [String: JSONValue]) -> String? {
    providers.keys.sorted().first { !$0.hasPrefix("orca") }
}