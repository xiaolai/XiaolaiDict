import Foundation

/// Where the language-model panes are answered from — **a source the reader already has** (ADR-0053).
///
/// Here rather than in `LLMProviders` because the app's settings and the setup board read it, and neither links the
/// providers' transport to ask what the reader chose. The raw values are what is stored: renaming a case strands
/// every reader's choice, and `ProviderSettingsTests` pins them.
public enum ProviderChoice: String, Sendable, Equatable, CaseIterable, Codable {
    /// No source: the dictionary and Apple's engines, and no model pane. **The default**, and what anything
    /// unreadable is — a source the reader did not choose is a source their sentence would be sent to.
    case none
    /// The reader's own installed `claude` CLI, signed in by them.
    case claudeCLI
    /// The reader's own installed `codex` CLI, signed in by them.
    case codexCLI
    /// An OpenAI-compatible endpoint, with an API key where it needs one.
    case openAICompatible
    /// The bundled MLX model — hidden, not removed, and offered only where one is already on disk.
    case localModel
}

/// Reads and writes the reader's choice of source. **Unreadable is `none`**, never a crash and never a source.
///
/// It takes its defaults suite and has no default of its own: the app reads only the suite it was given.
public struct ProviderChoiceStore {
    public static let defaultsKey = "LanguageModelProvider"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() -> ProviderChoice {
        guard let raw = defaults.object(forKey: Self.defaultsKey) as? String,
              let choice = ProviderChoice(rawValue: raw)
        else { return .none }
        return choice
    }

    public func save(_ choice: ProviderChoice) {
        defaults.set(choice.rawValue, forKey: Self.defaultsKey)
    }
}

/// What the reader set for each source that is **not a secret** — the API key is the Keychain's, never here.
///
/// One value, so a settings pane reads and writes the whole of it at once, and every field has its default in one
/// place: the initialiser's.
public struct ProviderSettings: Sendable, Equatable {
    /// OpenAI's own endpoint — the one a reader with a key and no other preference means.
    public static let defaultEndpointURL = "https://api.openai.com/v1"
    /// The measured choice (ADR-0053): resident `haiku` answered in 0.9–1.1 s and was 9–11% wrong on the hard cases.
    public static let defaultClaudeCLIModel = "haiku"

    /// The endpoint's base URL, as the reader wrote it; `/chat/completions` is joined to it.
    public var endpointURL: String
    /// The model the endpoint is asked for. Empty is "not named yet": an endpoint has no default model.
    public var endpointModel: String
    /// Where the reader's `claude` is, where they had to say. Nil is "find it". Always an absolute path.
    public var claudeCLIPath: String?
    /// Where the reader's `codex` is, where they had to say. Nil is "find it". Always an absolute path.
    public var codexCLIPath: String?
    /// The model Claude's CLI is started with.
    public var claudeCLIModel: String
    /// The model Codex's server is asked for. **Empty is the server's own default**, which is what the plan asks
    /// for (`model/list`'s default-low entry), never a name written into this build.
    public var codexCLIModel: String

    public init(endpointURL: String = ProviderSettings.defaultEndpointURL, endpointModel: String = "",
                claudeCLIPath: String? = nil, codexCLIPath: String? = nil,
                claudeCLIModel: String = ProviderSettings.defaultClaudeCLIModel, codexCLIModel: String = "") {
        self.endpointURL = endpointURL
        self.endpointModel = endpointModel
        self.claudeCLIPath = claudeCLIPath
        self.codexCLIPath = codexCLIPath
        self.claudeCLIModel = claudeCLIModel
        self.codexCLIModel = codexCLIModel
    }
}

/// Reads and writes `ProviderSettings`, a key per field. **Unreadable is the default, field by field** — a value of
/// the wrong type, a blank string, a path that is not absolute — so one bad value never costs the reader the rest.
///
/// **A value equal to its default is not written, and one taken back is removed**: a later build that changes a
/// default then reaches every reader who never chose one, instead of only the readers who never opened the pane.
public struct ProviderSettingsStore {
    /// The defaults keys, in the app's own domain. The end-to-end stages write them by name.
    public enum Key {
        public static let endpointURL = "ProviderEndpointURL"
        public static let endpointModel = "ProviderEndpointModel"
        public static let claudeCLIPath = "ClaudeCLIPath"
        public static let codexCLIPath = "CodexCLIPath"
        public static let claudeCLIModel = "ClaudeCLIModel"
        public static let codexCLIModel = "CodexCLIModel"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() -> ProviderSettings {
        let standard = ProviderSettings()
        return ProviderSettings(
            endpointURL: text(Key.endpointURL) ?? standard.endpointURL,
            endpointModel: text(Key.endpointModel) ?? standard.endpointModel,
            claudeCLIPath: path(Key.claudeCLIPath),
            codexCLIPath: path(Key.codexCLIPath),
            claudeCLIModel: text(Key.claudeCLIModel) ?? standard.claudeCLIModel,
            codexCLIModel: text(Key.codexCLIModel) ?? standard.codexCLIModel)
    }

    public func save(_ settings: ProviderSettings) {
        let standard = ProviderSettings()
        write(settings.endpointURL, Key.endpointURL, unless: standard.endpointURL)
        write(settings.endpointModel, Key.endpointModel, unless: standard.endpointModel)
        write(settings.claudeCLIPath ?? "", Key.claudeCLIPath, unless: "")
        write(settings.codexCLIPath ?? "", Key.codexCLIPath, unless: "")
        write(settings.claudeCLIModel, Key.claudeCLIModel, unless: standard.claudeCLIModel)
        write(settings.codexCLIModel, Key.codexCLIModel, unless: standard.codexCLIModel)
    }

    /// The stored string, trimmed, or nil where there is none, it is not a string, or it is blank.
    private func text(_ key: String) -> String? {
        guard let stored = defaults.object(forKey: key) as? String else { return nil }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The stored path, where it is absolute. A relative one would be resolved against whatever directory the app
    /// started in, which is not a place the reader chose.
    private func path(_ key: String) -> String? {
        guard let path = text(key), path.hasPrefix("/") else { return nil }
        return path
    }

    private func write(_ value: String, _ key: String, unless standard: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == standard {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
    }
}
