import Foundation
import ModelKit
import Observation
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictUI
import os

/// The local model on this Mac: whether it is here, the download that brings it, and the reader's
/// **Not now**. Owned by the app, which the setup board and the translation pane read.
///
/// **State is read from the store, not remembered.** A model deleted from Finder is gone from the
/// board the next time it is refreshed, and a model finished by a previous launch is ready at this one.
@Observable
@MainActor
final class LocalModelController {
    private(set) var state: LocalModelState
    private(set) var declined: Bool
    /// What this Mac is offered, decided once from its memory — physical memory does not change
    /// while the app runs.
    let offered: [LocalModelSize]
    let recommended: LocalModelSize?

    @ObservationIgnored let store: ModelStore
    @ObservationIgnored private let declines: LocalModelDeclineStore
    @ObservationIgnored private let transport: any ModelFileTransport
    /// What each size downloads — the pinned manifests; a test hands in small ones.
    @ObservationIgnored private let manifest: @Sendable (LocalModelSize) -> ModelManifest
    @ObservationIgnored private var download: Task<Void, Never>?
    /// Which download is current. Progress arrives on tasks of its own, and one from a download that
    /// has since finished — or been replaced — must not write over the one running now.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "model")
    /// Called once a download is whole, **before** it is announced ready: the app ends the service,
    /// so no question asked after "ready" reaches the model that was there before.
    @ObservationIgnored var onInstalled: (@MainActor () async -> Void)?

    init(
        defaults: UserDefaults, store: ModelStore = .standard(),
        physicalMemory: UInt64 = SystemMemory.physical,
        transport: any ModelFileTransport = URLSessionModelTransport(),
        manifest: @escaping @Sendable (LocalModelSize) -> ModelManifest = { $0.manifest }
    ) {
        self.store = store
        self.transport = transport
        self.manifest = manifest
        declines = LocalModelDeclineStore(defaults: defaults)
        declined = declines.hasDeclined()
        offered = ModelSizing.offered(physicalMemory: physicalMemory)
        recommended = ModelSizing.recommended(physicalMemory: physicalMemory)
        state = Self.read(store: store, offered: offered, manifest: manifest)
    }

    /// A download left running by a controller that has gone would have nobody to tell it finished.
    isolated deinit {
        download?.cancel()
    }

    /// The model's licence, downloaded with its weights — what About names. Read through `state`,
    /// so a view showing it is redrawn when a download finishes.
    var licenceURL: URL? {
        guard case .ready(let size) = state else { return nil }
        let wanted = manifest(size)
        // The manifest's own licence file, not a second guess at its name. Built from
        // `licenceFileName` here as well, this was two independent ways to say where the licence is,
        // and a model whose licence is named differently would have been downloaded to one path and
        // looked for at another.
        guard let licence = wanted.licence, let directory = store.installed(wanted) else { return nil }
        return directory.appending(path: licence.path)
    }

    /// Re-reads the store — called when the board opens and when the menu does, so a model removed
    /// from Finder is noticed. A running download's own progress is the truth while it runs, and a
    /// stopped one keeps saying why until something is downloaded or asked for again.
    func refresh() {
        guard !state.isDownloading else { return }
        let read = Self.read(store: store, offered: offered, manifest: manifest)
        // A stopped download keeps saying why. What it says is **still answering**, though, is
        // re-read: the model an upgrade was replacing can be deleted while the message stands, and
        // a board that goes on naming a model that is gone reports a working app with none.
        if case .stopped(let reason, let size, let replacing) = state, read == .notDownloaded {
            if replacing != nil { state = .stopped(reason: reason, size: size, replacing: nil) }
            return
        }
        if read != state {
            // **A model that arrived without this app downloading it** — `--model-report` installs
            // one, and a reader can copy one in — is announced while a service may still be
            // answering from the model *it* loaded. The download path ends that service before
            // saying ready; this asks it to end too, rather than leaving the row naming one model
            // and the answers coming from another until the service idles out ten minutes later.
            // `onInstalled` is what holds the local rung back for the length of the unload — see
            // the coordinator — so the window between publishing "ready" here and that unload
            // finishing is one where nothing is asked of the process that still has the old model.
            if case .ready(let size) = read, state.answering != size {
                Task { [onInstalled] in await onInstalled?() }
            }
            state = read
        }
        if case .ready(let size) = read { pruneStrays(keeping: size) }
    }

