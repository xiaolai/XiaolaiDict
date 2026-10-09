import Foundation
import LLMProviders
import ModelKit
import Observation

/// **What Settings › Language Model shows and changes** (ADR-0053, plan §6): the source the reader chose, the settings
/// beside it, whether a key is filed for their endpoint, and what the source said when it was last asked.
///
/// A model rather than view state for the reason `SettingsModel` is one: a grouped `Form` cannot be rendered in a test,
/// so every decision the pane draws is made here, where a test can ask it. The words are the pane's.
///
/// - **The key is the Keychain's, filed for the endpoint's origin** (`EndpointAddress.keyAccount`) and for nothing
///   else: never in the defaults, never held here, never logged. The pane asks only *whether* one is filed.
/// - **Nothing here touches the Keychain until it is asked to** — `reload()`, which the pane calls when it appears. A
///   model made with the app, in every test that makes one, reads no credential.
@Observable
@MainActor
public final class LanguageModelPaneModel {
    /// The source the reader chose, as stored.
    public private(set) var choice: ProviderChoice
    /// Everything else they set, as stored and read back — so a value the store refuses is not shown as kept.
    public private(set) var settings: ProviderSettings
    /// The text fields as the reader is typing them, kept by `commitDrafts()`.
    public var drafts: Drafts
    /// Whether a key is filed for the endpoint now set.
    public private(set) var key = KeyState.unknown
    /// What a source last said when asked, and which source it was. Shown only while it is the reader's source now.
    public private(set) var readiness: SourceReadiness?
    /// A check the reader asked for is running.
    public private(set) var isChecking = false
    /// Why the last attempt to save or remove a key failed — a status, never the key. Cleared by the next attempt.
    public private(set) var keyFailure: CredentialStoreFailure?

    @ObservationIgnored private let choices: ProviderChoiceStore
    @ObservationIgnored private let store: ProviderSettingsStore
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let ask: @Sendable () async -> SourceReadiness?

    /// The text fields, as typed.
    public struct Drafts: Equatable, Sendable {
        public var endpointURL: String
        public var endpointModel: String
        public var claudeCLIModel: String
        public var codexCLIModel: String
        public var claudeCLIPath: String
        public var codexCLIPath: String

        init(_ settings: ProviderSettings) {
            endpointURL = settings.endpointURL
            endpointModel = settings.endpointModel
            claudeCLIModel = settings.claudeCLIModel
            codexCLIModel = settings.codexCLIModel
            claudeCLIPath = settings.claudeCLIPath ?? ""
            codexCLIPath = settings.codexCLIPath ?? ""
        }
    }

    /// Whether a key is filed for the endpoint, as the pane says it.
    public enum KeyState: Equatable, Sendable {
        /// Not asked yet.
        case unknown
        /// The address is not one a key could be filed for.
        case noAddress
        /// None is filed for `host`.
        case absent(host: String)
        /// One is filed for `host`.
        case saved(host: String)
        /// The Keychain would not say.
        case unreadable(CredentialStoreFailure)
    }

    /// `defaults` is the suite the app was given; `credentials` the store the providers read keys from; `check` asks the
    /// router the reader's source now, one trivial question.
    public init(defaults: UserDefaults, credentials: any CredentialStore,
                check: @escaping @Sendable () async -> SourceReadiness?) {
        choices = ProviderChoiceStore(defaults: defaults)
        store = ProviderSettingsStore(defaults: defaults)
        self.credentials = credentials
        ask = check
        choice = choices.load()
        let settings = store.load()
        self.settings = settings
        drafts = Drafts(settings)
    }

    // MARK: - What is shown

    /// The source the reader's settings name now — what a question would be sent to.
    public var source: ProviderSource { ProviderSource(choice: choice, settings: settings) }

    /// **The choice that is in force**: a CLI chosen while the switch is off is `none`, as the router reads it.
    public var effectiveChoice: ProviderChoice {
        refusal(of: choice) == nil ? choice : .none
    }

    /// What the source said, while it is still the reader's source.
    public var shownReadiness: ProviderReadiness? {
        guard let readiness, readiness.source == source else { return nil }
        return readiness.readiness
    }

