import Foundation
import Synchronization

/// Where the form table is kept on disk, and nothing about what is in it.
///
/// **One file, written by the dictionary service and read by whoever asks a lemma.** The service is the only
/// process that links the container reader, so it builds; the app reads the result without linking the
/// reader (ADR-0051). Beside the phrase inventories and the index, in the support directory.
public struct FormTableStore: Sendable {
    public static let defaultDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/XiaolaiDict/forms")

    let directory: URL

    public init(directory: URL = FormTableStore.defaultDirectory) {
        self.directory = directory
    }

    var file: URL { directory.appending(path: "forms.table") }

    /// The stored table, whatever it was built from. Nil where there is none or it cannot be read as one —
    /// every way this fails means the same to every caller, which is "no table", so it is not `throws`.
    public func read() -> FormTable? {
        if case .table(let table) = load() { return table }
        return nil
    }

    /// What reading the file came to, **with the three ways it can fail told apart** — because they differ in
    /// whether trying again can help: a file that is not there, or whose bytes are not a table, fails the same way
    /// until it is rewritten, while one that could not be *read* (permissions, I/O) may recover.
    enum Load {
        case table(FormTable)
        case absent
        case unreadable
        case invalid
    }

    func load() -> Load {
        // **Absent is the system's word for it**, not a separate `fileExists`: that call answers false for a file it
        // merely could not stat, and a transient failure would then be filed as "nothing there" and acknowledged.
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .absent
        } catch {
            return .unreadable
        }
        return FormTable(decoding: text).map(Load.table) ?? .invalid
    }

    /// Written whole to a name of this writer's own, then moved into place: a reader — the app, on another
    /// process — never sees half a file, and two writers never replace each other's staging file.
    public func write(_ table: FormTable) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = file.appendingPathExtension("staging-\(UUID().uuidString)")
        try Data(table.encoded().utf8).write(to: staged, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// What `read()` would see change: the file's modification date and size, or nil where there is no file.
    /// A `stat`, so it is cheap enough to ask before every lemma.
    func stamp() -> Stamp? {
        guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate, let size = values.fileSize else { return nil }
        return Stamp(modified: date, size: size)
    }

    struct Stamp: Equatable, Sendable {
        let modified: Date
        let size: Int
    }
}

/// The table this process consults when it decides a lemma.
///
/// **Empty until something installs a source.** A process that never calls `use` — every test, and any tool
/// that links `DictionaryModel` for a wire type — lemmatises exactly as before, so no lemma depends on what
/// happens to be in the developer's `~/Library`. The app and the dictionary service each call it once at
/// launch.
///
/// A process-wide holder rather than a parameter, because `Lemmatizer.lemma` is asked from the lookup, the
/// hover, the ledger projection and the service's own headword comparison, and a lemma that differed by call
/// site would key one word two ways. `lemma(…using:)` takes a table explicitly for the callers — the tests —
/// that must not read the shared one.
public final class FormAuthority: Sendable {
    public static let shared = FormAuthority()

    private struct State {
        var table: FormTable?
        var store: FormTableStore?
        var stamp: FormTableStore.Stamp?
        /// Moves whenever the source changes under a read in flight — `use` or `publish` — so that read's result is
        /// dropped rather than put over what replaced it.
        var generation = 0
        /// Moves whenever a different table is put in force — read or published — so a caller can tell that the table
        /// it decided something with is no longer the one in force without comparing 76,000 titles.
        var revision = 0
        /// The first read after `useInBackground` has not finished.
        var loading = false
        /// A background refresh is queued or running; another request joins it.
        var refreshing = false
    }

    private let state = Mutex(State())
    /// **One read at a time.** Two refreshes reading in parallel could finish in either order, and the older
    /// file's table would then be put over the newer's.
    private let reading = Mutex(())

    public init() {}

    /// The table in force, or nil where none has been read — which is not "an empty table", and means the
    /// tagger answers alone.
    public var table: FormTable? { state.withLock { $0.table } }

    /// Changes whenever the table in force does. A caller that decided something with the table it saw first
    /// compares this to know whether to decide again.
    public var revision: Int { state.withLock { $0.revision } }

    /// Reads from `store` now, and again whenever `refresh()` finds the file has moved.
    public func use(_ store: FormTableStore) {
        // A synchronous read supersedes any load in flight, so nothing is left to wait for.
        state.withLock { $0.store = store; $0.stamp = nil; $0.generation += 1; $0.loading = false }
        refresh()
    }

