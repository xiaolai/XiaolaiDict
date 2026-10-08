import DictionaryModel
import Foundation
import ReviewKit
import Testing
import XiaolaiDictTestSupport
@testable import StudyKit

struct LegacyKeepBackfillTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func lookup(_ ledger: Ledger, _ i: Int) throws -> Int {
        try ledger.record(LookupRecord(surface: "fine", lemma: "fine", context: "A fine day \(i).",
            language: "en", lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
    }
    func evidence(_ i: Int, chosen: SenseChoice = .onlySense) -> SenseEncounter {
        SenseEncounter(dictionary: DictionaryIdentity(name: "NOAD", identifier: "noad", version: nil), entryID: "e\(i)",
            senseKey: "s", senseKeyKind: .publisher, sensePath: nil, entrySenseCount: 1,
            senseHash: "h", gloss: "a meaning", chosenBy: chosen, chosenAt: now)
    }
    @Test func boundedResumableImportStaysUnconfirmedAndRemovedTargetsStayRemoved() throws {
        let ledger = try Ledger(path: ":memory:")
        for i in 1...6 { let id = try lookup(ledger,i); try ledger.record(evidence(i), for: id) }
        try ledger.run("UPDATE keep_backfill SET upper_id = 6 WHERE version = 1",bind:[]) { _ in }
        #expect(try ledger.backfillKeptDrafts(limit: 2) == 2)
        #expect(try ledger.notes().count == 2)
        #expect(try ledger.notes().allSatisfy { $0.confirmedAt == nil })
        let removed = try #require(ledger.notes().first)
        try ledger.removeFromStudy([removed.id])
        try ledger.run("UPDATE keep_backfill SET cursor = 0 WHERE version = 1",bind:[]) { _ in }
        #expect(try ledger.backfillKeptDrafts(limit: 2) == 2)
        #expect(try ledger.note(for: removed.target, issuer: .live, language: "en") == nil)
        while try ledger.backfillKeptDrafts(limit: 2) > 0 {}
        #expect(try ledger.notes().count == 5)
        #expect(try ledger.queueCounts(at: now, dictionary: "noad",newAllowance:5,dayStart:now).due == 0)
        #expect(try ledger.backfillKeptDrafts(limit: 2) == 0)
    }
    @Test func migrationFromTwelvePreservesProgressAndReceiptSurvivesRelaunch() throws {
        let directory = TemporaryDirectory(); let path = directory.appending("ledger.sqlite").path
        var ledger: Ledger? = try Ledger(path: path)
        let live = try #require(ledger)
        let id = try lookup(live,1); let e = evidence(1)
        let target = StudyTarget.sense(dictionary: "noad",entryID:e.entryID,senseKey:"s",senseKeyKind:.publisher)
        let note = try live.enroll(target,issuer:.live,language:"en",chosenBy:.reader,
            answer:StudyAnswer(origin:.dictionary,text:"meaning"),lookupID:id,at:now)
        let card = try live.card(of:note.id,at:now)
        // Reconstruct the real pre-upgrade additive schema; no row identities are changed.
        try live.execute("""
            DROP TRIGGER remember_removed_target; DROP TRIGGER study_keep_new_note;
            DROP TABLE removed_keep_targets; DROP TABLE lookup_disposition_receipts;
            DROP TABLE lookup_disposition_operations; DROP TABLE study_keep_metadata; DROP TABLE keep_backfill;
            DROP INDEX lookups_archive; ALTER TABLE lookups DROP COLUMN disposition;
            ALTER TABLE lookups DROP COLUMN disposition_revision; ALTER TABLE lookups DROP COLUMN primary_dictionary;
            ALTER TABLE lookups DROP COLUMN keep_policy; PRAGMA user_version = 12;
            """)
        ledger = nil
        let migrated = try Ledger(path:path)
        #expect(try migrated.notes() == [note])
        #expect(try migrated.card(id:card.id) == card)
        #expect(FileManager.default.fileExists(atPath:path+".schema12.backup"))
        var fk = 0, violations = 0
        try migrated.run("PRAGMA foreign_keys",bind:[]) { fk = $0.integer(0) }
        try migrated.run("PRAGMA foreign_key_check",bind:[]) { _ in violations += 1 }
        #expect(fk == 1 && violations == 0)
        let op = UUID(); _ = try migrated.changeDisposition(.discarded,lookups:[id],operation:op)
        #expect(try migrated.libraryCount(LibraryQuery()) == 1, "legacy explicit progress remains collected")
        let restarted = try Ledger(path:path)
        #expect(try restarted.undoDisposition(operation:op).affected == 1)
    }
    @Test func earlyAuxiliaryTapDoesNotInventHistoricalPrimary() throws {
        let ledger = try Ledger(path:":memory:")
        let id = try lookup(ledger,1)
        let aux = SenseEncounter(dictionary:DictionaryIdentity(name:"Other",identifier:"other"),entryID:"aux",
            senseKey:"a",senseKeyKind:.publisher,sensePath:nil,entrySenseCount:2,senseHash:"a",gloss:"auxiliary",
            chosenBy:.reader,chosenAt:now)
        try ledger.record(aux, for:id)
        try ledger.record(evidence(1,chosen:.model), for:id)
        try ledger.run("UPDATE keep_backfill SET upper_id = ?",bind:[.integer(id)]) { _ in }
        #expect(try ledger.backfillKeptDrafts(limit:10) == 1)
        #expect(try ledger.notes().isEmpty)
        #expect(try ledger.preferredEvidence(ofLookup:id) == nil)
    }

    /// **A backfilled draft is as correctable as an automatic one.** Both are untouched proposals; a
    /// correction that left the legacy one linked kept two meanings collected for one reading.
    @Test func correctingABackfilledDraftMovesTheReadingsAssociation() throws {
        let ledger = try Ledger(path: ":memory:")
        let id = try lookup(ledger, 1)
        try ledger.record(evidence(1, chosen: .model), for: id)
        try ledger.run("UPDATE keep_backfill SET upper_id = ?", bind: [.integer(id)]) { _ in }
        #expect(try ledger.backfillKeptDrafts(limit: 10) == 1)
        let draft = try #require(try ledger.notes().first)
        let chosen = StudyTarget.sense(dictionary: "noad", entryID: "e1", senseKey: "t", senseKeyKind: .publisher)
        let kept = try #require(try ledger.keep(chosen, issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "the right meaning"), lookupID: id, at: now,
            source: .manual))
        #expect(try ledger.lookupIDs(evidencing: kept.id) == [id])
        #expect(try ledger.lookupIDs(evidencing: draft.id).isEmpty,
                "the corrected draft still claims the reading")
        #expect(try ledger.libraryCount(LibraryQuery()) == 1)
        #expect(try ledger.notes().count == 2, "the draft itself is kept, only its association moves")
    }

}