    /// The choices the pane lists, in its order. The bundled model only where its setup is shown — the flag, or a model
    /// already on disk — or it is the reader's choice already, which the list must be able to show as chosen.
    public func offered(showingLocalModel: Bool) -> [ProviderChoice] {
        let always: [ProviderChoice] = [.none, .claudeCLI, .codexCLI, .openAICompatible]
        return showingLocalModel || choice == .localModel ? always + [.localModel] : always
    }

    /// Why `wanted` cannot be chosen now, or nil where it can.
    public func refusal(of wanted: ProviderChoice) -> ChoiceRefusal? {
        switch wanted {
        case .claudeCLI, .codexCLI: settings.subscriptionCLIsEnabled ? nil : .subscriptionCLIsOff
        case .none, .openAICompatible, .localModel: nil
        }
    }

    /// Why a key cannot be saved from `draft` now, or nil where it can — against the address as typed, which is the
    /// one it would be filed for: saving keeps what is typed first.
    public func keyRefusal(_ draft: String) -> KeyRefusal? {
        guard typedAddress != nil else { return .noAddress }
        let key = Self.trimmed(draft)
        guard !key.isEmpty else { return .blank }
        return OpenAICompatibleProvider.canSend(key: key) ? nil : .notAHeaderValue
    }

    /// Why a CLI's location as typed would not be used, or nil where it would. Empty is "find it".
    public func pathRefusal(_ draft: String) -> PathRefusal? {
        let path = Self.trimmed(draft)
        return path.isEmpty || path.hasPrefix("/") ? nil : .notAbsolute
    }

    /// **Why the address as typed is not one the app sends to** (`EndpointAddress.parse`, the one rule), or nil where
    /// it is — or the field is empty, which is the default address. An address refused is never kept.
    public var addressRefusal: EndpointAddress.Refusal? {
        let typed = Self.trimmed(drafts.endpointURL)
        guard !typed.isEmpty, case .failure(let refusal) = EndpointAddress.parse(typed) else { return nil }
        return refusal
    }

    /// Why the source cannot be checked now, or nil where it can.
    public var checkRefusal: CheckRefusal? {
        if isChecking { return .checking }
        return source == .local ? .nothingToCheck : nil
    }

    /// The address as typed, as it would be kept: an empty field keeps the default.
    private var typedAddress: EndpointAddress? {
        let typed = Self.trimmed(drafts.endpointURL)
        return EndpointAddress(typed.isEmpty ? ProviderSettings.defaultEndpointURL : typed)
    }

    // MARK: - What the reader does

    /// Reads everything again — the choice, the settings, whether a key is filed — as the pane appears.
    public func reload() {
        choice = choices.load()
        settings = store.load()
        drafts = Drafts(settings)
        refreshKey()
    }

    /// Chooses `wanted`, unless `refusal(of:)` says why not — in which case nothing is written.
    public func choose(_ wanted: ProviderChoice) {
        guard refusal(of: wanted) == nil else { return }
        choices.save(wanted)
        choice = wanted
    }

    /// Turns the CLIs' switch on or off. **Off, a CLI that was chosen is chosen no longer**, so the list never shows a
    /// source chosen that no question goes to.
    public func setSubscriptionCLIs(_ on: Bool) {
        var next = settings
        next.subscriptionCLIsEnabled = on
        save(next)
        if !on, choice == .claudeCLI || choice == .codexCLI { choose(.none) }
    }

    /// Keeps what is typed in the text fields — in the suite the router reads, and read back from it, so the fields
    /// show what was kept. A location the store will not keep stays in its field, with `pathRefusal` saying why; **so
    /// does an address the app would not send to** (`addressRefusal`) — one carrying a password above all, which must
    /// never reach the defaults.
    public func commitDrafts() {
        var next = settings
        let addressRefused = addressRefusal != nil
        if !addressRefused { next.endpointURL = drafts.endpointURL }
        next.endpointModel = drafts.endpointModel
        next.claudeCLIModel = drafts.claudeCLIModel
        next.codexCLIModel = drafts.codexCLIModel
        next.claudeCLIPath = drafts.claudeCLIPath
        next.codexCLIPath = drafts.codexCLIPath
        save(next)
        if !addressRefused { drafts.endpointURL = settings.endpointURL }
        drafts.endpointModel = settings.endpointModel
        drafts.claudeCLIModel = settings.claudeCLIModel
        drafts.codexCLIModel = settings.codexCLIModel
        if pathRefusal(drafts.claudeCLIPath) == nil { drafts.claudeCLIPath = settings.claudeCLIPath ?? "" }
        if pathRefusal(drafts.codexCLIPath) == nil { drafts.codexCLIPath = settings.codexCLIPath ?? "" }
        refreshKey()
    }

