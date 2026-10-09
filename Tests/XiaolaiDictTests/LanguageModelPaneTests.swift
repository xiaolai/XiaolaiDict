import Foundation
import LLMProviders
import ModelKit
import Synchronization
import Testing
import XiaolaiDictTestSupport
@testable import XiaolaiDictUI

/// **Settings › Language Model, asked rather than drawn** (ADR-0053, plan §6): a grouped `Form` renders as nothing under
/// `ImageRenderer`, so each decision the pane shows is asserted on `LanguageModelPaneModel` — which source may be
/// chosen, what is kept where, whether a key is filed and for which origin, what a check said and of which source, and
/// what leaves the Mac. Over a defaults suite of the test's own and a credential store in this process: nothing here
/// asks the Keychain, starts a CLI or reaches a network.
@MainActor
struct LanguageModelPaneTests {
    /// A credential store in this process, counting what the pane asks of it.
    final class Credentials: CredentialStore {
        private let secrets = Mutex<[String: String]>([:])
        private let failure = Mutex<CredentialStoreFailure?>(nil)
        var all: [String: String] { secrets.withLock { $0 } }
        func failEveryCall(with error: CredentialStoreFailure?) { failure.withLock { $0 = error } }

        func read(account: String) throws(CredentialStoreFailure) -> String? {
            if let error = failure.withLock({ $0 }) { throw error }
            return secrets.withLock { $0[account] }
        }

        func contains(account: String) throws(CredentialStoreFailure) -> Bool {
            if let error = failure.withLock({ $0 }) { throw error }
            return secrets.withLock { $0[account] != nil }
        }

        func write(_ secret: String, account: String) throws(CredentialStoreFailure) {
            if let error = failure.withLock({ $0 }) { throw error }
            secrets.withLock { $0[account] = secret }
        }

        func delete(account: String) throws(CredentialStoreFailure) {
            if let error = failure.withLock({ $0 }) { throw error }
            _ = secrets.withLock { $0.removeValue(forKey: account) }
        }
    }

    /// The router's check, as a test answers it: whatever `answer` holds when asked, counted.
    final class Checks: Sendable {
        private let state = Mutex<(answer: SourceReadiness?, asked: Int)>((nil, 0))
        var asked: Int { state.withLock { $0.asked } }
        func answer(_ said: SourceReadiness?) { state.withLock { $0.answer = said } }
        var check: @Sendable () async -> SourceReadiness? {
            { [self] in state.withLock { $0.asked += 1; return $0.answer } }
        }
    }

    static func pane(_ suite: UserDefaults = TemporaryDefaults.suite(), credentials: Credentials = Credentials(),
                     checks: Checks = Checks()) -> LanguageModelPaneModel {
        LanguageModelPaneModel(defaults: suite, credentials: credentials, check: checks.check)
    }

    static let openAI = "https://api.openai.com/v1"
    static let local = "http://127.0.0.1:11434/v1"
    static func account(_ address: String) -> String { EndpointAddress(address).map(\.keyAccount) ?? "none" }

    // MARK: - The source, and the one switch both CLIs sit behind

    /// **A CLI cannot be chosen while the switch is off** — refused with its reason, and nothing written. The control:
    /// with the switch on it is chosen, and kept in the suite the router reads.
    @Test(arguments: [ProviderChoice.claudeCLI, .codexCLI])
    func aCLIIsChosenOnlyWithTheSwitchOn(cli: ProviderChoice) {
        let suite = TemporaryDefaults.suite()
        let pane = Self.pane(suite)
        #expect(!pane.settings.subscriptionCLIsEnabled, "the switch is on before the reader turned it on")
        #expect(pane.refusal(of: cli) == .subscriptionCLIsOff)
        pane.choose(cli)
        #expect(pane.choice == .none)
        #expect(ProviderChoiceStore(defaults: suite).load() == .none, "a refused choice was written")

        pane.setSubscriptionCLIs(true)
        #expect(pane.refusal(of: cli) == nil)
        pane.choose(cli)
        #expect(ProviderChoiceStore(defaults: suite).load() == cli)
        #expect(ProviderSettingsStore(defaults: suite).load().subscriptionCLIsEnabled)
        #expect(pane.effectiveChoice == cli)
    }

