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

    func record(_ record: LookupRecord) throws {
        try ledger.record(record)
    }
}
