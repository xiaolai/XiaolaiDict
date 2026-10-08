import AppKit
import Capture
import CaptureModel
import DictionaryModel
import Foundation
@testable import LLMProviders
import MacCapture
import ModelKit
import StudyModels
import Synchronization
import Testing
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictTestSupport
@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// **The providers composed as the app composes them** (ADR-0053, plan §8 P3): a lookup answered through a provider
/// the reader chose, the panes marked with where their question went, the source started at launch and kept to the
/// reader's settings, and put away before the app quits. The provider answers in this process and records what it was
/// sent, so each test asserts the wire as well as the answer — and nothing here starts a CLI or reaches a network.
@MainActor
struct ProviderCompositionTests {
    static let sentence = "She banked the fire before going to bed."
    static let sense = "heap (a fire) with tightly packed fuel so that it burns slowly"
    static let explanation = SentenceQuestion(sentence: sentence, term: "banked", senseText: sense)
    static let translation = TranslationQuestion(sentence: sentence, target: "zh-Hans", met: .init(term: "banked", sense: sense))
    static let loopback = "http://127.0.0.1:11434/v1"

    /// A coordinator over a suite in which the reader chose `choice`, its provider `backend`, and no model service.
    static func coordinator(choosing choice: ProviderChoice, endpoint: String = loopback,
                            backend: FakeProvider) -> (LocalModelCoordinator, UserDefaults) {
        let suite = TemporaryDefaults.suite()
        ProviderChoiceStore(defaults: suite).save(choice)
        // The CLIs' switch on, as a reader who chose one has it: with it off a CLI is no source.
        ProviderSettingsStore(defaults: suite).save(ProviderSettings(endpointURL: endpoint, endpointModel: "m",
                                                                     subscriptionCLIsEnabled: true))
        struct NoService: Error {}
        let coordinator = LocalModelCoordinator(
            defaults: suite, store: ModelStore(root: ScratchFile.unmade("providers", file: "models")),
            client: ModelClient(connect: { _ in throw NoService() }, servicePresence: { .gone }),
            providers: ProviderFactory { _ in ProviderBuild(backend: backend) })
        return (coordinator, suite)
    }

    // MARK: - A lookup, end to end

    /// **A lookup is answered through the provider the reader chose**: the dictionary answers, the shipped ladder's top
    /// rung asks the provider, and the sense it names is the one marked on the card. On this Mac — a loopback endpoint
    /// — so the sense question may be asked, and asked by the lookup itself.
    @Test func aLookupIsAnsweredThroughAChosenProvider() async throws {
        let backend = FakeProvider()
        let (models, _) = Self.coordinator(choosing: .openAICompatible, backend: backend)
        let panel = RecordingPanel()
        let runner = LookupRunner(
            client: DictionaryClient(connect: { _ in AnswersWithTwoSenses() }), panel: panel,
            primary: { PrimaryDictionary(chosen: "noad") }, selector: models.senseLadder)
        let selection = Selection(
            text: "fine", sentence: "He paid a heavy fine.", rangeInSentence: NSRange(location: 16, length: 4),
            quality: .accessibility(.accessibilityTextRange, context: .complete), place: ReadingPlace())
        _ = await runner.run(selection, near: .zero, requestedAt: .now, ticket: panel.newRequest())

        guard case .lookup(let shown)? = panel.updates.last else {
            Issue.record("the panel was never filled in")
            return
        }
        #expect(shown.sense == .chosen(key: "s2", by: .model), "the provider's answer is not the sense on the card")
        let asked = backend.requests.filter { $0.instructions == ModelPrompt.senseInstructions }
        #expect(asked.count == 1, "the lookup did not ask the chosen provider")
        #expect(asked.first?.prompt.contains("a sum of money exacted as a penalty") == true)
    }

    // MARK: - Where the question went, said under the answer

    /// **A remote provider's explanation is said to be remote**, and it was given the reader's sentence and no sense.
    @Test func aRemoteProvidersExplanationIsSaidToBeRemote() async throws {
        let backend = FakeProvider()
        let (models, _) = Self.coordinator(choosing: .claudeCLI, backend: backend)
        let answer = await models.explanationActions.explain(Self.explanation)
        #expect(answer == .explained(FakeProvider.explanation, tier: .remote))
        let sent = try #require(backend.requests.first)
        #expect(sent.prompt == Self.explanation.prompt(for: .remote))
        #expect(!sent.prompt.contains("tightly packed"))
    }

