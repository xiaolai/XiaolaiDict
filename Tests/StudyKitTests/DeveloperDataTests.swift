import DictionaryModel
import Foundation
import Testing
import XiaolaiDictTestSupport

@testable import StudyKit

/// The developer pane's two data operations, on a scratch ledger. Nothing here may touch the reader's own.
struct DeveloperDataTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func counts(_ ledger: Ledger) throws -> [String: Int] {
        var found: [String: Int] = [:]
        for table in try ledger.userTables() {
            try ledger.run("SELECT COUNT(*) FROM \(table)", bind: []) { found[table] = $0.integer(0) }
        }
        return found
    }

    /// **A table nobody classified is a table the clear would delete or keep by accident.** Fails the day the
    /// schema grows, which is the moment someone has to say which kind the new one is.
    @Test func everyTableIsClassifiedAsUserDataOrBookkeeping() throws {
        let ledger = try Ledger(path: ScratchFile.path("developer-tables"))
        let known: Set<String> = [
            "lookup_disposition_operations", "lookup_disposition_receipts", "lookups", "removed_keep_targets",
            "review_events", "sense_encounters", "study_answers", "study_cards", "study_ignored_lemmas",
            "study_keep_metadata", "study_locators", "study_note_lookups", "study_notes", "study_tags",
        ]
        #expect(Set(try ledger.userTables()) == known)
        #expect(Set(try ledger.allTables()).subtracting(known) == Ledger.bookkeepingTables)
    }

    @Test func deployingFillsAnEmptyLedgerWithEveryKindOfRow() throws {
        let path = ScratchFile.path("developer-deploy")
        let ledger = try Ledger(path: path)
        let report = try ledger.deployTestData(now: now)
        let rows = try counts(ledger)
        #expect(report.lookups >= 20 && report.notes >= 8 && report.reviewed >= 3)
        #expect(rows["lookups"] == report.lookups)
        #expect(rows["study_notes"] == report.notes)
        #expect((rows["review_events"] ?? 0) == report.reviewed, "a review must have been graded, not faked into a row")
        let problems = try ledger.integrity()
        #expect(problems.isEmpty, "the seeded ledger is not whole: \(problems)")
        // The kinds a reader's surfaces differ on: a phrase, an unconfirmed proposal, a paused note.
        var kinds = Set<String>()
        try ledger.run("SELECT DISTINCT target_kind FROM study_notes", bind: []) { kinds.insert(try! $0.text(0)) }
        #expect(kinds.isSuperset(of: ["sense", "phrase"]))
    }

    /// **Never mixed with a reader's own data.** A second deploy, or a deploy into a ledger with anything
    /// in it, is refused and changes nothing.
    @Test func deployingRefusesALedgerThatHoldsAnything() throws {
        let path = ScratchFile.path("developer-deploy-refused")
        let ledger = try Ledger(path: path)
        _ = try ledger.deployTestData(now: now)
        let before = try counts(ledger)
        #expect(throws: DeveloperDataError.ledgerNotEmpty) { try ledger.deployTestData(now: now) }
        #expect(try counts(ledger) == before)
    }

    @Test func clearingEmptiesEveryUserTableAndLeavesALedgerThatStillWorks() throws {
        let path = ScratchFile.path("developer-clear")
        let ledger = try Ledger(path: path)
        _ = try ledger.deployTestData(now: now)
        let removed = try ledger.clearEveryRow()
        #expect(removed > 0)
        let left = try counts(ledger)
        #expect(left.values.allSatisfy { $0 == 0 }, "\(left)")
        // Schema, version and foreign keys survive: a ledger that opened and then refused writes is worse.
        var keys = 0
        try ledger.run("PRAGMA foreign_keys", bind: []) { keys = $0.integer(0) }
        #expect(keys == 1)
        #expect(try ledger.integrity().isEmpty)
        _ = try ledger.deployTestData(now: now)   // clear → deploy is the whole point
        #expect((try counts(ledger)["lookups"] ?? 0) > 0)
    }

    @Test func clearingAnEmptyLedgerRemovesNothingAndSaysSo() throws {
        let path = ScratchFile.path("developer-clear-empty")
        #expect(try Ledger(path: path).clearEveryRow() == 0)
    }
}