    /// The prune the last `refresh()` started, or nil where it started none.
    ///
    /// **Work this class does not await still has to be waitable.** The prune runs detached so the
    /// board is not held by it, and it writes inside the store's root — so anything that owns that
    /// root, a test fixture above all, has to be able to wait for it before removing the directory
    /// underneath it. Holding the task is the only wait that says what it means: `nil` is "no prune
    /// was started", and a task is "here is the work, await it".
    ///
    /// What this replaced was a poll for `.staging/store.lock` appearing, and that could not tell
    /// three different situations apart. The lock file is created with `O_CREAT` and **never
    /// unlinked**, so it outlives the prune that made it: a store where anything had installed
    /// already had the file, and the poll returned at once having waited for nothing. Where no
    /// prune was started — `refresh()` only prunes when the store reads `.ready` — the poll instead
    /// spent its whole bound and answered false. And a `.background` task starved under a parallel
    /// test run had not written it yet. Same reading for "done", "never going to happen" and "not
    /// yet": five of six call sites were timing out silently and passing.
    @ObservationIgnored private(set) var pruning: Task<Void, Never>?

    /// Anything left from an earlier model, removed again — in the background, off the actor the
    /// board draws on. A removal that failed while the new model was installing, because a file was
    /// still open or a permission was missing, is **retried** here rather than logged once and
    /// forgotten: forgotten, it is gigabytes that stay for good.
    private func pruneStrays(keeping size: LocalModelSize) {
        let store = store
        let wanted = manifest(size)
        pruning = Task.detached(priority: .background) { _ = store.removeStrays(keeping: wanted) }
    }

    private static func read(
        store: ModelStore, offered: [LocalModelSize], manifest: (LocalModelSize) -> ModelManifest
    ) -> LocalModelState {
        if let size = installedSize(store: store, offered: offered, manifest: manifest) { return .ready(size) }
        return offered.isEmpty ? .tooLittleMemory : .notDownloaded
    }

    /// The largest size on disk, whole — **of the sizes this Mac is offered**. A model copied from a
    /// larger Mac, or left behind by one that had more memory free, is on disk and can never be
    /// loaded here: read as ready it would promise an answer the service then refuses for want of
    /// memory, which is a failure rendering as confidently as a success.
    private static func installedSize(
        store: ModelStore, offered: [LocalModelSize], manifest: (LocalModelSize) -> ModelManifest
    ) -> LocalModelSize? {
        store.installedManifests(among: offered.map(manifest)).map(\.size).max()
    }

    /// Starts — or resumes — a download of `size`. Only ever called by the reader's click: a 3 GB
    /// download never starts unasked.
    func startDownload(_ size: LocalModelSize) {
        guard download == nil, offered.contains(size) else { return }
        // Asking for the download is the opposite of Not now.
        if declined {
            declines.clear()
            declined = false
        }
        generation += 1
        let current = generation
        // What is answering while this downloads: an upgrade replaces a model that keeps working.
        let replacing = Self.installedSize(store: store, offered: offered, manifest: manifest)
        let wanted = manifest(size)
        let downloader = ModelDownloader(store: store, transport: transport)
        let publish = progressPublisher(for: size, replacing: replacing, generation: current)
        state = .downloading(
            ModelDownloadProgress(received: 0, total: wanted.totalBytes), size: size, replacing: replacing)
        log.notice("model: downloading \(wanted.identifier, privacy: .public)")
        download = Task { [weak self] in
            do {
                try await downloader.install(wanted, progress: publish)
                await self?.installed(size, keeping: wanted)
            } catch {
                self?.log.error("model: download stopped: \(String(describing: error), privacy: .public)")
                self?.finish(.stopped(reason: Self.reason(error), size: size, replacing: replacing))
            }
        }
    }