    @Test func aRemoteProvidersTranslationIsSaidToBeRemote() async throws {
        let backend = FakeProvider()
        let (models, _) = Self.coordinator(choosing: .codexCLI, backend: backend)
        #expect(await models.translationActions.translate(Self.translation)
            == .translated(FakeProvider.translation, by: .remoteModel))
        let sent = try #require(backend.requests.first)
        #expect(!sent.prompt.contains("tightly packed"), "the sense reached a remote translation")
    }

    /// **The control: a provider on this Mac keeps the labels the panes always had** — and is told the sense.
    @Test func aProviderOnThisMacKeepsTheLocalLabels() async throws {
        let backend = FakeProvider()
        let (models, _) = Self.coordinator(choosing: .openAICompatible, backend: backend)
        #expect(await models.explanationActions.explain(Self.explanation)
            == .explained(FakeProvider.explanation, tier: .onDevice))
        #expect(await models.translationActions.translate(Self.translation)
            == .translated(FakeProvider.translation, by: .localModel))
        #expect(backend.requests.allSatisfy { $0.prompt.contains("tightly packed") })
    }

    /// **Only the remote source's own answer is re-marked.** Where its reply was not an answer the ladder fell through,
    /// and what came back — here a translation of Apple's — keeps its own label; an answer from this Mac keeps its own.
    @Test func onlyTheRemoteSourcesOwnAnswerIsMarkedRemote() {
        let remote = RoutedReply(reply: .explanation("A remote explanation."), tier: .remote)
        #expect(ModelProvenance.explanation(.explained("A remote explanation.", tier: .onDevice), answeredBy: remote)
            == .explained("A remote explanation.", tier: .remote))
        #expect(ModelProvenance.explanation(.explained("Apple's own.", tier: .onDevice), answeredBy: remote)
            == .explained("Apple's own.", tier: .onDevice), "Apple's answer was said to be remote")
        let refused = RoutedReply(reply: .failure(.refused), tier: .remote)
        #expect(ModelProvenance.explanation(.explained("Apple's own.", tier: .onDevice), answeredBy: refused)
            == .explained("Apple's own.", tier: .onDevice))
        let here = RoutedReply(reply: .explanation("Local."), tier: .onThisMac)
        #expect(ModelProvenance.explanation(.explained("Local.", tier: .onDevice), answeredBy: here)
            == .explained("Local.", tier: .onDevice))
        #expect(ModelProvenance.explanation(.unavailable("x"), answeredBy: remote) == .unavailable("x"))

        let translated = RoutedReply(reply: .translation("译文"), tier: .remote)
        #expect(ModelProvenance.translation(.translated("译文", by: .localModel), answeredBy: translated)
            == .translated("译文", by: .remoteModel))
        #expect(ModelProvenance.translation(.translated("苹果的", by: .appleTranslation), answeredBy: translated)
            == .translated("苹果的", by: .appleTranslation))
        #expect(ModelProvenance.translation(.translated("译文", by: .localModel),
                                            answeredBy: RoutedReply(reply: .translation("译文"), tier: .onThisMac))
            == .translated("译文", by: .localModel))
        #expect(ModelProvenance.translation(.unavailable, answeredBy: translated) == .unavailable)
    }

    // MARK: - Started at launch, kept to the settings, put away before the quit

    /// **Launching starts the chosen source and warms it**, without a question from the reader.
    @Test func launchingWarmsTheChosenSource() async throws {
        let backend = FakeProvider(warmsByAsking: true)
        let (models, _) = Self.coordinator(choosing: .claudeCLI, backend: backend)
        models.start()
        try await Wiring.settle("the chosen CLI was not warmed at launch") { backend.checks == 1 }
    }

    /// **A CLI chosen with the reader's switch off is never started** — at launch, by a question, or by the switch's
    /// own write — and its question goes where `none` sends it. The control: turning the switch on starts it.
    @Test func aCLIChosenWithTheSwitchOffIsNeverStarted() async throws {
        let backend = FakeProvider(warmsByAsking: true)
        let (models, suite) = Self.coordinator(choosing: .claudeCLI, backend: backend)
        let store = ProviderSettingsStore(defaults: suite)
        var settings = store.load()
        settings.subscriptionCLIsEnabled = false
        store.save(settings)
        models.start()
        _ = await models.explanationActions.explain(Self.explanation)
        try await Task.sleep(for: .milliseconds(200))
        #expect(backend.requests.isEmpty && backend.checks == 0, "a CLI was asked with the reader's switch off")

        settings.subscriptionCLIsEnabled = true
        store.save(settings)
        try await Wiring.settle("turning the switch on did not start the chosen CLI") { backend.checks == 1 }
    }

    /// **What the chosen source said when it was warmed reaches the Language Model pane** — the preflight's answer, so
    /// the pane shows it without asking a second trivial question of the reader's subscription.
    @Test func whatTheWarmedSourceSaidReachesThePane() async throws {
        let backend = FakeProvider(warmsByAsking: true)
        let (models, _) = Self.coordinator(choosing: .claudeCLI, backend: backend)
        #expect(models.languageModel.shownReadiness == nil)
        models.start()
        try await Wiring.settle("the warming's answer never reached the pane") {
            models.languageModel.shownReadiness == .cli(.ready(version: "9.9.9", answeredIn: .milliseconds(5)))
        }
        #expect(backend.checks == 1, "the pane asked the source a question of its own")
    }

    /// **The pane's check asks the router the app holds** — the source the reader's settings name, one trivial
    /// question — and shows what it said.
    @Test func thePanesCheckAsksTheAppsRouter() async throws {
        let backend = FakeProvider()
        let (models, _) = Self.coordinator(choosing: .openAICompatible, backend: backend)
        await models.languageModel.check()
        #expect(backend.checks == 1)
        #expect(models.languageModel.shownReadiness == .cli(.ready(version: "9.9.9", answeredIn: .milliseconds(5))))
    }

    /// **A write to the app's suite that is not the reader's choice asks the source nothing** — the suite holds window
    /// frames and every other setting, and each write is seen.
    @Test func anUnrelatedSettingAsksTheSourceNothing() async throws {
        let backend = FakeProvider(warmsByAsking: true)
        let (models, suite) = Self.coordinator(choosing: .claudeCLI, backend: backend)
        models.start()
        try await Wiring.settle("the chosen CLI was not warmed at launch") { backend.checks == 1 }
        for index in 0..<3 { suite.set(index, forKey: "SomeOtherSetting") }
        try await Task.sleep(for: .milliseconds(300))
        #expect(backend.checks == 1, "an unrelated setting asked the reader's CLI its question again")
    }

    /// **A change of source is seen when it is made, not at the next question**: the source the reader left is put
    /// away at once.
    @Test func leavingASourcePutsItAwayWithoutWaitingForAQuestion() async throws {
        let backend = FakeProvider()
        let (models, suite) = Self.coordinator(choosing: .claudeCLI, backend: backend)
        models.start()
        _ = await models.explanationActions.explain(Self.explanation)
        ProviderChoiceStore(defaults: suite).save(.none)
        try await Wiring.settle("the source the reader left was not put away") { backend.shutDowns == 1 }
    }

    /// **The app's quit waits for the provider to be put away, and then quits** — never refused, never turned into
    /// anything else.
    @Test func quittingPutsTheProviderAwayAndThenQuits() async throws {
        let backend = FakeProvider()
        let (models, suite) = Self.coordinator(choosing: .claudeCLI, backend: backend)
        _ = await models.explanationActions.explain(Self.explanation)
        let app = XiaolaiDictApp(defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()), models: models)
        let replied = Recorder<[Int]>([])
        #expect(app.endProvidersThenQuit { replied.withLock { $0.append(backend.shutDowns) } } == .terminateLater)
        try await Wiring.settle("the quit was never let go on") { !replied.withLock { $0 }.isEmpty }
        #expect(replied.withLock { $0 } == [1], "the app quit before its provider was put away")
    }

    /// **A quit asked for from inside the main queue's drain still quits** — which is where SIGTERM asks for it. The
    /// signal source's handler runs on the main queue and calls `NSApp.terminate` there; told `.terminateLater`, AppKit
    /// spins the run loop *inside that callout* until it is replied to, and nothing else queued on the main queue runs
    /// until the callout returns. A reply that needed the main actor therefore never came: measured on the E2E Mac
    /// (2026-10-09), the app answered `NSTerminateLater` to the provider stage's SIGTERM and was still running minutes
    /// later, its main thread in `-[NSApplication _shouldTerminate]` under the signal handler. Reproduced here: this
    /// body resumes as a main-actor job — inside the drain — and spins the run loop the way AppKit does.
    @Test func aQuitAskedForFromInsideTheMainQueueStillQuits() async throws {
        let backend = FakeProvider()
        let (models, suite) = Self.coordinator(choosing: .claudeCLI, backend: backend)
        _ = await models.explanationActions.explain(Self.explanation)
        let app = XiaolaiDictApp(defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()), models: models)
        let replied = Recorder<Bool>(false)
        #expect(app.endProvidersThenQuit { replied.withLock { $0 = true } } == .terminateLater)
        // `-[NSApplication _shouldTerminate]`'s wait, synchronously, bounded only so a hang is a failure and not a run
        // that never ends: past the providers' own bound, which a quit is allowed to spend.
        Self.spinTheRunLoop(until: { replied.withLock { $0 } },
                            for: Double(XiaolaiDictApp.providerShutdown.components.seconds) + 5)
        #expect(replied.withLock { $0 }, "a quit asked for from inside the main queue was never let go on")
        #expect(backend.shutDowns == 1, "the app quit without putting its provider away")
    }

    /// The lines no test can call: launching starts the providers, outside an instrument run, and AppKit's quit goes
    /// through the wait above.
    @Test func theRunningAppStartsTheProvidersAndEndsThemBeforeItQuits() throws {
        let app = try Self.source("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        let didFinish = try #require(app.range(of: "func applicationDidFinishLaunching("))
        #expect(app[didFinish.lowerBound...].prefix(4_000).contains("if !Self.isInstrumented { models.start() }"),
                "nothing starts the chosen source at launch")
        let terminate = try #require(app.range(of: "func applicationShouldTerminate("))
        #expect(app[terminate.lowerBound...].prefix(300).contains("endProvidersThenQuit"),
                "AppKit's quit does not wait for the providers")
    }

    /// The run loop, turned on this thread until `done` or `seconds` have passed — synchronously, as AppKit turns it
    /// while it waits for a reply to `.terminateLater`. Not `async`: suspending would leave the main queue's drain, and
    /// staying inside it is the point.
    static func spinTheRunLoop(until done: () -> Bool, for seconds: Double) {
        let bound = Date.now.addingTimeInterval(seconds)
        while !done(), Date.now < bound {
            RunLoop.main.run(mode: .default, before: Date.now.addingTimeInterval(0.05))
        }
    }

    static func source(_ path: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repository.appending(path: path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

/// **A provider in this process**, answering each kind of question as a model would, and keeping what it was sent.
final class FakeProvider: ProviderBackend {
    static let explanation = "She covered the fire so that it would burn slowly through the night."
    static let translation = "她睡前把炉火封好了。"

    private let state = Mutex<(requests: [GenerationRequest], shutDowns: Int, checks: Int)>(([], 0, 0))
    let warmsByAsking: Bool

    init(warmsByAsking: Bool = false) { self.warmsByAsking = warmsByAsking }

    var requests: [GenerationRequest] { state.withLock { $0.requests } }
    var shutDowns: Int { state.withLock { $0.shutDowns } }
    var checks: Int { state.withLock { $0.checks } }

    func generate(_ request: GenerationRequest) async throws(ProviderFailure) -> String {
        state.withLock { $0.requests.append(request) }
        if request.instructions == ModelPrompt.senseInstructions { return "2" }
        if request.instructions.hasPrefix("Translate") { return Self.translation }
        return Self.explanation
    }

    func readiness() async -> ProviderReadiness {
        state.withLock { $0.checks += 1 }
        return .cli(.ready(version: "9.9.9", answeredIn: .milliseconds(5)))
    }

    func shutDown() async { state.withLock { $0.shutDowns += 1 } }
}

/// The dictionary service answering *fine* with one entry of two noun senses, keyed by the publisher.
private struct AnswersWithTwoSenses: DictionaryTransport {
    func send(_ request: ServiceRequest) async throws -> ServiceReply {
        let senses = [("s1", "a period of fine weather"), ("s2", "a sum of money exacted as a penalty by a court")]
            .enumerated().map { index, sense in
                DictionarySense(path: SensePath(block: 1, ordinal: index + 1), key: sense.0, keyKind: .publisher,
                                definition: sense.1, text: sense.1)
            }
        let entry = DictionaryEntry(
            dictionary: DictionaryIdentity(name: "NOAD", identifier: "noad"), headword: "fine", lookedUp: "fine",
            html: "<p/>", document: EntryDocument(isStyled: true, entryID: "e", homograph: nil,
                                                  blocks: [SenseBlock(number: 1, partOfSpeech: "noun", senses: senses)]))
        return .lookup(LookupAnswer(word: .entries(NonEmpty([entry])!, unreadable: [])))
    }

    func cancel(reason: String) {}
}
