import Foundation
import ModelKit
import Observation
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictUI
import os

/// The local model as the app holds it: **the store and the download on one side, the service on
/// the other, and the lifecycle between them.**
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
    @ObservationIgnored private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "model")

    init(
        defaults: UserDefaults, store: ModelStore = .standard(), client: ModelClient = ModelClient(),
        transport: any ModelFileTransport = URLSessionModelTransport(),
        physicalMemory: UInt64 = SystemMemory.physical
    ) {
        controller = LocalModelController(
            defaults: defaults, store: store, physicalMemory: physicalMemory, transport: transport)
        access = LocalModelAccess(client: client, store: store)
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

    /// The shipped sense ladder — the local model first, Apple's on-device model, `NLEmbedding`.
    var senseLadder: LadderSenseSelector { access.senseLadder.ladder }

    /// Loads the model beside a lookup, so the sense question after it does not pay for the load.
    func prewarm() async { await access.prewarm() }

    /// What the lookup panel's sentence pane is handed: the downloaded model first, Apple's
    /// on-device model **wherever that one does not answer** — not downloaded, not enough memory,
    /// declined, a generation that failed, a reply of the wrong shape, or no service at all. Read
    /// at the click, like the translator.
    var explanationActions: ExplanationActions {
        ExplanationActions { [access] question in await access.explainer.explain(question) }
    }

    /// What the lookup panel's translation pane is handed: the translator, the reader's language,
    /// and the download to put beside Apple's answer.
    var translationActions: TranslationActions {
        let choice = controller.choice
        return TranslationActions(
            translate: { [access] question in await access.translator.translate(question) },
            target: ReaderLanguage.preferred,
            // The translator's own, so the control and the answer cannot disagree about whether this
            // sentence was worth asking about.
            sourceLanguage: { [access] sentence in access.translator.sourceLanguage(of: sentence) },
            canDownloadModel: choice.canDownload,
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
