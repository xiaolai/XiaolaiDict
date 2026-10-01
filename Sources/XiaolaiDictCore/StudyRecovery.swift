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
    /// **Only its own, and only the exact shape the migration writes**: `<ledger>.schema<digits>.backup`
    /// and nothing else.
    ///
    /// A prefix-and-suffix match is not that. It accepted `ledger.sqlite.schema7.my-own.backup` — a
    /// name a reader might plausibly choose for a copy — while the comment claimed an exact match,
    /// which is how a file that is not ours would have been deleted by a command promising to delete
    /// ours. The digits are checked, so anything between the version and `.backup` disqualifies it.
    public static func appManagedBackups(besides path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".schema"
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents
            .filter { name in
                guard name.hasPrefix(prefix), name.hasSuffix(".backup") else { return false }
                let middle = name.dropFirst(prefix.count).dropLast(".backup".count)
                return !middle.isEmpty && middle.allSatisfy(\.isNumber)
            }
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
    public func eraseReadingData(at path: String, lookups ids: [Int]? = nil) throws -> ErasureReport {
        var count = 0
        let scope = ids == nil ? "" : " WHERE id IN (SELECT value FROM json_each(?))"
        let values: [SQLiteValue] = ids.map { [.text(Self.jsonArray(of: $0.map(String.init)))] } ?? []
        try run("SELECT COUNT(*) FROM lookups" + scope, bind: values) { count = $0.integer(0) }
        // **`DELETE` frees the pages and leaves their bytes.** macOS's SQLite runs `secure_delete`
        // in FAST mode, which only scrubs pages it is already rewriting, so thousands of characters
        // of the reader's sentences stayed legible in the file after an erase that reported success.
        // Measured on this Mac before this line existed.
        try execute("PRAGMA secure_delete = ON")
        try inOneTransaction("eraseReading") {
            try run("DELETE FROM lookups" + scope, bind: values) { _ in }
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
        //
        // **Its answer is read.** `wal_checkpoint` reports a busy checkpoint in its first column —
        // another connection holding a read snapshot can prevent the truncation — and running it
        // through `execute`, whose `sqlite3_exec` callback is nil, threw that answer away. The
        // erase then reported itself complete over a log still holding the reader's history.
        var checkpointBusy = false
        try run("PRAGMA wal_checkpoint(TRUNCATE)", bind: []) { checkpointBusy = $0.integer(0) != 0 }
        if checkpointBusy {
            left[path + "-wal"] = String(
                localized: "The write-ahead log could not be truncated: another connection is reading it.",
                comment: "Reported when an erase cannot clear the database's sidecar log")
        }
        // Rewrites the database without the freed pages, so nothing of what was deleted survives in
        // the file. Outside the transaction, because `VACUUM` cannot run inside one.
        try execute("VACUUM")
        return ErasureReport(lookupsRemoved: count, backupsRemoved: removed, backupsLeft: left)
    }
}