    /// `use`, for a caller that must not wait — the app at launch. The table is parsed on a utility queue, and
    /// `settled(within:)` is how a lookup waits for it, bounded, so the first lemma of a session is not decided
    /// before the table exists and then decided again differently after.
    public func useInBackground(_ store: FormTableStore) {
        let generation = state.withLock { current -> Int in
            current.store = store; current.stamp = nil; current.generation += 1; current.loading = true
            return current.generation
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            refresh()
            // Only the latest load clears the flag: an older one finishing must not release a wait on a newer.
            state.withLock { if $0.generation == generation { $0.loading = false } }
        }
    }

    /// How a wait for the first read ended.
    public enum Settled: Sendable, Equatable {
        /// Nothing was loading — every test, and any process that installed no source.
        case idle
        /// A load was in progress and finished.
        case finished
        /// The limit passed with the load still running: the caller goes on **without** the table and should say so.
        case timedOut
    }

    /// Returns once the read `useInBackground` started has finished, or after `limit`. **Immediately** where none is
    /// in progress.
    ///
    /// Waits for the work and not for a clock: a poll of a flag with a deadline, since a task started elsewhere
    /// cannot be awaited and the read cannot be cancelled.
    public func settled(within limit: Duration) async -> Settled {
        guard state.withLock({ $0.loading }) else { return .idle }
        let deadline = ContinuousClock.now + limit
        while state.withLock({ $0.loading }) {
            if ContinuousClock.now >= deadline { return .timedOut }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return .finished
    }

    /// Puts `table` in force without a file: what the service does the moment it has built one.
    public func publish(_ table: FormTable) {
        // A published table supersedes a load in flight: that load's completion no longer matches the generation
        // and would never clear the flag, so it is cleared here or every later wait would run to its limit.
        state.withLock { $0.table = table; $0.revision += 1; $0.generation += 1; $0.loading = false }
    }

    /// `refresh()` for a caller that must not wait: the `stat` is made here and the read, which parses 76,000 titles
    /// and is not instant, runs on a utility queue. A lookup that finds the file newer uses the table already in
    /// force and the next one uses the new.
    ///
    /// **Requests coalesce**: while one is queued or running another joins it, and it looks once more before it
    /// stops, so a file that moved meanwhile is still found without a read per lookup. Bounded at three passes: a
    /// file that cannot be read is retried by the next lookup, not spun on.
    public func refreshInBackground() {
        let start = state.withLock { current -> Bool in
            guard let store = current.store, !current.refreshing, store.stamp() != current.stamp else { return false }
            current.refreshing = true
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            for _ in 0 ..< 3 {
                refresh()
                let moved = state.withLock { current in current.store.map { $0.stamp() != current.stamp } ?? false }
                if !moved { break }
            }
            state.withLock { $0.refreshing = false }
        }
    }

    /// Re-reads where the file changed since it was last read. **A `stat` when nothing moved**, so a caller
    /// may ask before every lookup; the service writes the file once per dictionary change, and this is how
    /// the app, in another process, comes to see it without being restarted.
    ///
    /// A file that has gone, or cannot be read, leaves the table already in force alone: losing a lemma
    /// source mid-session would move a word's ledger key for no reason the reader can see. **A file whose bytes are
    /// not a table is not read again until it changes** — the same bytes fail the same way — but **one that could
    /// not be read at all is tried again**, because permissions and I/O recover.
    public func refresh() { refresh(afterReading: {}) }

    /// `afterReading` runs between the read and the commit — a seam for the one interleaving a test cannot otherwise
    /// make: a `publish` that lands while a file is being read.
    func refresh(afterReading: () -> Void) {
        reading.withLock { _ in
            let snapshot = state.withLock { current in current.store.map { ($0, current.generation, current.stamp) } }
            guard let (store, generation, known) = snapshot else { return }
            let stamp = store.stamp()
            guard stamp != known else { return }
            let outcome = stamp == nil ? FormTableStore.Load.absent : store.load()
            afterReading()
            state.withLock { current in
                // Superseded while it was being read: `use` or `publish` has the say, not this.
                guard current.generation == generation else { return }
                switch outcome {
                case .table(let read): current.table = read; current.stamp = stamp; current.revision += 1
                case .absent, .invalid: current.stamp = stamp
                case .unreadable: break
                }
            }
        }
    }
}
