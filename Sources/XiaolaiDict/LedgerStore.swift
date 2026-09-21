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

    /// `~/Library/Application Support/XiaolaiDict/ledger.sqlite`, created on first use, opened on a
    /// background task whoever calls it.
    ///
    /// **Migrates before it creates.** The app kept this directory under its old name, so the
    /// first launch after the rename would otherwise create an empty ledger beside a full one and
    /// show the reader a history that had simply vanished. The order matters: creating the
    /// directory first would make the move refuse, every time, for the rest of the app's life.
    ///
    /// `applicationSupport` is a parameter so that order can be tested against a temporary
    /// directory instead of the reader's own.
    static func openDefault(applicationSupport: URL? = nil) async throws -> LedgerStore {
        try await Task.detached(priority: .utility) {
            let root = try applicationSupport ?? FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = root.appendingPathComponent(
                StateMigration.directoryName, isDirectory: true)
            try StateMigration.migrateLedgerDirectory(
                from: root.appendingPathComponent(StateMigration.legacyDirectoryName, isDirectory: true),
                to: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try LedgerStore(
                path: directory.appendingPathComponent(StateMigration.ledgerFileName).path)
        }.value
    }

    /// What the reader met of this lemma before `before`. Encounters, never meanings.
    func priorEncounters(of lemma: String, before: Date) throws -> PriorEncounters {
        try ledger.priorEncounters(of: lemma, before: before)
    }

    /// The lookup, and the sense it met where that is a fact — in one call, so a sense can never
    /// end up in the ledger without the lookup it belongs to.
    @discardableResult
    func record(_ recording: LookupRecording) throws -> Int {
        let lookup = try ledger.record(recording.record)
        if let encounter = recording.encounter { try ledger.record(encounter, for: lookup) }
        return lookup
    }

    /// A sense the reader picked, hung off a lookup already recorded. Kept apart from the model's
    /// guesses by `chosenBy`, which is the whole point of that column.
    func record(_ encounter: SenseEncounter, for lookup: Int) throws {
        try ledger.record(encounter, for: lookup)
    }

    /// What the history drawer shows. Bounded in both directions — a window of days and a cap on
    /// rows — because the drawer is a surface the reader opens often, and a ledger years deep must
    /// never arrive whole on the main actor.
    func recentLookups(since: Date, limit: Int) throws -> [ReadingEntry] {
        try ledger.recentLookups(since: since, limit: limit)
    }

    /// A lookup the reader did not mean to make. The senses met in it go with it.
    func delete(lookup id: Int) throws {
        try ledger.delete(lookup: id)
    }
}