    /// **Files `secret` as the key for the origin of the address in the field** — kept first, so the key goes with the
    /// address the reader sees — under `EndpointAddress.keyAccount`, the account a provider for that address reads and
    /// no other does. Answers whether it was filed. Spaces around a pasted key are not part of it.
    @discardableResult
    public func saveKey(_ secret: String) -> Bool {
        commitDrafts()
        keyFailure = nil
        guard keyRefusal(secret) == nil, let address = EndpointAddress(settings.endpointURL) else { return false }
        do {
            try credentials.write(Self.trimmed(secret), account: address.keyAccount)
        } catch {
            keyFailure = error
            return false
        }
        refreshKey()
        return true
    }

    /// **Removes the key the pane says is saved** — the one filed for the address kept now, which is what the line
    /// beside the button names — and no other origin's.
    public func removeKey() {
        keyFailure = nil
        guard let address = EndpointAddress(settings.endpointURL) else { return }
        do {
            try credentials.delete(account: address.keyAccount)
        } catch {
            keyFailure = error
        }
        refreshKey()
    }

    /// **Asks the source one trivial question**, after keeping what is typed so the source asked is the one shown, and
    /// keeps what it said. Refused while one runs, and where there is nothing to ask.
    public func check() async {
        commitDrafts()
        guard checkRefusal == nil else { return }
        isChecking = true
        defer { isChecking = false }
        record(await ask())
    }

    /// **Keeps what a source said — only while it is the reader's source**: from a check, or from the app warming the
    /// source chosen. An answer about a source the reader has since left is dropped, so a late one cannot replace what
    /// the source now chosen said.
    public func record(_ said: SourceReadiness?) {
        guard let said, said.source == source else { return }
        readiness = said
    }

    // MARK: - Underneath

    /// Writes `next`, where it differs, and reads back what was kept. Unchanged, nothing is written: every write to the
    /// suite is a change the app's router is told of.
    private func save(_ next: ProviderSettings) {
        guard next != settings else { return }
        store.save(next)
        settings = store.load()
    }

