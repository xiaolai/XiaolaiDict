import Foundation
@testable import LLMProviders
import ModelKit
import Synchronization
import Testing
import XiaolaiDictTestSupport

/// **The one place a question is sent to a source**: which source the reader's settings name, read at every question;
/// a source they leave put away — its process ended, and seen to end — before the next is asked; and nothing warmed by
/// a lookup but the local model.
struct ModelBackendRouterTests {
    static let explanation = SentenceQuestion(sentence: "He paid the fine.", term: "fine",
                                              senseText: "a sum of money exacted as a penalty by a court of law")

    /// The reader's settings, as a test changes them between questions.
    final class Settings: Sendable {
        private let source: Mutex<ProviderSource>
        init(_ source: ProviderSource) { self.source = Mutex(source) }
        var current: ProviderSource { source.withLock { $0 } }
        func choose(_ next: ProviderSource) { source.withLock { $0 = next } }
    }

    /// The bundled model, as a test sees it asked.
    final class LocalModel: Sendable {
        private let state = Mutex<(asked: [ModelRequest], prewarms: Int)>(([], 0))
        var asked: [ModelRequest] { state.withLock { $0.asked } }
        var prewarms: Int { state.withLock { $0.prewarms } }
        var access: ModelBackendRouter.Local {
            .init(ask: { [self] request in
                state.withLock { $0.asked.append(request) }
                return .explanation("from the local model")
            }, prewarm: { [self] in state.withLock { $0.prewarms += 1 } })
        }
    }

    /// A factory that hands out `provider` for every source, and counts what it was asked to make.
    final class Handing: Sendable {
        let provider: RecordingProvider
        private let made = Mutex<[ProviderSource]>([])
        init(_ provider: RecordingProvider) { self.provider = provider }
        var makes: [ProviderSource] { made.withLock { $0 } }
        var factory: ProviderFactory {
            ProviderFactory { [self] source in
                made.withLock { $0.append(source) }
                // Slow enough that questions asked together all arrive while it is being made.
                try? await Task.sleep(for: .milliseconds(50))
                return ProviderBuild(backend: provider)
            }
        }
    }

    static func router(_ settings: Settings, _ local: LocalModel, _ factory: ProviderFactory) -> ModelBackendRouter {
        ModelBackendRouter(source: { settings.current }, local: local.access, factory: factory,
                           dictionaryTextMayLeave: false)
    }

    static let loopback = ProviderSource.endpoint(url: "http://127.0.0.1:11434/v1", model: "m")
    static let hosted = ProviderSource.endpoint(url: "https://api.example.com/v1", model: "m")

    // MARK: - Which source

    /// **`none` and the local model ask the local model**, which answers "not installed" itself where there is none —
    /// so a reader who chose nothing, and a reader with a model on disk, are where they were before the providers.
    @Test func theLocalSourceAsksTheLocalModelAndNoProvider() async {
        let local = LocalModel(), handing = Handing(RecordingProvider { _ in "x" })
        let routed = await Self.router(Settings(.local), local, handing.factory)
            .ask(.explain(Self.explanation), origin: .reader)
        #expect(routed == RoutedReply(reply: .explanation("from the local model"), tier: .onThisMac))
        #expect(local.asked == [.explain(Self.explanation)])
        #expect(handing.makes.isEmpty, "a provider was made for the local source")
    }

    /// **A chosen provider is asked, and the local model is not**, with the tier its source has.
    @Test(arguments: [(loopback, ProviderTier.onThisMac), (hosted, .remote),
                      (.claudeCLI(path: nil, model: "haiku"), .remote)])
    func aChosenProviderIsAskedWithItsSourcesTier(source: ProviderSource, tier: ProviderTier) async {
        let local = LocalModel(), handing = Handing(RecordingProvider { _ in "It is a penalty here." })
        let routed = await Self.router(Settings(source), local, handing.factory)
            .ask(.explain(Self.explanation), origin: .reader)
        #expect(routed == RoutedReply(reply: .explanation("It is a penalty here."), tier: tier))
        #expect(local.asked.isEmpty, "the local model was asked while a provider was chosen")
        #expect(handing.makes == [source])
    }

