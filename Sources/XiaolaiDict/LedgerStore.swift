import DictionaryModel
import Foundation
import XiaolaiDictCore

/// The ledger on disk, owned by one actor so lookups can be recorded from anywhere.
actor LedgerStore {
    private let ledger: Ledger

    /// A ledger at `path`, created if absent. Opening is file and database work — creation, and a
    /// schema migration on the first launch after an update — so call it off the main actor.
    init(path: String) throws {
        ledger = try Ledger(path: path)
    }

    /// The support directory the ledger lives in, and the file inside it. **Changing either
    /// orphans every reader's history**: the app would open an empty ledger beside the full one,
    /// and an empty ledger is indistinguishable from a working one. `LedgerStoreTests` pins both
    /// as literals so a rename cannot move them quietly.
    static let directoryName = "XiaolaiDict"
    static let fileName = "ledger.sqlite"

    /// `~/Library/Application Support/XiaolaiDict/ledger.sqlite`, created on first use, opened on a
    /// background task whoever calls it. `applicationSupport` is a parameter so it can be opened
    /// against a temporary directory instead of the reader's own.
    static func openDefault(applicationSupport: URL? = nil) async throws -> LedgerStore {
        try await Task.detached(priority: .utility) {
            let root = try applicationSupport ?? FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = root.appendingPathComponent(directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try LedgerStore(path: directory.appendingPathComponent(fileName).path)
        }.value
    }

    /// What the reader met of this lemma before `before`. Encounters, never meanings.
    ///
    /// **In this language.** English *gift* and German *Gift* share a lemma and are two words; asked
    /// without one, a reader of both is shown the other word's history as this one's.
    func priorEncounters(of lemma: String, before: Date, language: String?) throws -> PriorEncounters {
        try ledger.priorEncounters(of: lemma, before: before, language: language)
    }

    /// The lookup, and the sense it met where that is a fact — in one call, so a sense can never
    /// end up in the ledger without the lookup it belongs to.
    @discardableResult
    func record(_ recording: LookupRecording) throws -> Int {
        // One transaction, so a sense that cannot be written takes its lookup with it rather than
        // leaving a row the caller has been told does not exist.
        try ledger.record(recording.record, with: recording.encounter)
    }

    /// A sense the reader picked, hung off a lookup already recorded. Kept apart from the model's
    /// guesses by `chosenBy`, which is the whole point of that column.
    func record(_ encounter: SenseEncounter, for lookup: Int) throws {
        try ledger.record(encounter, for: lookup)
    }

    /// What the history drawer shows. Bounded in both directions — a window of days and a cap on
    /// rows — because the drawer is a surface the reader opens often, and a ledger years deep must
    /// never arrive whole on the main actor.
    ///
    /// `studying` is passed through rather than defaulted here, for the reason the ledger makes it
    /// required: a surface that forgot the reader's setting would go on drawing the words they
    /// filtered out, and read as a setting that does nothing.
    func recentLookups(since: Date, limit: Int, studying: Set<ProbeScript>) throws -> [ReadingEntry] {
        try ledger.recentLookups(since: since, limit: limit, studying: studying)
    }

    /// A lookup the reader did not mean to make. The senses met in it go with it.
    func delete(lookup id: Int) throws {
        try ledger.delete(lookup: id)
    }
}