    /// Asks the Keychain whether a key is filed for the address kept now — never for the key itself.
    private func refreshKey() {
        guard let address = EndpointAddress(settings.endpointURL) else {
            key = .noAddress
            return
        }
        do {
            key = try credentials.contains(account: address.keyAccount)
                ? .saved(host: address.displayHost) : .absent(host: address.displayHost)
        } catch {
            key = .unreadable(error)
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Why a choice cannot be made now.
public enum ChoiceRefusal: Equatable, Sendable {
    /// A CLI, while the switch both sit behind is off.
    case subscriptionCLIsOff
}

/// Why a key cannot be saved now.
public enum KeyRefusal: Equatable, Sendable {
    /// The address is not one a key could be filed for.
    case noAddress
    /// Nothing is typed.
    case blank
    /// It holds something a request header cannot carry — a space, a line break, a letter outside ASCII — so the
    /// provider would never send it.
    case notAHeaderValue
}

/// Why a CLI's location would not be used.
public enum PathRefusal: Equatable, Sendable {
    /// Not a full path: a relative one would be resolved against wherever the app started.
    case notAbsolute
}

/// Why the source cannot be checked now.
public enum CheckRefusal: Equatable, Sendable {
    /// A check is running.
    case checking
    /// The dictionary and Apple's engines, or the bundled model: nothing a check could ask.
    case nothingToCheck
}

/// **What leaves this Mac for the source the reader chose, derived from `RemoteDisclosure` and never written down
/// beside it** (plan §3) — so the sentence the pane shows changes the day the owner's constant does, and cannot say
/// something the client does not do.
public enum LanguageModelDisclosure: Equatable, Sendable {
    /// No source: the dictionary and Apple's engines, which run on this Mac, or the bundled model.
    case nothingLeaves
    /// A server on this Mac, at `host`: it may be sent the dictionary's text, and nothing leaves the Mac.
    case staysOnThisMac(host: String)
    /// A remote source: the reader's sentence and the word they looked up, and none of the dictionary's text.
    case sentenceOnly(to: Destination)
    /// A remote source, once the dictionary's text may leave: the sentence and the dictionary's text.
    case sentenceAndDictionaryText(to: Destination)

    /// Where a remote source's questions go.
    public enum Destination: Equatable, Sendable {
        case claude
        case codex
        /// An endpoint at `host`, or at an address that names none.
        case endpoint(host: String?)
    }

    /// What leaves for `source`, under the owner's rule about the dictionary's text — an argument, so both of its
    /// arms are tested before anyone flips it.
    public static func of(_ source: ProviderSource,
                          dictionaryTextMayLeave: Bool = RemoteDisclosure.dictionaryTextMayLeave) -> Self {
        let destination: Destination
        switch source {
        case .local: return .nothingLeaves
        case .endpoint(let url, _) where source.tier == .onThisMac:
            return .staysOnThisMac(host: EndpointAddress(url)?.displayHost ?? url)
        case .endpoint(let url, _): destination = .endpoint(host: EndpointAddress(url)?.displayHost)
        case .claudeCLI: destination = .claude
        case .codexCLI: destination = .codex
        }
        return RemoteDisclosure.mayCarryDictionaryText(source.tier, dictionaryTextMayLeave: dictionaryTextMayLeave)
            ? .sentenceAndDictionaryText(to: destination) : .sentenceOnly(to: destination)
    }
}

/// **What the reader must do, read off what a source said** — a kind, worded by the pane.
public enum ProviderAdvice: Equatable, Sendable {
    /// It answered, in `answeredIn`; a CLI also said its version.
    case ready(version: String?, answeredIn: Duration)
    /// The CLI is not installed where installers put it, nor on the reader's login shell's path.
    case install
    /// The location the reader typed is not a program.
    case fixLocation
    /// Nobody is signed in to the CLI: run `command` in Terminal and sign in.
    case signIn(command: String)
    /// The CLI is too old for what this app asks of it.
    case update(version: String?)
    /// The endpoint needs an address the app can use and a model.
    case completeEndpoint
    /// The endpoint refused the key, or wants one.
    case checkKey
    /// The source does not know the model named.
    case checkModel
    /// The endpoint could not be reached at the address.
    case checkAddress
    /// It is limited, busy, slow or refused this time: nothing to change, try later.
    case tryLater
    /// It answered with something that is not an answer.
    case unexpectedAnswer

    /// What `readiness`, said of `source`, asks of the reader.
    public static func of(_ readiness: ProviderReadiness, from source: ProviderSource) -> Self {
        switch readiness {
        case .cli(.ready(let version, let answeredIn)): .ready(version: version, answeredIn: answeredIn)
        case .cli(.notInstalled): .install
        case .cli(.overrideUnusable): .fixLocation
        case .cli(.notSignedIn), .cli(.unavailable(.unauthorised)): .signIn(command: signInCommand(for: source))
        case .cli(.tooOld(let version)): .update(version: version)
        // A CLI reaches its own service: not reaching it is not an address the reader can correct.
        case .cli(.unavailable(.unreachable)): .tryLater
        case .cli(.unavailable(let failure)): of(failure)
        case .endpointUnusable: .completeEndpoint
        case .endpointReady(let answeredIn): .ready(version: nil, answeredIn: answeredIn)
        case .endpointFailed(let failure): of(failure)
        }
    }

    private static func of(_ failure: ProviderFailure) -> Self {
        switch failure {
        case .unauthorised: .checkKey
        case .modelNotFound: .checkModel
        case .unreachable: .checkAddress
        case .rateLimited, .timedOut, .refused, .cancelled: .tryLater
        case .badShape: .unexpectedAnswer
        }
    }

    /// What signs in to the CLI `source` starts, run in Terminal (plan §5) — never run for the reader.
    private static func signInCommand(for source: ProviderSource) -> String {
        if case .codexCLI = source { return "codex login" }
        return "claude"
    }
}