    /// **Turning the switch off takes the CLI back**: what the list shows chosen is what the router asks — and the
    /// other sources never needed the switch.
    @Test func turningTheSwitchOffTakesTheCLIBack() {
        let suite = TemporaryDefaults.suite()
        let pane = Self.pane(suite)
        pane.setSubscriptionCLIs(true)
        pane.choose(.codexCLI)
        pane.setSubscriptionCLIs(false)
        #expect(pane.choice == .none)
        #expect(ProviderChoiceStore(defaults: suite).load() == .none)
        for other in [ProviderChoice.none, .openAICompatible, .localModel] {
            #expect(pane.refusal(of: other) == nil, "\(other) was refused for the CLIs' switch")
        }
        pane.choose(.openAICompatible)
        pane.setSubscriptionCLIs(false)
        #expect(pane.choice == .openAICompatible, "turning the CLIs off took away a source that is not one")
    }

    /// **A CLI chosen with the switch off — written into the defaults by anything — is in force as nothing**, as the
    /// router reads it, so the board never says a source is set that no question goes to.
    @Test func aCLIStoredWithTheSwitchOffIsNotInForce() {
        let suite = TemporaryDefaults.suite()
        ProviderChoiceStore(defaults: suite).save(.claudeCLI)
        let pane = Self.pane(suite)
        #expect(pane.choice == .claudeCLI)
        #expect(pane.effectiveChoice == .none)
        #expect(pane.source == .local)
    }

    /// **The bundled model is listed only where its setup is shown** — the flag, or a model on disk — or where it is
    /// the reader's choice already, which the list must be able to show as chosen.
    @Test func theBundledModelIsListedOnlyWhereItsSetupIsShown() {
        let hidden = Self.pane()
        #expect(hidden.offered(showingLocalModel: false) == [.none, .claudeCLI, .codexCLI, .openAICompatible])
        #expect(hidden.offered(showingLocalModel: true) == [.none, .claudeCLI, .codexCLI, .openAICompatible, .localModel])
        let suite = TemporaryDefaults.suite()
        ProviderChoiceStore(defaults: suite).save(.localModel)
        #expect(Self.pane(suite).offered(showingLocalModel: false).last == .localModel)
    }

    // MARK: - What is kept, and where

    /// **What is typed is kept by `commitDrafts`, in the suite the router reads**, and read back — so a value the store
    /// refuses is shown as refused, not as kept. A location that is not a full path is refused with its reason, and the
    /// reader's text stays in the field.
    @Test func whatIsTypedIsKeptWhereTheRouterReadsIt() {
        let suite = TemporaryDefaults.suite()
        let pane = Self.pane(suite)
        pane.drafts.endpointURL = "  \(Self.local)  "
        pane.drafts.endpointModel = "qwen3:4b"
        pane.drafts.claudeCLIModel = "sonnet"
        pane.drafts.claudeCLIPath = "bin/claude"
        pane.commitDrafts()
        let kept = ProviderSettingsStore(defaults: suite).load()
        #expect(kept.endpointURL == Self.local)
        #expect(kept.endpointModel == "qwen3:4b")
        #expect(kept.claudeCLIModel == "sonnet")
        #expect(kept.claudeCLIPath == nil, "a relative path was kept")
        #expect(pane.pathRefusal(pane.drafts.claudeCLIPath) == .notAbsolute)
        #expect(pane.drafts.claudeCLIPath == "bin/claude", "the reader's text was taken out of the field")
        #expect(pane.pathRefusal("/opt/homebrew/bin/claude") == nil && pane.pathRefusal("") == nil)
    }

