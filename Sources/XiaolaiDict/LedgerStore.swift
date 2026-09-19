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
    static func openDefault() async throws -> LedgerStore {
        try await Task.detached(priority: .utility) {
            let directory = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("XiaolaiDict", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try LedgerStore(path: directory.appendingPathComponent("ledger.sqlite").path)
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
}