    /// **The settings are read at every question**, so a question never goes to a source the reader has left — and the
    /// source they left is put away when they leave it, not when the router goes.
    @Test func theChoiceIsReadAtEveryQuestion() async {
        let settings = Settings(.local), local = LocalModel(), handing = Handing(RecordingProvider { _ in "From it." })
        let router = Self.router(settings, local, handing.factory)
        _ = await router.ask(.explain(Self.explanation), origin: .reader)
        settings.choose(Self.hosted)
        #expect(await router.ask(.explain(Self.explanation), origin: .reader).reply == .explanation("From it."))
        settings.choose(.local)
        _ = await router.ask(.explain(Self.explanation), origin: .reader)
        #expect(local.asked.count == 2)
        #expect(handing.provider.requests.count == 1)
        #expect(handing.provider.shutDowns == 1, "the provider the reader left was not put away")
    }

    /// **Questions asked together while a source is being made make it once** — a second provider would be a second
    /// CLI process, with nothing holding it.
    @Test func questionsAskedTogetherMakeOneProvider() async {
        let handing = Handing(RecordingProvider { _ in "Once." })
        let router = Self.router(Settings(Self.hosted), LocalModel(), handing.factory)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = await router.ask(.explain(Self.explanation), origin: .reader) } }
        }
        #expect(handing.makes.count == 1)
        #expect(handing.provider.requests.count == 5)
    }

    /// **A source left and chosen again is made again, and a question still waiting on the first making is not handed
    /// it once it has been put away.** A, then B, then A again, each question asked while the first A is still being
    /// made: the question for B puts the first A away when that making ends, and the first question — matched by its
    /// source alone — would then be handed the A that had just been put away, while a new A was being made.
    @Test func aSourceChosenAgainIsANewOneAndTheOldIsNeverAsked() async {
        let settings = Settings(Self.hosted)
        let first = RecordingProvider { _ in "From the first." }, second = RecordingProvider { _ in "From the second." }
        let made = Mutex(0)
        let factory = ProviderFactory { source in
            guard source == Self.hosted else { return ProviderBuild(backend: RecordingProvider { _ in "From B." }) }
            let count = made.withLock { $0 += 1; return $0 }
            if count == 1 { try? await Task.sleep(for: .milliseconds(400)) }
            return ProviderBuild(backend: count == 1 ? first : second)
        }
        let router = Self.router(settings, LocalModel(), factory)
        async let waiting = router.ask(.explain(Self.explanation), origin: .reader)
        try? await Task.sleep(for: .milliseconds(50))
        settings.choose(Self.loopback)
        async let leaving = router.ask(.explain(Self.explanation), origin: .reader)
        try? await Task.sleep(for: .milliseconds(50))
        settings.choose(Self.hosted)
        let again = await router.ask(.explain(Self.explanation), origin: .reader)
        _ = await (waiting, leaving)
        #expect(again.reply == .explanation("From the second."))
        #expect(first.requests.isEmpty, "a question was sent to a source after it had been put away")
        #expect(first.shutDowns == 1)
    }

    /// A source that could not be made answers nothing, so the ladder falls through — and says why when checked.
    @Test func aSourceThatCannotBeMadeAnswersNothingAndSaysWhy() async {
        let refused = ProviderFactory { _ in ProviderBuild(refusal: .cli(.notInstalled)) }
        let router = Self.router(Settings(.claudeCLI(path: nil, model: "haiku")), LocalModel(), refused)
        #expect(await router.ask(.explain(Self.explanation), origin: .reader) == RoutedReply(reply: nil, tier: .remote))
        #expect(await router.check() == .cli(.notInstalled))
    }

    // MARK: - Warming

    /// **A lookup prewarms the local model and nothing else**: a lookup that started a CLI or asked an endpoint would
    /// spend the reader's subscription on a pane they may never open.
    @Test func aLookupPrewarmsOnlyTheLocalModel() async {
        let local = LocalModel(), handing = Handing(RecordingProvider(warmsByAsking: true) { _ in "ready" })
        let settings = Settings(.local)
        let router = Self.router(settings, local, handing.factory)
        await router.prewarmForLookup()
        #expect(local.prewarms == 1)
        settings.choose(.claudeCLI(path: nil, model: "haiku"))
        await router.prewarmForLookup()
        #expect(local.prewarms == 1, "the local model was loaded while a provider was chosen")
        #expect(handing.makes.isEmpty && handing.provider.checks == 0, "a lookup started a provider")
    }

    /// **Reconciling warms a source that is warmed by asking, and asks an endpoint nothing**: its connection opens on
    /// the reader's first question, and a request at every launch would be spent on nothing.
    @Test func reconcilingWarmsAResidentSourceAndAsksAnEndpointNothing() async {
        let resident = Handing(RecordingProvider(warmsByAsking: true) { _ in "ready" })
        #expect(await Self.router(Settings(.claudeCLI(path: nil, model: "haiku")), LocalModel(), resident.factory)
            .reconcile() == .endpointReady(answeredIn: .milliseconds(1)))
        #expect(resident.provider.checks == 1)

        let endpoint = Handing(RecordingProvider(warmsByAsking: false) { _ in "ready" })
        #expect(await Self.router(Settings(Self.hosted), LocalModel(), endpoint.factory).reconcile() == nil)
        #expect(endpoint.makes == [Self.hosted], "the endpoint was not made ready")
        #expect(endpoint.provider.checks == 0 && endpoint.provider.requests.isEmpty, "an endpoint was asked at launch")
    }

    /// **A source is warmed once per choice, however often its settings are read.** The app reconciles at every write
    /// to its suite — a window's frame among them — and a CLI asked its trivial question each time would spend the
    /// reader's subscription on nothing. The control: the same source chosen again after another is a new one, warmed.
    @Test func reconcilingAnUnchangedSourceAsksNothingMore() async {
        let settings = Settings(.claudeCLI(path: nil, model: "haiku"))
        let resident = Handing(RecordingProvider(warmsByAsking: true) { _ in "ready" })
        let router = Self.router(settings, LocalModel(), resident.factory)
        #expect(await router.reconcile() == .endpointReady(answeredIn: .milliseconds(1)))
        for _ in 0..<3 { await router.reconcile() }
        #expect(resident.provider.checks == 1, "an unchanged source was asked its question again")
        settings.choose(.local)
        await router.reconcile()
        settings.choose(.claudeCLI(path: nil, model: "haiku"))
        await router.reconcile()
        #expect(resident.provider.checks == 2, "a source chosen again was not warmed")
    }

    /// `check` always asks — the instrument's question, and the reader's *Check connection* — an endpoint too.
    @Test func checkingAsksEvenAnEndpoint() async {
        let endpoint = Handing(RecordingProvider { _ in "ready" })
        let router = Self.router(Settings(Self.hosted), LocalModel(), endpoint.factory)
        #expect(await router.check() == .endpointReady(answeredIn: .milliseconds(1)))
        #expect(endpoint.provider.checks == 1)
        #expect(await Self.router(Settings(.local), LocalModel(), endpoint.factory).check() == nil)
    }

    // MARK: - No orphan: a real CLI process, ended and seen to end

    /// A factory that finds `fake` where the installers put a CLI, starts it in a directory of the test's own, and
    /// reports its process's events to `events`.
    static func factory(finding fake: FakeCLI, events: EventLog) -> ProviderFactory {
        ProviderFactory(
            locator: CLILocator(searchDirectories: [fake.directory.url], loginShell: nil, shellTimeout: .seconds(1)),
            credentials: InMemoryCredentials(), configuration: ResidentSessionTests.configuration(),
            endpointSession: { .ephemeral }, scratch: { ScratchDirectory(in: fake.directory.url) },
            events: fake.holding(events.sink))
    }

    /// **Leaving a CLI ends its process, and the router does not return until it has gone.** Asserted the moment the
    /// call returns, and by the session's own record that it was shut down — a process merely dropped is ended later,
    /// by a timer, and leaves no such record.
    @Test func leavingACLIEndsItsProcessBeforeTheNextSourceIsUsed() async throws {
        let fake = try FakeCLI.claude()
        let events = EventLog()
        let settings = Settings(.claudeCLI(path: nil, model: "haiku"))
        let router = Self.router(settings, LocalModel(), Self.factory(finding: fake, events: events))
        let first = try answeringPID(try #require(await Self.answer(router)))
        #expect(isAlive(first))

        settings.choose(.local)
        await router.reconcile()
        #expect(!isAlive(first), "the CLI outlived the choice that started it")
        #expect(events.all.contains { $0.event == .retired(pid: first, .shutDown) })
    }

    /// The same when the reader's change is first seen by a question rather than by `reconcile`.
    @Test func aQuestionAfterTheChoiceChangedEndsTheProcessFirst() async throws {
        let fake = try FakeCLI.claude()
        let events = EventLog()
        let settings = Settings(.claudeCLI(path: nil, model: "haiku"))
        let router = Self.router(settings, LocalModel(), Self.factory(finding: fake, events: events))
        let first = try answeringPID(try #require(await Self.answer(router)))

        settings.choose(.local)
        _ = await router.ask(.explain(Self.explanation), origin: .reader)
        #expect(!isAlive(first))
        #expect(events.all.contains { $0.event == .retired(pid: first, .shutDown) })
    }

    /// **Shutting down — the app's quit — ends every process and returns once each has gone.**
    @Test func shuttingDownEndsTheCLIProcess() async throws {
        let fake = try FakeCLI.claude()
        let events = EventLog()
        let router = Self.router(Settings(.claudeCLI(path: nil, model: "haiku")), LocalModel(),
                                 Self.factory(finding: fake, events: events))
        let first = try answeringPID(try #require(await Self.answer(router)))
        await router.shutDown()
        #expect(!isAlive(first), "the CLI outlived the app's quit")
        #expect(events.all.contains { $0.event == .retired(pid: first, .shutDown) })
    }

    /// **Reconciling at launch starts the chosen CLI and asks it the preflight's question**, so the reader's first
    /// real question finds it warm — and the process is the one that question is then answered by.
    @Test func reconcilingStartsTheChosenCLIWarm() async throws {
        let fake = try FakeCLI.claude()
        let router = Self.router(Settings(.claudeCLI(path: nil, model: "haiku")), LocalModel(),
                                 Self.factory(finding: fake, events: EventLog()))
        guard case .cli(.ready)? = await router.reconcile() else {
            Issue.record("the chosen CLI was not started and asked")
            return
        }
        let warmed = try fake.logged("pid", as: Int.self)
        #expect(try fake.logged("text", as: String.self).count == 1)
        let answered = try answeringPID(try #require(await Self.answer(router)))
        #expect(warmed.allSatisfy { Int32($0) == answered }, "the first question started another process")
        await router.shutDown()
    }

    /// An explanation from `router`, as text — the fake's answer names its pid.
    static func answer(_ router: ModelBackendRouter) async -> String? {
        guard case .explanation(let text)? = await router.ask(.explain(explanation), origin: .reader).reply
        else { return nil }
        return text
    }
}

/// **The source a reader's choice and settings name**, and the tier it runs at.
struct ProviderSourceTests {
    static let settings = ProviderSettings(
        endpointURL: "http://localhost:11434/v1", endpointModel: "llama", claudeCLIPath: "/opt/claude",
        codexCLIPath: "/opt/codex", claudeCLIModel: "sonnet", codexCLIModel: "gpt")

    @Test func eachChoiceNamesItsSourceWithOnlyTheSettingsItUses() {
        #expect(ProviderSource(choice: .none, settings: Self.settings) == .local)
        #expect(ProviderSource(choice: .localModel, settings: Self.settings) == .local)
        #expect(ProviderSource(choice: .claudeCLI, settings: Self.settings) == .claudeCLI(path: "/opt/claude", model: "sonnet"))
        #expect(ProviderSource(choice: .codexCLI, settings: Self.settings) == .codexCLI(path: "/opt/codex", model: "gpt"))
        #expect(ProviderSource(choice: .openAICompatible, settings: Self.settings)
            == .endpoint(url: "http://localhost:11434/v1", model: "llama"))
    }

    /// Both CLIs are remote whatever is installed where; an endpoint is on this Mac only where its host is loopback.
    @Test func theTierIsRemoteDisclosuresRule() {
        #expect(ProviderSource.local.tier == .onThisMac)
        #expect(ProviderSource.claudeCLI(path: nil, model: "haiku").tier == .remote)
        #expect(ProviderSource.codexCLI(path: nil, model: "").tier == .remote)
        #expect(ProviderSource.endpoint(url: "http://127.0.0.1:1234/v1", model: "m").tier == .onThisMac)
        #expect(ProviderSource.endpoint(url: "https://api.openai.com/v1", model: "m").tier == .remote)
        #expect(ProviderSource.endpoint(url: "http://192.168.1.2:11434/v1", model: "m").tier == .remote)
    }
}

/// **The factory makes the provider a source names, or says what the reader must do instead.**
struct ProviderFactoryTests {
    static func factory(searching directory: URL, scratch: URL) -> ProviderFactory {
        ProviderFactory(
            locator: CLILocator(searchDirectories: [directory], loginShell: nil, shellTimeout: .seconds(1)),
            credentials: InMemoryCredentials(), configuration: ResidentSessionTests.configuration(),
            endpointSession: { .ephemeral }, scratch: { ScratchDirectory(in: scratch) }, events: { _ in })
    }

    /// An endpoint that cannot be asked anything is refused before anything is made: no model named, a base URL that
    /// is not http(s), or not a URL at all.
    @Test(arguments: [("https://api.example.com/v1", ""), ("ftp://api.example.com/v1", "m"), ("not a url", "m"),
                      ("", "m")])
    func anEndpointThatCannotBeAskedIsRefused(url: String, model: String) async {
        let empty = TemporaryDirectory(named: "xiaolaidict-factory")
        let build = await Self.factory(searching: empty.url, scratch: empty.url).make(.endpoint(url: url, model: model))
        #expect(build.backend == nil)
        #expect(build.refusal == .endpointUnusable)
    }

    @Test func anEndpointThatCanBeAskedIsMade() async {
        let empty = TemporaryDirectory(named: "xiaolaidict-factory")
        let build = await Self.factory(searching: empty.url, scratch: empty.url)
            .make(.endpoint(url: "http://localhost:11434/v1", model: "llama"))
        #expect(build.backend is OpenAICompatibleProvider)
        #expect(build.refusal == nil)
    }

    /// A CLI that is nowhere is not installed; a path the reader gave that is not a program is theirs to correct.
    @Test func aCLIThatCannotBeFoundSaysWhatTheReaderMustDo() async {
        let empty = TemporaryDirectory(named: "xiaolaidict-factory")
        let factory = Self.factory(searching: empty.url, scratch: empty.url)
        #expect(await factory.make(.claudeCLI(path: nil, model: "haiku")).refusal == .cli(.notInstalled))
        #expect(await factory.make(.codexCLI(path: "/nonexistent/codex", model: "")).refusal
            == .cli(.overrideUnusable(path: "/nonexistent/codex")))
    }

    /// **A CLI that is found is started in an empty directory of its own, removed with the build** — the CLIs read
    /// instructions from the directory they run in.
    @Test func aFoundCLIIsMadeInADirectoryRemovedWithIt() async throws {
        let fake = try FakeCLI.claude()
        let scratch = TemporaryDirectory(named: "xiaolaidict-factory")
        var build: ProviderBuild? = await Self.factory(searching: fake.directory.url, scratch: scratch.url)
            .make(.claudeCLI(path: nil, model: "haiku"))
        #expect(build?.backend is ClaudeCLIProvider)
        let made = try FileManager.default.contentsOfDirectory(atPath: scratch.url.path)
        #expect(made.count == 1, "\(made)")
        await build?.backend?.shutDown()
        build = nil
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.url.path).isEmpty,
                "the CLI's directory outlived it")
    }

    /// The local source is not a provider: nothing is made, and nothing is refused.
    @Test func theLocalSourceMakesNothing() async {
        let empty = TemporaryDirectory(named: "xiaolaidict-factory")
        let build = await Self.factory(searching: empty.url, scratch: empty.url).make(.local)
        #expect(build.backend == nil && build.refusal == nil)
    }
}