    /// **Why an address is not used is said, each reason by name** — `EndpointAddress.parse`, the one rule: one that names
    /// no server, one carrying a name or a password, and plain HTTP to a server off this Mac. An address the app sends to
    /// is not refused, and an empty field is the default address.
    @Test func whyAnAddressIsNotUsedIsSaid() {
        let pane = Self.pane()
        let cases: [(String, EndpointAddress.Refusal?)] = [
            ("api.openai.com/v1", .notAnAddress), ("ftp://api.openai.com/v1", .notAnAddress),
            ("https://reader:secret@api.openai.com/v1", .carriesCredentials),
            ("http://e2e@localhost:8080/v1", .carriesCredentials),
            ("http://192.168.1.5:11434/v1", .unencrypted), ("http://another-mac.local:1234/v1", .unencrypted),
            (Self.openAI, nil), (Self.local, nil), ("https://192.168.1.5:11434/v1", nil), ("", nil),
        ]
        for (typed, refusal) in cases {
            pane.drafts.endpointURL = typed
            #expect(pane.addressRefusal == refusal, "\(typed)")
        }
    }

    /// **An address that carries a password never reaches the defaults** — where it would sit in plain text — and the
    /// reader's text stays in the field, said to be refused; no key is filed for it either.
    @Test func anAddressCarryingAPasswordIsNeverKept() {
        let suite = TemporaryDefaults.suite()
        let credentials = Credentials()
        let pane = Self.pane(suite, credentials: credentials)
        let typed = "https://reader:hunter2-PANE@api.example.com/v1"
        pane.drafts.endpointURL = typed
        pane.commitDrafts()
        #expect(ProviderSettingsStore(defaults: suite).load().endpointURL == ProviderSettings.defaultEndpointURL)
        #expect(!String(describing: suite.dictionaryRepresentation()).contains("hunter2"),
                "a password in the address reached the defaults")
        #expect(pane.drafts.endpointURL == typed, "the reader's text was taken out of the field")
        #expect(pane.keyRefusal("sk-x") == .noAddress)
        #expect(!pane.saveKey("sk-x"))
        #expect(credentials.all.isEmpty)
    }

    /// **A key is not filed for a plain-HTTP address off this Mac**, nor the address kept — it would go unencrypted. The
    /// control: the same on this Mac's loopback is kept, and takes a key.
    @Test func aPlainHTTPAddressOffThisMacTakesNoKeyAndIsNotKept() {
        let suite = TemporaryDefaults.suite()
        let credentials = Credentials()
        let pane = Self.pane(suite, credentials: credentials)
        pane.drafts.endpointURL = "http://192.168.1.5:11434/v1"
        #expect(pane.keyRefusal("sk-lan") == .noAddress)
        #expect(!pane.saveKey("sk-lan"))
        #expect(credentials.all.isEmpty, "a key was filed for an address that would send it unencrypted")
        #expect(ProviderSettingsStore(defaults: suite).load().endpointURL == ProviderSettings.defaultEndpointURL)
        pane.drafts.endpointURL = Self.local
        #expect(pane.saveKey("sk-local"))
        #expect(credentials.all == [Self.account(Self.local): "sk-local"])
    }

    // MARK: - The key, filed for the origin

    /// **The key is filed for the origin of the address in the field** — what is typed there is kept first, so the key
    /// goes with the address the reader sees and not the one stored a moment ago — **and nowhere in the defaults**.
    @Test func theKeyIsFiledForTheAddressInTheFieldAndNotInTheDefaults() throws {
        let suite = TemporaryDefaults.suite()
        let credentials = Credentials()
        let pane = Self.pane(suite, credentials: credentials)
        pane.choose(.openAICompatible)
        pane.drafts.endpointURL = Self.local
        #expect(pane.saveKey("  sk-PANE-SECRET-77  "))
        #expect(credentials.all == [Self.account(Self.local): "sk-PANE-SECRET-77"], "\(credentials.all.keys)")
        #expect(ProviderSettingsStore(defaults: suite).load().endpointURL == Self.local)
        #expect(pane.key == .saved(host: "127.0.0.1:11434"))
        let stored = String(describing: suite.dictionaryRepresentation())
        // The control: the scan sees what the pane did keep in the suite.
        #expect(stored.contains("127.0.0.1:11434"), "the scan reads no value the pane kept, so it can see nothing")
        #expect(!stored.contains("PANE-SECRET"), "the key reached the defaults")
    }

    /// **Changing the address to another origin shows no key until the reader saves one** — the key filed for the
    /// first is not this address's, and is still there for the first. Another path of the same origin is the same key.
    @Test func anotherOriginShowsNoKeyUntilOneIsSaved() {
        let credentials = Credentials()
        let pane = Self.pane(credentials: credentials)
        pane.drafts.endpointURL = Self.openAI
        pane.saveKey("sk-openai")
        pane.drafts.endpointURL = "https://api.deepseek.com/v1"
        pane.commitDrafts()
        #expect(pane.key == .absent(host: "api.deepseek.com"))
        pane.drafts.endpointURL = "https://api.openai.com/v2"
        pane.commitDrafts()
        #expect(pane.key == .saved(host: "api.openai.com"), "one origin's other path lost its key")
        #expect(credentials.all.count == 1)
    }

    /// **Removing a key removes this origin's, and no other.**
    @Test func removingAKeyRemovesOnlyThisOrigins() {
        let credentials = Credentials()
        let pane = Self.pane(credentials: credentials)
        pane.drafts.endpointURL = Self.openAI
        pane.saveKey("sk-openai")
        pane.drafts.endpointURL = Self.local
        pane.saveKey("sk-local")
        pane.removeKey()
        #expect(pane.key == .absent(host: "127.0.0.1:11434"))
        #expect(credentials.all == [Self.account(Self.openAI): "sk-openai"])
    }

    /// **A key that cannot be sent cannot be saved**, each refusal named: no address to file it for, nothing typed, and
    /// a key a request header cannot carry — which the provider would refuse to send, failing every question. The
    /// control: a plain key is accepted, and spaces around a pasted one are not part of it.
    @Test func aKeyThatCannotBeSentCannotBeSaved() {
        let pane = Self.pane()
        pane.drafts.endpointURL = "not an address"
        #expect(pane.keyRefusal("sk-plain") == .noAddress)
        #expect(!pane.saveKey("sk-plain"))
        pane.drafts.endpointURL = Self.openAI
        #expect(pane.keyRefusal("") == .blank)
        #expect(pane.keyRefusal("  \n") == .blank)
        for broken in ["sk a", "sk-\u{7F}", "sk-é", "sk-a\nb"] {
            #expect(pane.keyRefusal(broken) == .notAHeaderValue, "\(broken.debugDescription)")
        }
        #expect(pane.keyRefusal("sk-a_b.c-9") == nil)
        #expect(pane.keyRefusal("  sk-pasted\n") == nil)
    }

    /// **The Keychain refusing is said, never as a saved key** — and the next attempt clears it.
    @Test func aKeychainThatRefusesIsSaid() {
        let credentials = Credentials()
        let pane = Self.pane(credentials: credentials)
        pane.drafts.endpointURL = Self.openAI
        credentials.failEveryCall(with: .keychain(status: -25_308))
        #expect(!pane.saveKey("sk-x"))
        #expect(pane.keyFailure == .keychain(status: -25_308))
        credentials.failEveryCall(with: nil)
        #expect(pane.saveKey("sk-x"))
        #expect(pane.keyFailure == nil)
    }

    /// **Nothing asks the Keychain until the pane appears**: the model is made with the app, in every test that makes
    /// one, and a store that throws on every call would show it.
    @Test func nothingAsksTheKeychainUntilThePaneAppears() {
        let credentials = Credentials()
        credentials.failEveryCall(with: .keychain(status: -1))
        let pane = Self.pane(credentials: credentials)
        #expect(pane.key == .unknown)
        pane.reload()
        #expect(pane.key == .unreadable(.keychain(status: -1)))
    }

    // MARK: - What the source said

    /// **What a source said is shown only while it is the reader's source** — a check that comes back about a source
    /// they have since left is not shown, and does not replace what the source now chosen said.
    @Test func whatASourceSaidIsShownOnlyForThatSource() {
        let suite = TemporaryDefaults.suite()
        let pane = Self.pane(suite)
        pane.setSubscriptionCLIs(true)
        pane.choose(.claudeCLI)
        let claude = pane.source
        let ready = ProviderReadiness.cli(.ready(version: "2.1.294", answeredIn: .milliseconds(800)))
        pane.record(SourceReadiness(source: claude, readiness: ready))
        #expect(pane.shownReadiness == ready)

        pane.choose(.codexCLI)
        #expect(pane.shownReadiness == nil, "Claude's answer was shown under Codex")
        let codex = pane.source
        pane.record(SourceReadiness(source: codex, readiness: .cli(.notSignedIn)))
        pane.record(SourceReadiness(source: claude, readiness: ready))
        #expect(pane.shownReadiness == .cli(.notSignedIn), "a late answer about Claude replaced Codex's")
    }

    /// **The reader's check asks the router, keeps what the source said, and is refused while one runs or where there is
    /// nothing to ask** — the dictionary and Apple's engines, or the bundled model.
    @Test func aCheckAsksTheRouterAndKeepsWhatItSaid() async {
        let checks = Checks()
        let pane = Self.pane(checks: checks)
        #expect(pane.checkRefusal == .nothingToCheck)
        await pane.check()
        #expect(checks.asked == 0, "a check asked the router with nothing chosen")

        pane.choose(.openAICompatible)
        pane.drafts.endpointModel = "gpt-test"
        #expect(pane.checkRefusal == nil)
        checks.answer(SourceReadiness(source: .endpoint(url: Self.openAI, model: "gpt-test"),
                                      readiness: .endpointReady(answeredIn: .milliseconds(900))))
        await pane.check()
        #expect(checks.asked == 1)
        #expect(pane.settings.endpointModel == "gpt-test", "the check asked before what was typed was kept")
        #expect(pane.shownReadiness == .endpointReady(answeredIn: .milliseconds(900)))
        #expect(!pane.isChecking)
    }

    // MARK: - What leaves this Mac

    /// **Derived from `RemoteDisclosure`, both arms of the owner's constant**: nothing for no source, everything stays
    /// for a server on this Mac, the sentence only for a remote source — and the dictionary's text too once it may leave.
    /// **The switch says what starting the reader's CLI means, before either can be chosen** (rows 19–20 of the
    /// 2026-10-09 audit): a question is charged to whatever account the program is set up with — a subscription, or an
    /// API key it was given, which is not a subscription at all — each program is asked a short question of this app's
    /// own when it starts, and Codex also sends the reader's own `~/.codex/AGENTS.md`, which this app cannot leave out.
    @Test func theSwitchSaysWhatStartingTheReadersCLIMeans() {
        let footer = LanguageModelPane.subscriptionsFooter
        #expect(!footer.contains("uses your subscription"), "said every question uses a subscription")
        #expect(footer.contains("API key"))
        #expect(footer.contains("~/.codex/AGENTS.md"))
        #expect(footer.contains("short question"))
    }

    /// **And what leaves for Codex says it too**, beside the sentence: its own instructions file, and its warm-up.
    @Test func whatLeavesForCodexNamesTheReadersInstructionsAndTheWarmUp() {
        let also = LanguageModelPane.codexAlsoSends
        #expect(also.contains("~/.codex/AGENTS.md"))
        #expect(also.contains("warm-up"))
    }

    @Test func whatLeavesIsDerivedFromRemoteDisclosure() {
        let claude = ProviderSource.claudeCLI(path: nil, model: "haiku")
        let codex = ProviderSource.codexCLI(path: nil, model: "")
        let hosted = ProviderSource.endpoint(url: "https://api.deepseek.com/v1", model: "m")
        let loopback = ProviderSource.endpoint(url: Self.local, model: "m")
        for flipped in [false, true] {
            #expect(LanguageModelDisclosure.of(.local, dictionaryTextMayLeave: flipped) == .nothingLeaves)
            #expect(LanguageModelDisclosure.of(loopback, dictionaryTextMayLeave: flipped)
                == .staysOnThisMac(host: "127.0.0.1:11434"))
        }
        #expect(LanguageModelDisclosure.of(claude, dictionaryTextMayLeave: false) == .sentenceOnly(to: .claude))
        #expect(LanguageModelDisclosure.of(codex, dictionaryTextMayLeave: false) == .sentenceOnly(to: .codex))
        #expect(LanguageModelDisclosure.of(hosted, dictionaryTextMayLeave: false)
            == .sentenceOnly(to: .endpoint(host: "api.deepseek.com")))
        #expect(LanguageModelDisclosure.of(claude, dictionaryTextMayLeave: true) == .sentenceAndDictionaryText(to: .claude))
        #expect(LanguageModelDisclosure.of(hosted, dictionaryTextMayLeave: true)
            == .sentenceAndDictionaryText(to: .endpoint(host: "api.deepseek.com")))
        // An address that names no server is remote, read failing closed — and says so without a host.
        #expect(LanguageModelDisclosure.of(.endpoint(url: "not an address", model: "m"), dictionaryTextMayLeave: false)
            == .sentenceOnly(to: .endpoint(host: nil)))
        // **The default is the owner's constant**, so the pane says what the client does today.
        #expect(LanguageModelDisclosure.of(claude)
            == LanguageModelDisclosure.of(claude, dictionaryTextMayLeave: RemoteDisclosure.dictionaryTextMayLeave))
        #expect(LanguageModelDisclosure.of(claude) == .sentenceOnly(to: .claude))
    }

    // MARK: - What the reader must do

    /// **What a source said, as what the reader must do** — and which command signs in to which CLI.
    @Test func whatASourceSaidIsWhatTheReaderMustDo() {
        let claude = ProviderSource.claudeCLI(path: nil, model: "haiku")
        let codex = ProviderSource.codexCLI(path: nil, model: "")
        let endpoint = ProviderSource.endpoint(url: Self.openAI, model: "m")
        let cases: [(ProviderReadiness, ProviderSource, ProviderAdvice)] = [
            (.cli(.ready(version: "1.0", answeredIn: .seconds(1))), claude, .ready(version: "1.0", answeredIn: .seconds(1))),
            (.cli(.notInstalled), claude, .install),
            (.cli(.overrideUnusable(path: "/x")), codex, .fixLocation),
            (.cli(.notSignedIn), claude, .signIn(command: "claude")),
            (.cli(.notSignedIn), codex, .signIn(command: "codex login")),
            (.cli(.tooOld(version: "0.1")), codex, .update(version: "0.1")),
            (.cli(.unavailable(.rateLimited)), claude, .tryLater),
            (.cli(.unavailable(.modelNotFound)), claude, .checkModel),
            (.cli(.unavailable(.unauthorised)), codex, .signIn(command: "codex login")),
            (.cli(.unavailable(.badShape("x"))), claude, .unexpectedAnswer),
            (.endpointUnusable, endpoint, .completeEndpoint),
            (.endpointReady(answeredIn: .seconds(2)), endpoint, .ready(version: nil, answeredIn: .seconds(2))),
            (.endpointFailed(.unauthorised), endpoint, .checkKey),
            (.endpointFailed(.modelNotFound), endpoint, .checkModel),
            (.endpointFailed(.unreachable), endpoint, .checkAddress),
            (.endpointFailed(.rateLimited), endpoint, .tryLater),
            (.endpointFailed(.timedOut), endpoint, .tryLater),
            (.endpointFailed(.refused), endpoint, .tryLater),
            (.endpointFailed(.badShape("x")), endpoint, .unexpectedAnswer),
        ]
        for (readiness, source, advice) in cases {
            #expect(ProviderAdvice.of(readiness, from: source) == advice, "\(readiness) from \(source)")
        }
    }
}
