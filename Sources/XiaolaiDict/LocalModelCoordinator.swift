import DictionaryModel
import Foundation
import LLMProviders
import ModelKit
import Observation
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictUI
import os

/// The local model as the app holds it: **the store and the download on one side, the service on
/// the other, and the lifecycle between them** — and, since ADR-0053, the router that sends each
/// question to the local model or to the provider the reader chose.
///
/// Its own type because the app delegate is not the place: model persistence, a multi-gigabyte
/// download, an XPC service's lifetime, the sense ladder's composition and the translation pane's
/// engines are one subject, and the delegate already has several.
@Observable
@MainActor
final class LocalModelCoordinator {
    /// Private on purpose: everything the app needs is a named operation below. Reached directly,
    /// the client would answer questions without the unload-before-ready lifecycle around it.
    private let controller: LocalModelController
    @ObservationIgnored private let access: LocalModelAccess
    /// **The one composition point** (ADR-0053, plan §2): every question the ladders ask goes through it, to the local
    /// model or to the reader's provider, read from their settings at that question. Private for the controller's
    /// reason: the panes are handed named operations below, never a way to ask around the router.
    @ObservationIgnored private let router: ModelBackendRouter
    /// The suite the reader's choice is kept in, watched so a change reaches the router when it is made.
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var settingsObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "model")
    /// **What Settings › Language Model shows and changes**, over the suite this coordinator was given and the Keychain
    /// items the providers read — so the key the pane files is the key a provider reads, under the account its endpoint's
    /// origin names. Its check asks the router; the warming at a change is handed to it by `start()`.
    let languageModel: LanguageModelPaneModel

    /// `credentials` is the store the pane files a key in; it must be the one `providers` reads from, which for the
    /// app's own is the Keychain. A test handing a factory of its own hands a store of its own.
    init(
        defaults: UserDefaults, store: ModelStore = .standard(), client: ModelClient = ModelClient(),
        transport: any ModelFileTransport = URLSessionModelTransport(),
        probe: any ModelHostProbe = URLSessionModelHostProbe(),
        physicalMemory: UInt64 = SystemMemory.physical,
        providers: ProviderFactory = .standard,
        credentials: any CredentialStore = KeychainCredentialStore()
    ) {
        controller = LocalModelController(
            defaults: defaults, store: store, physicalMemory: physicalMemory,
            transport: transport, probe: probe)
        let access = LocalModelAccess(client: client, store: store)
        self.access = access
        // The local model is reached through its access, which answers "not installed" without starting the service
        // where there is no model — so `none`, the reader's default, is exactly what it was before the providers.
        router = ModelBackendRouter(
            choices: ProviderChoiceStore(defaults: defaults), settings: ProviderSettingsStore(defaults: defaults),
            local: .init(ask: { request in await access.ask(request) }, prewarm: { await access.prewarm() }),
            factory: providers)
        self.defaults = defaults
        languageModel = LanguageModelPaneModel(defaults: defaults, credentials: credentials) { [router] in
            await router.check()
        }
        // A new model is answered from only once the service holding the old one has gone.
        //
        // **Ready is still published if it will not go.** The model is on disk and is what the next
        // service loads; refusing to say so would leave the row unfinished for as long as a stuck
        // process lives, which is worse than a few answers from the model being replaced. The
        // failure is recorded rather than swallowed.
        controller.onInstalled = { [access, log] in
            // **Held for the length of the unload**, so nothing is asked of the old process while
            // it is being ended — the window `refresh()` opens by publishing "ready" without
            // awaiting this. Released only where the process was *seen* to go.
            access.quarantine.hold()
            if await access.client.unload() {
                access.quarantine.lift()
                log.notice("model: the service holding the previous model has ended")
            } else {
                // **Ready is still published — and the local rung is held back until that process
                // goes.** Refusing to say ready would leave the row unfinished for as long as a
                // stuck service lives; letting the rung answer would let the model the reader just
                // replaced go on answering, with nothing on screen to say so. The quarantine lifts
                // itself as soon as the process is seen to be gone, and meanwhile the ladder falls
                // to Apple's model and the translator to Apple's framework, labelled as always.
                // **Nothing is taken here**: the quarantine was taken above and only the branch
                // that saw the process go lifts it, so this branch simply leaves it held. The
                // second `hold()` that used to stand here set a flag that was already set.
                log.error("model: the service did not confirm it had ended; the local model is held back until it has")
            }
        }
    }

    /// What the setup board's row reads and acts through.
    var choice: LocalModelChoice { controller.choice }
    /// The model's licence, where a model is downloaded — what About names.
    var licenceURL: URL? { controller.licenceURL }

    /// Re-reads the store. Called where the reader looks: the board opening, and the menu.
    func refresh() { controller.refresh() }

    /// The prune the last `refresh()` started — see `LocalModelController.pruning`. Forwarded so a
    /// caller holding only the coordinator can still wait for work `refresh()` does not await.
    var pruning: Task<Void, Never>? { controller.pruning }

    /// The shipped sense ladder — the source the reader chose first (the local model, or their provider), Apple's
    /// on-device model, `NLEmbedding`. **Asked by every lookup**, so it asks for `.lookup`: a remote provider is never
    /// asked a sense question a lookup fired (plan §6).
    var senseLadder: LadderSenseSelector {
        LocalModelAccess.senseLadder(topRung: LocalModelSenseSelector { [router] question in
            await router.ask(.pickSense(question), origin: .lookup).reply
        }).ladder
    }

    /// Loads the model beside a lookup, so the sense question after it does not pay for the load — the local model
    /// only: a lookup that started a provider would spend the reader's subscription on a pane they may never open.
    func prewarm() async { await router.prewarmForLookup() }

    /// **At launch: the chosen source brought up — a CLI started and warmed — and kept to the reader's settings.** A
    /// change made in this process (the settings pane writes the suite this coordinator was given) puts the source left
    /// away and warms the one chosen at once; one made outside it is seen at the next question, which reads the
    /// settings itself. Idempotent: a second call watches nothing twice.
    ///
    /// **What the warmed source said is handed to the Language Model pane** — the preflight's answer, with the source
    /// it is about — so the pane shows it without spending a second question of the reader's subscription.
    func start() {
        guard settingsObserver == nil else { return }
        let router = router, pane = languageModel
        let reconcile: @Sendable () -> Void = {
            Task { @MainActor in pane.record(await router.reconcile()) }
        }
        reconcile()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { _ in
            reconcile()
        }
    }

    /// The observer goes with the coordinator: `NotificationCenter` keeps it until it is removed. `isolated` so it can
    /// reach the registration — a nonisolated `deinit` cannot touch a main-actor property.
    isolated deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    /// Puts every provider away — a CLI's process ended and seen to end — before the app quits.
    ///
    /// **`nonisolated`, so it never waits for the main actor**: the router is an actor of its own, and a quit can be
    /// asked for from inside the main queue's drain — SIGTERM's handler is — where nothing that needs the main actor
    /// runs until the quit itself returns (`XiaolaiDictApp.endProvidersThenQuit`).
    nonisolated func shutDown() async { await router.shutDown() }

    /// What the lookup panel's sentence pane is handed: the source the reader chose first, Apple's
    /// on-device model **wherever that one does not answer** — not downloaded, not enough memory,
    /// declined, a generation that failed, a reply of the wrong shape, a provider that is not there,
    /// or no service at all. **Asked because the reader asked** (decision D4), and said to be remote
    /// where a remote source answered (`ModelProvenance`). Read at the click, like the translator.
    var explanationActions: ExplanationActions {
        ExplanationActions { [router] question in
            let answered = RoutedAnswer()
            let explainer = LocalModelAccess.explainer { question in
                answered.keep(await router.ask(.explain(question), origin: .reader))
            }
            return ModelProvenance.explanation(await explainer.explain(question), answeredBy: answered.last)
        }
    }

    /// The translator for one question: the router asked because the reader asked, and where it sent the question
    /// kept beside the answer for the pane's label.
    private nonisolated static func translator(asking router: ModelBackendRouter,
                                               keeping answered: RoutedAnswer) -> SentenceTranslator {
        LocalModelAccess.translator { question in
            answered.keep(await router.ask(.translate(question), origin: .reader))
        }
    }

    /// What the lookup panel's translation pane is handed: the translator, the reader's language,
    /// and the download to put beside Apple's answer.
    var translationActions: TranslationActions {
        let choice = controller.choice
        return TranslationActions(
            translate: { [router] question in
                let answered = RoutedAnswer()
                let outcome = await Self.translator(asking: router, keeping: answered).translate(question)
                return ModelProvenance.translation(outcome, answeredBy: answered.last)
            },
            target: ReaderLanguage.preferred,
            // The translator's own, so the control and the answer cannot disagree about whether this
            // sentence was worth asking about.
            sourceLanguage: { [router] sentence in
                Self.translator(asking: router, keeping: RoutedAnswer()).sourceLanguage(of: sentence)
            },
            // **Only where the bundled model's setup is shown** (ADR-0053): hidden, not removed.
            canDownloadModel: choice.canDownload && choice.isShown,
            // **What the row would download, read at the click** — which is the size a stopped
            // download was of, not the recommended one. Started from `recommended`, a stopped 9B
            // download answered the reader's "download" by fetching 4B instead: another three
            // gigabytes, and the one they had asked for abandoned part-finished.
            downloadModel: { [weak self] in
                guard let self, let size = self.controller.choice.downloadable else { return }
                self.controller.startDownload(size)
            })
    }
}
