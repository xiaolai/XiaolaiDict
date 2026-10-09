import Foundation
import ModelKit
import Observation
import XiaolaiDictBase
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
    @ObservationIgnored private let probe: any ModelHostProbe
    /// The reader's choice of where weights come from. Read at each download rather than held,
    /// so changing it in Settings takes effect on the next one without anything being rebuilt.
    @ObservationIgnored private let sources: ModelSourceStore
    @ObservationIgnored private let choices: ModelChoiceStore
    /// `ShowLocalModelSetup`, read each time the choice is built — so a reader who sets it sees the setup the next time
    /// a surface draws, without a relaunch.
    @ObservationIgnored private let setupFlag: LocalModelSetupFlag
    @ObservationIgnored private let physicalMemory: UInt64
    /// **Read at each question, and injected like the clock.** Free memory changes minute to
    /// minute, and a test that asked the real machine would be measuring the machine.
    @ObservationIgnored private let availableMemory: @Sendable () -> UInt64?
    /// What each size downloads — the pinned manifests; a test hands in small ones.
    @ObservationIgnored private let manifest: @Sendable (LocalModelSize) -> ModelManifest
    @ObservationIgnored private var download: Task<Void, Never>?
    /// Which download is current. Progress arrives on tasks of its own, and one from a download that
    /// has since finished — or been replaced — must not write over the one running now.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "model")
    /// **The model that answers is about to change** — a download finished, a model arrived without this app
    /// downloading it, the reader chose another or removed one. **Called synchronously, before the change is
    /// published**: the app holds the local rung back at once — so no question reaches the service holding the old
    /// model in between — and ends that service, handing back the ending, which a caller that must wait for it awaits.
    /// A service keeps the model it loaded, so without this the change reached an answer only when it idled out.
    @ObservationIgnored var onModelChanging: (@MainActor () -> Task<Void, Never>)?
    /// The model the last removal could not remove, where it could not — said on the row until the next attempt.
    private(set) var removalFailed: LocalModelSize?

    init(
        defaults: UserDefaults, store: ModelStore = .standard(),
        physicalMemory: UInt64 = SystemMemory.physical,
        availableMemory: @escaping @Sendable () -> UInt64? = { SystemMemory.available() },
        transport: any ModelFileTransport = URLSessionModelTransport(),
        probe: any ModelHostProbe = URLSessionModelHostProbe(),
        manifest: @escaping @Sendable (LocalModelSize) -> ModelManifest = { $0.manifest }
    ) {
        self.store = store
        self.transport = transport
        self.probe = probe
        let sources = ModelSourceStore(defaults: defaults)
        self.sources = sources
        source = sources.load()
        let choices = ModelChoiceStore(defaults: defaults)
        self.choices = choices
        wanted = choices.load()
        self.physicalMemory = physicalMemory
        self.availableMemory = availableMemory
        self.manifest = manifest
        declines = LocalModelDeclineStore(defaults: defaults)
        setupFlag = LocalModelSetupFlag(defaults: defaults)
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
            // `onModelChanging` holds the local rung back **in this same turn**, before "ready" is
            // published below — so from that moment until the unload finishes nothing is asked of the
            // process that still has the old model. It used to be taken on a task of its own, which
            // ran after "ready" was already drawn.
            if case .ready(let size) = read, state.answering != size {
                _ = onModelChanging?()
            }
            state = read
        }
        if case .ready = read { pruneStrays() }
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
    /// **Every model this build knows is kept**, whichever one is answering. What goes is a
    /// superseded revision and a directory nobody asked for — ADR-0041.
    private func pruneStrays() {
        let store = store
        let keep = LocalModelSize.allCases.map(manifest)
        pruning = Task.detached(priority: .background) { _ = store.removeStrays(keeping: keep) }
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
        let publish = progressPublisher(for: size, replacing: replacing, generation: current)
        state = .downloading(
            ModelDownloadProgress(received: 0, total: wanted.totalBytes), size: size, replacing: replacing)
        log.notice("model: downloading \(wanted.identifier, privacy: .public)")
        let chosen = source
        let transport = transport
        let probe = probe
        let store = store
        download = Task { [weak self] in
            do {
                // **Measured once, before the transfer.** A named host is an order already; only
                // `fastest` asks, and it asks about the largest file because that is the one the
                // choice is actually about.
                let order: [ModelHost]
                if let fixed = chosen.fixedOrder {
                    order = fixed
                } else {
                    let largest = wanted.files.max { $0.size < $1.size } ?? wanted.files[0]
                    let measured = await probe.measure(largest, among: ModelHost.allCases)
                    // **What it measured, not just what it chose.** A probe that picks the
                    // slower host reads exactly like one that picked well, and these are the
                    // only numbers that tell them apart from a reader's machine.
                    let summary = measured.sorted { $0.host.rawValue < $1.host.rawValue }
                        .map { "\($0.host.rawValue) \($0.bytes)B" }.joined(separator: ", ")
                    self?.log.notice("model: probed \(summary, privacy: .public)")
                    order = ModelHost.ranked(measured)
                }
                try Task.checkCancellation()
                self?.log.notice("model: fetching from \(order.map(\.rawValue).joined(separator: ", "), privacy: .public)")
                let downloader = ModelDownloader(store: store, transport: transport, hosts: order)
                try await downloader.install(wanted, progress: publish)
                await self?.installed(size, keeping: wanted)
            } catch {
                self?.log.error("model: download stopped: \(Self.logDescription(error), privacy: .public)")
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
        // **Staleness is about when a reading was taken, not how large it is.** Dropping any
        // reading below the one on screen kept the bar honest against callbacks that arrive out
        // of order — and made it lie when a file genuinely restarts: a host that ignores the
        // range truncates what was there, and the bar sat at 80% through a re-download of
        // gigabytes. A ticket taken in call order tells the two apart with no threshold.
        let ordering = ProgressOrder()
        return { [weak self] progress in
            guard throttle.shouldPublish(progress) else { return }
            let ticket = ordering.next()
            Task { @MainActor [weak self] in
                guard let self, self.generation == current,
                      case .downloading = self.state, ordering.isNewest(ticket)
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
        let keep = LocalModelSize.allCases.map(manifest)
        let left = await Task.detached(priority: .utility) { store.removeStrays(keeping: keep) }.value
        // The new model is installed and works; what is left over is only disk it will not use. It
        // is named rather than shrugged off, and `pruneStrays` tries again on the next refresh.
        if !left.isEmpty {
            log.error("model: could not remove \(left.joined(separator: ", "), privacy: .public)")
        }
        log.notice("model: installed \(wanted.identifier, privacy: .public)")
        await onModelChanging?().value
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
    /// Kept as a name the tests and this file use; the rule itself lives in `ModelKit`, beside
    /// the download, because it was needed in a second place the day after it was written.
    static func logDescription(_ error: any Error) -> String { modelFailureDescription(error) }

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
        case ModelDownloadError.rangeMismatch:
            return String(localized: "the server sent a different part of the file than was asked for",
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

    /// Which model the reader has chosen to answer, or nil where they have not said.
    private(set) var wanted: LocalModelSize?

    /// What the switch lists: each model on disk with what it occupies. **Measured rather than
    /// taken from the manifest**, because what the reader is weighing is the space it is using.
    var onDiskModels: [LocalModelChoice.InstalledModel] {
        installedSizes.map {
            LocalModelChoice.InstalledModel(size: $0, bytes: manifest($0).totalBytes)
        }
    }

    /// Every model on disk this Mac can be offered, smallest first — what the switch lists.
    var installedSizes: [LocalModelSize] {
        store.installedManifests(among: offered.map(manifest)).map(\.size).sorted()
    }

    /// **Which model answers, and whether it is the one that was asked for.** Recomputed rather
    /// than stored: free memory changes minute to minute, so a stored verdict goes stale in the
    /// one direction that matters — claiming a model will load when it will not.
    var answeringChoice: ModelChoice {
        ModelSizing.answering(
            wanted: wanted, installed: installedSizes,
            physicalMemory: physicalMemory, availableMemory: availableMemory() ?? 0)
    }

    /// Chooses which installed model answers. **Takes effect on the next question**, and is kept
    /// even where that model cannot be loaded right now: the reader's choice is a preference, not
    /// an assertion about this minute's free memory.
    /// **And ends the service holding the model chosen before**, which keeps the model it loaded — so the next question
    /// loads the one chosen now (ADR-0041: which model answers is the reader's).
    func choose(_ size: LocalModelSize?) {
        guard size != wanted else { return }
        wanted = size
        choices.save(size)
        log.notice("model: the reader chose \(size?.rawValue ?? "no model in particular", privacy: .public)")
        _ = onModelChanging?()
        refresh()
    }

    /// Removes a model the reader no longer wants, and forgets it as their choice if it was one — **once the service
    /// that may hold it has been ended**, so nothing answers from files that are gone. The row is read again after the
    /// files are, and a removal that failed is said (`removalFailed`), never dropped.
    func remove(_ size: LocalModelSize) async {
        removalFailed = nil
        if wanted == size {
            wanted = nil
            choices.save(nil)
        }
        await onModelChanging?().value
        let store = store, manifest = manifest(size), log = log
        log.notice("model: removing \(manifest.identifier, privacy: .public)")
        let removed = await Task.detached(priority: .utility) { () -> Bool in
            do {
                try store.remove(manifest)
                return true
            } catch {
                log.error("model: could not remove \(manifest.identifier, privacy: .public): \(modelFailureDescription(error), privacy: .public)")
                return false
            }
        }.value
        if !removed { removalFailed = size }
        refresh()
    }

    /// Where the reader has said weights should come from. **Observed**, so the picker redraws
    /// with what it set rather than with what it was built with.
    private(set) var source: ModelSource

    /// Takes effect on the next download: a transfer already running is not moved to another
    /// host underneath itself, which would restart a file rather than resume it.
    func chooseSource(_ chosen: ModelSource) {
        guard chosen != source else { return }
        source = chosen
        sources.save(chosen)
        log.notice("model: weights will be fetched from \(chosen.rawValue, privacy: .public)")
    }

    /// What the setup board and the translation pane are handed.
    var choice: LocalModelChoice {
        LocalModelChoice(
            state: state, declined: declined, offered: offered, recommended: recommended,
            download: { [weak self] in self?.startDownload($0) },
            decline: { [weak self] in self?.decline() },
            cancel: { [weak self] in self?.cancelDownload() },
            source: source,
            chooseSource: { [weak self] in self?.chooseSource($0) },
            onDisk: onDiskModels,
            chosen: wanted,
            answering: answeringChoice,
            choose: { [weak self] in self?.choose($0) },
            removeModel: { [weak self] size in Task { await self?.remove(size) } },
            setupFlagged: setupFlag.isSet(), removalFailed: removalFailed)
    }
}

/// Which progress reading is the newest, by the order the downloader produced them.
///
/// **Taken synchronously, checked after the hop.** The publisher's `Task { @MainActor }` hops are
/// not ordered against each other, so without this a reading taken earlier could land later and
/// overwrite a newer one. Comparing byte counts instead cannot tell a stale reading from a file
/// that restarted, which is a bar that freezes rather than one that flickers.
final class ProgressOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0
    private var delivered = 0

    func next() -> Int {
        lock.withLock { issued += 1; return issued }
    }

    func isNewest(_ ticket: Int) -> Bool {
        lock.withLock {
            guard ticket > delivered else { return false }
            delivered = ticket
            return true
        }
    }
}

/// Progress arrives once per network chunk — tens of thousands of times for 3 GB — and the board
/// needs a few hundred updates at most. Published when it has moved a quarter of a percent — **either
/// way**: a file that restarts goes back, and a throttle that took only growth held the bar at its old
/// figure through the whole re-download. A step back is published at once and is the new baseline.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Int64 = -1

    func shouldPublish(_ progress: ModelDownloadProgress) -> Bool {
        let step = max(progress.total / 400, 1)
        return lock.withLock {
            let restarted = progress.received < last
            guard restarted || progress.received >= progress.total || progress.received - last >= step
            else { return false }
            last = progress.received
            return true
        }
    }
}
