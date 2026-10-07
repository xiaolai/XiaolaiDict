import DictionaryModel
import Foundation
import os
@testable import StudyKit
import Testing
import XiaolaiDictTestSupport
import XiaolaiDictUI
@testable import XiaolaiDict

@MainActor
struct LookupKeepRaceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func row(_ encounter: SenseEncounter? = nil, policy: LookupKeepPolicy = .automatic) -> LookupRecording {
        LookupRecording(record: LookupRecord(surface:"fine",lemma:"fine",context:"A fine day.",language:"en",
            lookedUpAt:now,result:.found,answeredBy:.dictionaryService,quality:nil),
            encounter:encounter, keepPolicy:policy, primaryDictionary:"noad")
    }
    func sense(_ key: String, by: SenseChoice = .reader, dictionary: String = "noad") -> SenseEncounter {
        SenseEncounter(dictionary:DictionaryIdentity(name:dictionary,identifier:dictionary),entryID:"e",senseKey:key,
            senseKeyKind:.publisher,sensePath:nil,entrySenseCount:2,senseHash:"h",gloss:"meaning",chosenBy:by,chosenAt:now)
    }
    func settled(_ recorder: LookupRecorder, request: Int, row: LookupRecording) async {
        await recorder.record(row,request:request)
    }
    @Test func discardBeforePersistenceOutranksLateModelAndUndoRestoresExactReading() async throws {
        let directory = TemporaryDirectory();let path = directory.appending("ledger.sqlite").path
        let recorder = LookupRecorder(); recorder.start { try LedgerStore(path:path) }
        recorder.begin(row(),request:1); recorder.discard(request:1); recorder.discard(request:1)
        await settled(recorder,request:1,row:row(sense("model",by:.model)))
        let ledger = try Ledger(path:path)
        #expect(try ledger.readingArchive(ReadingArchiveQuery()).isEmpty)
        #expect(try ledger.notes().isEmpty)
        #expect(recorder.states[1] == .discarded)
        recorder.undoDiscard(request:1)
        await settled(recorder,request:1,row:row(sense("model",by:.model)))
        #expect(try ledger.readingArchive(ReadingArchiveQuery()).count == 1)
        #expect(try ledger.notes().count == 1)
        #expect(try ledger.notes().first?.confirmedAt == nil)
    }
    @Test func deferredReaderChoiceWinsAndAutomaticTapIsNotExplicitKeep() async throws {
        let directory = TemporaryDirectory();let path = directory.appending("ledger.sqlite").path
        let recorder = LookupRecorder(); recorder.start { try LedgerStore(path:path) }
        recorder.begin(row(),request:1)
        recorder.study(sense("reader"),request:1)
        await settled(recorder,request:1,row:row(sense("model",by:.model)))
        let ledger = try Ledger(path:path)
        #expect(try ledger.notes().count == 1)
        let note = try #require(ledger.notes().first)
        #expect(note.target == .sense(dictionary:"noad",entryID:"e",senseKey:"reader",senseKeyKind:.publisher))
        var explicit = -1
        try ledger.run("SELECT explicit_keep FROM study_keep_metadata WHERE note_id = ?",bind:[.text(note.id.uuidString)]) { explicit = $0.integer(0) }
        #expect(explicit == 0)
        _ = try ledger.changeDisposition(.discarded,lookups:[1],operation:UUID())
        #expect(try ledger.libraryCount(LibraryQuery()) == 0)
    }
    @Test func manualLookupsDoNotPrepareTargetsAndAuxiliaryTapDoesNotAutoEnroll() async throws {
        let directory = TemporaryDirectory();let path = directory.appending("ledger.sqlite").path
        let recorder = LookupRecorder(); recorder.start { try LedgerStore(path:path) }
        await settled(recorder,request:1,row:row(sense("s",by:.onlySense),policy:.manual))
        #expect(recorder.states[1] == .manual)
        await settled(recorder,request:2,row:row())
        recorder.study(sense("aux",dictionary:"other"),request:2)
        await settled(recorder,request:2,row:row(sense("primary",by:.model)))
        let ledger = try Ledger(path:path)
        #expect(try ledger.notes().count == 1)
        #expect(try ledger.notes().first?.target.dictionary == "noad")
    }
    /// **A reading deleted under an open card is said, and its id forgotten** (audit-fix round 1). The
    /// refresh read no row, changed nothing, and the card went on saying what it had said of a reading
    /// that is gone — while keeping its row id. Lookup ids are SQLite rowids and are reused once the
    /// largest is deleted, so a later choice on that card was written onto someone else's reading.
    @Test func aDeletedReadingSaysSoAndItsIdIsNeverWrittenTo() async throws {
        let directory = TemporaryDirectory(); let path = directory.appending("ledger.sqlite").path
        let recorder = LookupRecorder(); recorder.start { try LedgerStore(path:path) }
        await settled(recorder, request:1, row:row(policy:.manual))
        #expect(recorder.states[1] == .manual)
        let ledger = try Ledger(path:path)
        let gone = try #require(try ledger.readingArchive(ReadingArchiveQuery()).first?.id)
        try ledger.delete(lookup: gone)
        await recorder.refreshStatus(request:1)
        #expect(recorder.states[1] == .deleted, "the card still describes a reading that was deleted")
        let reused = try ledger.record(LookupRecord(surface:"other",lemma:"other",context:"Another day.",language:"en",
            lookedUpAt:now,result:.found,answeredBy:.dictionaryService,quality:nil))
        try #require(reused == gone, "the id was not reused, so this cannot show the hazard")
        recorder.enrol(sense("reader"), request:1, language:"en")
        await recorder.settled(request:1)
        #expect(try ledger.notes().isEmpty, "a choice on the deleted reading's card was saved onto another reading")
        #expect(try ledger.preferredEvidence(ofLookup: reused) == nil, "and recorded as met there")
    }
    /// **The rowid given to another reading before the card noticed is not this card's reading**
    /// (audit-fix round 2). Round 1 forgot a deleted reading's id once a refresh found no row; reused
    /// first — another lookup recorded between the deletion and the refresh — the refresh found a row,
    /// drew the other reading's status on this card, and a choice made on it was written there. The
    /// card's reading is its row *and* the instant stored with it, checked where each read and write
    /// lands.
    @Test func aRowIdReusedBeforeTheRefreshIsNotTheCardsReading() async throws {
        let directory = TemporaryDirectory(); let path = directory.appending("ledger.sqlite").path
        let recorder = LookupRecorder(); recorder.start { try LedgerStore(path:path) }
        await settled(recorder, request:1, row:row(policy:.manual))
        #expect(recorder.states[1] == .manual)
        let ledger = try Ledger(path:path)
        let gone = try #require(try ledger.readingArchive(ReadingArchiveQuery()).first?.id)
        try ledger.delete(lookup: gone)
        // Another reading, a minute later, takes the id before this card is told anything.
        let reused = try ledger.record(LookupRecord(surface:"other",lemma:"other",context:"Another day.",language:"en",
            lookedUpAt:now.addingTimeInterval(60),result:.found,answeredBy:.dictionaryService,quality:nil))
        try #require(reused == gone, "the id was not reused, so this cannot show the hazard")
        let note = try ledger.enroll(.entry(dictionary: "noad", entryID: "other"), issuer: .live, language: "en",
                                     chosenBy: .reader, answer: StudyAnswer(origin: .reader, text: "else"),
                                     lookupID: reused, at: now)
        try ledger.confirm(noteID: note.id, at: now)

        await recorder.refreshStatus(request:1)
        #expect(recorder.states[1] == .deleted, "the card drew another reading's status as its own")
        recorder.enrol(sense("reader"), request:1, language:"en")
        await recorder.settled(request:1)
        #expect(try ledger.notes().map(\.id) == [note.id], "a choice on the deleted reading's card was saved onto another reading")
        #expect(try ledger.encounters(ofLookup: reused).isEmpty, "and recorded as met there")
    }

    /// **And a write already on its way is refused where it lands**, not only by the refresh: the
    /// card's tap was queued before anything said the reading was gone, and the reading at that id by
    /// then was someone else's.
    @Test func aWriteForADeletedReadingIsRefusedWhereItLands() async throws {
        let directory = TemporaryDirectory(); let path = directory.appending("ledger.sqlite").path
        let recorder = LookupRecorder(); recorder.start { try LedgerStore(path:path) }
        await settled(recorder, request:1, row:row(policy:.manual))
        let ledger = try Ledger(path:path)
        let gone = try #require(try ledger.readingArchive(ReadingArchiveQuery()).first?.id)
        try ledger.delete(lookup: gone)
        let reused = try ledger.record(LookupRecord(surface:"other",lemma:"other",context:"Another day.",language:"en",
            lookedUpAt:now.addingTimeInterval(60),result:.found,answeredBy:.dictionaryService,quality:nil))
        try #require(reused == gone, "the id was not reused, so this cannot show the hazard")

        recorder.enrol(sense("reader"), request:1, language:"en")
        await recorder.settled(request:1)
        #expect(try ledger.notes().isEmpty, "the queued choice was saved onto another reading")
        #expect(try ledger.encounters(ofLookup: reused).isEmpty, "and recorded as met there")
        #expect(recorder.states[1] == .deleted, "the card did not learn its reading had gone")
    }

    @Test func failedWriteHasRetryAndNoSuccessStatus() async {
        let recorder = LookupRecorder(); recorder.start { throw LedgerError.blankLemma }
        await settled(recorder,request:1,row:row())
        #expect(recorder.states[1] == .failed)
        #expect(recorder.problem != nil)
        recorder.retry(request:1)
        await settled(recorder,request:1,row:row())
        #expect(recorder.states[1] == .failed)
    }
    @Test func failedReaderEnrollmentRetriesItsIntentAndExternalDiscardRestores() async throws {
        let directory = TemporaryDirectory(); let path = directory.appending("ledger.sqlite").path
        let recorder = LookupRecorder(); recorder.start { try LedgerStore(path:path) }
        await settled(recorder, request:1, row:row(policy:.manual))
        let ledger = try Ledger(path:path)
        try ledger.run("CREATE TRIGGER fail_keep BEFORE INSERT ON study_notes BEGIN SELECT RAISE(ABORT, 'injected'); END", bind:[]) { _ in }
        recorder.enrol(sense("reader"), request:1, language:"en")
        for _ in 0..<100 where recorder.states[1] != .failed { await Task.yield() }
        #expect(recorder.states[1] == .failed)
        await recorder.refreshStatus(request:1)
        #expect(recorder.states[1] == .failed)
        try ledger.run("DROP TRIGGER fail_keep", bind:[]) { _ in }
        recorder.retry(request:1)
        for _ in 0..<1000 where recorder.states[1] == .keeping { await Task.yield() }
        #expect(recorder.states[1] == .kept)
        #expect(try ledger.notes().count == 1)
        _ = try ledger.changeDisposition(.discarded, lookups:[1], operation:UUID())
        await recorder.refreshStatus(request:1)
        #expect(recorder.states[1] == .discardedExternally)
        recorder.undoDiscard(request:1)
        for _ in 0..<1000 where recorder.states[1] == .discardedExternally { await Task.yield() }
        #expect(try ledger.disposition(ofLookup:1) == .kept)
    }

    /// **A later enrichment does not stand in for a failed reader choice.** The choice already bars
    /// the recording's own encounter from replaying, so clearing its retry intent on the
    /// enrichment's success left Retry replaying a row that could never carry it.
    @Test func failedReaderEnrolmentSurvivesALaterEnrichment() async throws {
        let directory = TemporaryDirectory(); let path = directory.appending("ledger.sqlite").path
        let recorder = LookupRecorder(); recorder.start { try LedgerStore(path:path) }
        await settled(recorder, request:1, row:row(policy:.manual))
        let ledger = try Ledger(path:path)
        try ledger.run("CREATE TRIGGER fail_keep BEFORE INSERT ON study_notes BEGIN SELECT RAISE(ABORT, 'injected'); END", bind:[]) { _ in }
        recorder.enrol(sense("reader"), request:1, language:"en")
        for _ in 0..<100 where recorder.states[1] != .failed { await Task.yield() }
        #expect(recorder.states[1] == .failed)
        try ledger.run("DROP TRIGGER fail_keep", bind:[]) { _ in }
        await settled(recorder, request:1, row:row(sense("model", by:.model), policy:.manual))
        recorder.retry(request:1)
        for _ in 0..<1000 where recorder.states[1] == .keeping { await Task.yield() }
        #expect(try ledger.notes().count == 1, "Retry lost the reader's enrolment")
        #expect(try ledger.notes().first?.target == .sense(dictionary:"noad",entryID:"e",senseKey:"reader",senseKeyKind:.publisher))
        #expect(recorder.states[1] == .kept)
    }

    /// **A later success does not hide an earlier failure of a different choice.** The auxiliary
    /// enrolment failed; the primary's automatic keep then succeeded and drew its own status over
    /// the failure, so Retry vanished with the auxiliary choice still unsaved.
    @Test func aFailedAuxiliaryEnrolmentKeepsRetryThroughAPrimaryKeep() async throws {
        let directory = TemporaryDirectory(); let path = directory.appending("ledger.sqlite").path
        let recorder = LookupRecorder(); recorder.start { try LedgerStore(path:path) }
        await settled(recorder, request:1, row:row())
        let ledger = try Ledger(path:path)
        try ledger.run("CREATE TRIGGER fail_keep BEFORE INSERT ON study_notes BEGIN SELECT RAISE(ABORT, 'injected'); END", bind:[]) { _ in }
        recorder.enrol(sense("aux", dictionary:"other"), request:1, language:"en")
        for _ in 0..<100 where recorder.states[1] != .failed { await Task.yield() }
        #expect(recorder.states[1] == .failed)
        try ledger.run("DROP TRIGGER fail_keep", bind:[]) { _ in }
        await settled(recorder, request:1, row:row(sense("primary", by:.onlySense)))
        #expect(try ledger.notes().map(\.target.dictionary) == ["noad"], "positive control: the primary was kept")
        #expect(recorder.states[1] == .failed, "the primary's success hid the auxiliary failure")
        recorder.retry(request:1)
        for _ in 0..<1000 where recorder.states[1] == .keeping || recorder.states[1] == .failed { await Task.yield() }
        #expect(Set(try ledger.notes().map(\.target.dictionary)) == ["noad", "other"], "Retry did not replay the auxiliary choice")
        #expect(recorder.states[1] != .failed)
    }

    /// **A discard outranks a failed enrolment's Retry.** Discard is the reader's later word on the
    /// reading (ADR-0044) and a discarded request writes no sense, so Retry there was dead and drew
    /// over the Undo the discard offers. Undoing the discard brings the failure, and its Retry, back.
    @Test func discardingAfterAFailedEnrolmentShowsTheDiscardNotADeadRetry() async throws {
        let directory = TemporaryDirectory(); let path = directory.appending("ledger.sqlite").path
        let recorder = LookupRecorder(); recorder.start { try LedgerStore(path:path) }
        await settled(recorder, request:1, row:row(policy:.manual))
        let ledger = try Ledger(path:path)
        try ledger.run("CREATE TRIGGER fail_keep BEFORE INSERT ON study_notes BEGIN SELECT RAISE(ABORT, 'injected'); END", bind:[]) { _ in }
        recorder.enrol(sense("reader"), request:1, language:"en")
        for _ in 0..<100 where recorder.states[1] != .failed { await Task.yield() }
        #expect(recorder.states[1] == .failed, "positive control: the enrolment failed")
        try ledger.run("DROP TRIGGER fail_keep", bind:[]) { _ in }
        recorder.discard(request:1)
        for _ in 0..<1000 where recorder.states[1] == .keeping { await Task.yield() }
        #expect(recorder.states[1] == .discarded, "the failed enrolment hid the discard and its Undo")
        #expect(try ledger.disposition(ofLookup:1) == .discarded)
        recorder.undoDiscard(request:1)
        for _ in 0..<1000 where recorder.states[1] == .discarded || recorder.states[1] == .keeping { await Task.yield() }
        #expect(recorder.states[1] == .failed, "undoing the discard lost the unsaved choice")
        recorder.retry(request:1)
        for _ in 0..<1000 where recorder.states[1] == .keeping || recorder.states[1] == .failed { await Task.yield() }
        #expect(try ledger.notes().count == 1, "Retry after the undo did not save the choice")
    }

    /// **Reopening a reading does not downgrade it while the dictionaries are asked.** The pending
    /// row exists so a new lookup has an id at once; an existing one already has its answer, and a
    /// reopening superseded before the reply would otherwise leave it pending for good.
    @Test func reopeningKeepsTheCompletedResultUntilANewAnswer() async throws {
        let directory = TemporaryDirectory(); let path = directory.appending("ledger.sqlite").path
        let recorder = LookupRecorder(); recorder.start { try LedgerStore(path:path) }
        await settled(recorder, request:1, row:row(policy:.manual))
        let ledger = try Ledger(path:path)
        #expect(try ledger.reading(ofLookup:1)?.result == .found, "positive control: the first answer landed")
        let original = row(policy:.manual)
        // As `reopenReading` hands it over: the reading's own identity, read from its row.
        let identity = try #require(try ledger.reading(ofLookup:1)?.identity)
        let reopened = LookupRecording(record:original.record.pending(), encounter:nil, lookup:identity, keepPolicy:.manual)
        await settled(recorder, request:2, row:reopened)
        #expect(try ledger.reading(ofLookup:1)?.result == .found, "a pending reopening overwrote the answer")
        #expect(try ledger.readingArchive(ReadingArchiveQuery()).count == 1)
    }

    /// **A ledger that failed to open is asked again**, not awaited again. Retry reused the failed
    /// opening, so a transient failure — a locked file, a full disk since cleared — never recovered.
    @Test func retryAfterAFailedOpeningOpensAgain() async throws {
        let directory = TemporaryDirectory(); let path = directory.appending("ledger.sqlite").path
        let attempts = OSAllocatedUnfairLock(initialState: 0)
        let recorder = LookupRecorder()
        recorder.start {
            let attempt = attempts.withLock { $0 += 1; return $0 }
            if attempt == 1 { throw LedgerError.blankLemma }
            return try LedgerStore(path:path)
        }
        await settled(recorder, request:1, row:row(policy:.manual))
        #expect(recorder.states[1] == .failed)
        recorder.retry(request:1)
        for _ in 0..<1000 where recorder.states[1] == .keeping { await Task.yield() }
        #expect(recorder.states[1] == .manual)
        #expect(try Ledger(path:path).readingArchive(ReadingArchiveQuery()).count == 1)
    }

}
