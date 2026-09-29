import Foundation
import SQLite3

/// **Recovery and erasure.** WI-006, the gate P0 closes on.
///
/// Two obligations that are easy to believe are met and hard to notice are not.
///
/// A migration writes a copy of the reader's ledger beside it — history, cards, answers and all.
/// That copy is the app's, not theirs, and a permanent erase that leaves it behind is an erase that
/// did not happen. It is not enough to delete the rows.
///
/// And a store can fail. When it does, the reader must still be able to look a word up: the
/// dictionary is the product, and study is something built on top of it. A study table that cannot be
/// written must not take the lookup path with it.
extension Ledger {
    /// The copies this app made, beside the ledger it made them from.
    ///
    /// **Only its own.** Matched on the exact suffix `backUpBeforeMigrating` writes, so a file the
    /// reader put there themselves is never a candidate for deletion by us.
    public static func appManagedBackups(besides path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".schema"
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".backup") }
            .sorted()
            .map { directory.appending(path: $0).path }
    }

    /// Every check that says a database is whole, run together.
    ///
    /// **The study invariants are in here too**, not only SQLite's own: a file can pass
    /// `integrity_check` and still hold two cards for one question or two live grades for one event,
    /// and those are the shapes that make a schedule wrong rather than unreadable.
    public func integrity() throws -> [String] {
        var problems: [String] = []
        try run("PRAGMA integrity_check", bind: []) { row in
            let answer = try row.text(0)
            if answer != "ok" { problems.append("integrity_check: \(answer)") }
        }
        try run("PRAGMA foreign_key_check", bind: []) { row in
            problems.append("foreign_key_check: \(row.optionalText(0) ?? "?")")
        }
        // One card per question. A second would give the reader two schedules for one thing to know.
        try run("""
            SELECT COUNT(*) FROM (
                SELECT note_id, prompt FROM study_cards GROUP BY note_id, prompt HAVING COUNT(*) > 1)
            """, bind: []) { row in
            if row.integer(0) > 0 { problems.append("duplicate cards: \(row.integer(0))") }
        }
        // A card with no note. The cascade makes this impossible; the check is what says the cascade
        // was on, which is the thing that has silently not been before.
        try run("""
            SELECT COUNT(*) FROM study_cards c
            LEFT JOIN study_notes n ON n.id = c.note_id WHERE n.id IS NULL
            """, bind: []) { row in
            if row.integer(0) > 0 { problems.append("orphaned cards: \(row.integer(0))") }
        }
        try run("""
            SELECT COUNT(*) FROM review_events e
            LEFT JOIN study_cards c ON c.id = e.card_id WHERE c.id IS NULL
            """, bind: []) { row in
            if row.integer(0) > 0 { problems.append("orphaned review events: \(row.integer(0))") }
        }
        return problems
    }

    /// What a permanent erase did, and what it could not.
    public struct ErasureReport: Sendable, Equatable {
        public let lookupsRemoved: Int
        public let backupsRemoved: [String]
        /// A copy the app made and could not delete, with the reason. **Reported, never swallowed**:
        /// a reader told their reading is gone while a copy of it sits beside the ledger has been
        /// told something false.
        public let backupsLeft: [String: String]

        public var isComplete: Bool { backupsLeft.isEmpty }
    }

    /// What a full erase would take. **Counted, not estimated** — the reader is about to make a
    /// decision they cannot reverse, and a number that turns out to be wrong afterwards is worse
    /// than no number.
    public func readingErasureImpact(at path: String) throws -> (lookups: Int, notesLeftWithoutACue: Int,
                                                                 backups: Int) {
        var lookups = 0
        try run("SELECT COUNT(*) FROM lookups", bind: []) { lookups = $0.integer(0) }
        // Every note evidenced by any lookup loses its cue, because every lookup is going.
        var orphaned = 0
        try run("""
            SELECT COUNT(*) FROM study_notes n
            WHERE EXISTS (SELECT 1 FROM study_note_lookups nl WHERE nl.note_id = n.id)
            """, bind: []) { orphaned = $0.integer(0) }
        return (lookups, orphaned, Self.appManagedBackups(besides: path).count)
    }

    /// Erases the reader's reading history, and the copies this app made of it.
    ///
    /// **The study notes stay.** This is the wide version of *delete reading data*: the reader wanted
    /// their history gone, not their cards, so every note survives and becomes `needsRepair` for want
    /// of a cue. Removing from study is the other command.
    ///
    /// **Copies the reader made themselves are outside this.** A Time Machine snapshot, a file they
    /// duplicated, an export they sent somewhere — none of it is ours to reach, and the reader-facing
    /// text says so rather than implying a completeness nothing can deliver.
    public func eraseReadingData(at path: String) throws -> ErasureReport {
        var count = 0
        try run("SELECT COUNT(*) FROM lookups", bind: []) { count = $0.integer(0) }
        try inOneTransaction("eraseReading") {
            try execute("DELETE FROM lookups")
        }
        // **After the rows, not before.** A backup removed first, on a delete that then fails, is a
        // reader with neither their history nor the copy they could have restored it from.
        var removed: [String] = []
        var left: [String: String] = [:]
        for backup in Self.appManagedBackups(besides: path) {
            do {
                try FileManager.default.removeItem(atPath: backup)
                removed.append(backup)
            } catch {
                left[backup] = error.localizedDescription
            }
        }
        // The write-ahead log still holds the deleted rows until it is folded in. A reader who was
        // told their history is gone should not have it recoverable from a sidecar file.
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return ErasureReport(lookupsRemoved: count, backupsRemoved: removed, backupsLeft: left)
    }
}