    /// Progress, throttled, published only while this download is the current one and never
    /// backwards — tasks carrying it can arrive out of order, or after a newer download began.
    private func progressPublisher(
        for size: LocalModelSize, replacing: LocalModelSize?, generation current: Int
    ) -> @Sendable (ModelDownloadProgress) -> Void {
        let throttle = ProgressThrottle()
        return { [weak self] progress in
            guard throttle.shouldPublish(progress) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == current,
                      case .downloading(let shown, _, _) = self.state, progress.received >= shown.received
                else { return }
                self.state = .downloading(progress, size: size, replacing: replacing)
            }
        }
    }

    /// The model is whole. Every other model on disk is removed — keeping two is gigabytes for
    /// nothing — and the service holding the old one is ended **before** "ready" is said.
    ///
    /// Off the main actor: this walks the store and deletes directories of several gigabytes, and
    /// the reader is looking at the board while it happens.
    private func installed(_ size: LocalModelSize, keeping wanted: ModelManifest) async {
        let store = store
        let left = await Task.detached(priority: .utility) { store.removeStrays(keeping: wanted) }.value
        // The new model is installed and works; what is left over is only disk it will not use. It
        // is named rather than shrugged off, and `pruneStrays` tries again on the next refresh.
        if !left.isEmpty {
            log.error("model: could not remove \(left.joined(separator: ", "), privacy: .public)")
        }
        log.notice("model: installed \(wanted.identifier, privacy: .public)")
        await onInstalled?()
        finish(.ready(size))
    }

    func cancelDownload() {
        download?.cancel()
    }

    func decline() {
        declines.decline()
        declined = true
    }

    private func finish(_ outcome: LocalModelState) {
        download = nil
        state = outcome
    }

    /// Why a download stopped, in the reader's terms — and never a network reason for a disk problem.
    static func reason(_ error: any Error) -> String {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return String(localized: "you stopped it", comment: "Why the model download stopped")
        }
        // **Every case of the store's own error is named.** Left to the generic ending, a download
        // refused for want of a disk reading, or one that ended with files missing, read as "could
        // not be completed" — which tells the reader nothing they can act on.
        switch error {
        case ModelDownloadError.insufficientDisk(let needed, _):
            return String(localized: "there is not enough free disk space — it needs \(needed.formatted(.byteCount(style: .file)))",
                          comment: "Why the model download stopped")
        case ModelDownloadError.diskCapacityUnknown:
            return String(localized: "this Mac would not say how much disk space is free",
                          comment: "Why the model download stopped")
        case ModelDownloadError.hashMismatch, ModelDownloadError.sizeMismatch:
            return String(localized: "a file did not match what was published, so it was discarded",
                          comment: "Why the model download stopped")
        case ModelDownloadError.couldNotDiscard:
            return String(localized: "a half-finished copy could not be cleared away",
                          comment: "Why the model download stopped")
        case ModelDownloadError.incomplete:
            return String(localized: "it ended before every file had arrived",
                          comment: "Why the model download stopped")
        case ModelDownloadError.alreadyInstalling:
            return String(localized: "it is already being downloaded",
                          comment: "Why the model download stopped")
        case ModelDownloadError.http(let status, _):
            return String(localized: "the server answered \(status)", comment: "Why the model download stopped")
        case let error as URLError where error.code == .notConnectedToInternet:
            return String(localized: "this Mac is not connected to the internet", comment: "Why the model download stopped")
        case is URLError:
            return String(localized: "the connection failed", comment: "Why the model download stopped")
        case let error as CocoaError where error.isFileError:
            return String(localized: "the model could not be saved to disk", comment: "Why the model download stopped")
        default:
            return String(localized: "the download could not be completed", comment: "Why the model download stopped")
        }
    }

    /// What the setup board and the translation pane are handed.
    var choice: LocalModelChoice {
        LocalModelChoice(
            state: state, declined: declined, offered: offered, recommended: recommended,
            download: { [weak self] in self?.startDownload($0) },
            decline: { [weak self] in self?.decline() },
            cancel: { [weak self] in self?.cancelDownload() })
    }
}

/// Progress arrives once per network chunk — tens of thousands of times for 3 GB — and the board
/// needs a few hundred updates at most. Published when it has moved a quarter of a percent.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = -1

    func shouldPublish(_ progress: ModelDownloadProgress) -> Bool {
        let step = max(progress.total / 400, 1)
        return lock.withLock {
            guard progress.received >= progress.total || progress.received - last >= step else { return false }
            last = progress.received
            return true
        }
    }
}
