import DictionaryModel
import Foundation
import Testing
@testable import XiaolaiDictCore

struct LookupDispositionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func lookup(_ ledger: Ledger, word: String = "fine") throws -> Int {
        try ledger.record(LookupRecord(surface: word, lemma: word, context: "A fine day.",
            language: "en", lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
    }
    @Test func discardReceiptIsDurableIdempotentAndUndoSkipsNewerChanges() throws {
        let ledger = try Ledger(path: ":memory:")
        let a = try lookup(ledger), b = try lookup(ledger)
        let operation = UUID()
        let receipt = try ledger.changeDisposition(.discarded, lookups: [a,b], operation: operation)
        #expect(receipt.affected == 2)
        #expect(try ledger.changeDisposition(.discarded, lookups: [a,b], operation: operation) == receipt)
        _ = try ledger.changeDisposition(.kept, lookups: [b], operation: UUID())
        let undo = try ledger.undoDisposition(operation: operation)
        #expect(undo.affected == 1)
        #expect(undo.skipped == 1)
        #expect(try ledger.readingArchive(ReadingArchiveQuery()).count == 2)
    }
    @Test func automaticOnlyTargetLeavesCollectionButExplicitOneStays() throws {
        let ledger = try Ledger(path: ":memory:")
        let a = try lookup(ledger)
        let target = StudyTarget.sense(dictionary: "noad", entryID: "e", senseKey: "s", senseKeyKind: .publisher)
        let note = try ledger.keep(target, issuer: .live, language: "en", chosenBy: .onlySense,
            answer: StudyAnswer(origin: .dictionary, text: "good"), lookupID: a, at: now, source: .automatic)
        #expect(try ledger.libraryCount(LibraryQuery()) == 1)
        _ = try ledger.changeDisposition(.discarded, lookups: [a], operation: UUID())
        #expect(try ledger.libraryCount(LibraryQuery()) == 0)
        #expect(try ledger.notes().first?.id == note?.id)
        try ledger.explicitlyKeep(noteID: #require(note?.id))
        #expect(try ledger.libraryCount(LibraryQuery()) == 1)
    }
    @Test func archiveReachesBeyondDrawerWithStableTimestampTies() throws {
        let ledger = try Ledger(path: ":memory:")
        for _ in 0..<451 { _ = try lookup(ledger) }
        var query = ReadingArchiveQuery(limit: 37)
        var ids: [Int] = []
        while true {
            let rows = try ledger.readingArchive(query)
            if rows.isEmpty { break }
            ids += rows.map(\.id)
            query.after = rows.last.map { ReadingArchiveCursor(at: $0.at, id: $0.id) }
        }
        #expect(ids.count == 451)
        #expect(Set(ids).count == 451)
    }
    @Test func supportingReadingsAndAllReviewKindsProtectProgress() throws {
        for kind in ["graded", "voided", "practice"] {
            let ledger = try Ledger(path:":memory:")
            let a = try lookup(ledger), b = try lookup(ledger)
            let target = StudyTarget.sense(dictionary:"noad",entryID:"e",senseKey:"s",senseKeyKind:.publisher)
            let answer = StudyAnswer(origin:.dictionary,text:"meaning")
            let note = try #require(try ledger.keep(target,issuer:.live,language:"en",chosenBy:.onlySense,
                answer:answer,lookupID:a,at:now,source:.automatic))
            _ = try ledger.keep(target,issuer:.live,language:"en",chosenBy:.onlySense,
                answer:answer,lookupID:b,at:now,source:.automatic)
            _ = try ledger.changeDisposition(.discarded,lookups:[a],operation:UUID())
            #expect(try ledger.libraryCount(LibraryQuery()) == 1, "second kept encounter still supports target")
            let card = try ledger.card(of:note.id,at:now)
            if kind == "practice" {
                _ = try ledger.grade(cardID:card.id,.good,eventID:UUID(),expectedRevision:card.revision,at:now,using:MemoryScheduler())
                _ = try ledger.practise(cardID:card.id,.good,eventID:UUID(),at:now)
            } else {
                _ = try ledger.grade(cardID:card.id,.good,eventID:UUID(),expectedRevision:card.revision,
                    at:now,using:MemoryScheduler())
                if kind == "voided" { _ = try ledger.undoLatestReview(ofCard:card.id,at:now.addingTimeInterval(1)) }
            }
            let before = try ledger.card(id:card.id)
            _ = try ledger.changeDisposition(.discarded,lookups:[b],operation:UUID())
            #expect(try ledger.libraryCount(LibraryQuery()) == 1, "any historical review kind preserves work")
            #expect(try ledger.card(id:card.id) == before)
            #expect(try ledger.answer(of:note.id) == answer)
        }
    }

    /// **What "Confirm this meaning" confirms is what was revealed.** The encounter a card draws is the
    /// newest one, which an auxiliary tap can be; the note it confirms is the one the reading is kept
    /// under. Both must come off one association, or the reader agrees to meaning B and confirms A.
    @Test func theKeptNotesOwnAnswerTravelsWithItsID() throws {
        let ledger = try Ledger(path: ":memory:")
        let a = try lookup(ledger)
        let target = StudyTarget.sense(dictionary: "noad", entryID: "e", senseKey: "s", senseKeyKind: .publisher)
        try ledger.record(SenseEncounter(dictionary: DictionaryIdentity(name: "NOAD", identifier: "noad"),
            entryID: "e", senseKey: "s", senseKeyKind: .publisher, sensePath: SensePath(block: 1, ordinal: 4),
            entrySenseCount: 12, senseHash: "s", gloss: "the primary meaning", chosenBy: .model, chosenAt: now), for: a)
        let note = try #require(try ledger.keep(target, issuer: .live, language: "en", chosenBy: .model,
            answer: StudyAnswer(origin: .dictionary, text: "the primary meaning"), lookupID: a, at: now,
            source: .automatic))
        try ledger.record(SenseEncounter(dictionary: DictionaryIdentity(name: "Other", identifier: "other"),
            entryID: "aux", senseKey: "x", senseKeyKind: .publisher, sensePath: nil, entrySenseCount: 2,
            senseHash: "x", gloss: "an auxiliary meaning", chosenBy: .reader, chosenAt: now), for: a)
        let row = try #require(try ledger.reading(ofLookup: a))
        #expect(row.sense?.gloss == "an auxiliary meaning", "positive control: the newest encounter is drawn")
        #expect(row.studyNoteID == note.id)
        #expect(row.studyAnswer == "the primary meaning",
                "the meaning a confirmation reveals must be the confirmed note's own")
        #expect(row.meaning == "the primary meaning", "what a reveal shows is what confirming reaches")
        // The labels beside Confirm describe the same note: its dictionary and its sense, not the
        // auxiliary encounter recorded after it.
        let shown = row.shown
        #expect(shown.sense?.dictionary == "NOAD")
        #expect(shown.sense?.label == "4/12")
        #expect(shown.sense?.gloss == "the primary meaning")
        #expect(shown.meaning == row.meaning)
        let unkept = try lookup(ledger)
        try ledger.record(SenseEncounter(dictionary: DictionaryIdentity(name: "Other", identifier: "other"),
            entryID: "aux", senseKey: "x", senseKeyKind: .publisher, sensePath: nil, entrySenseCount: 2,
            senseHash: "x", gloss: "an auxiliary meaning", chosenBy: .reader, chosenAt: now), for: unkept)
        let unkeptRow = try #require(try ledger.reading(ofLookup: unkept))
        #expect(unkeptRow.meaning == "an auxiliary meaning")
        #expect(unkeptRow.shown == unkeptRow, "a reading that is not kept describes its encounter")
    }

    /// **One rule for readiness.** The reading projection gathers facts and asks `StudyReadiness.of`,
    /// so what History says about a kept reading is what the library and the queue say about its note.
    @Test func aKeptReadingsStatusIsTheNotesReadiness() throws {
        let ledger = try Ledger(path: ":memory:")
        let cases: [(StudyTarget, SenseChoice?, StudyAnswer?)] = [
            // An entry rung the reader answered in their own words: ready, not in repair.
            (.entry(dictionary: "noad", entryID: "e1"), nil, StudyAnswer(origin: .reader, text: "my words")),
            // An entry rung carrying the publisher's whole entry: waits to be narrowed.
            (.entry(dictionary: "noad", entryID: "e2"), nil, StudyAnswer(origin: .dictionary, text: "entry")),
            // A proposal with nothing to reveal: repair, not confirmation.
            (.sense(dictionary: "noad", entryID: "e3", senseKey: "s", senseKeyKind: .publisher), .model, nil),
            (.sense(dictionary: "noad", entryID: "e4", senseKey: "s", senseKeyKind: .publisher), .model,
             StudyAnswer(origin: .dictionary, text: "proposed")),
            (.sense(dictionary: "noad", entryID: "e5", senseKey: "s", senseKeyKind: .publisher), .reader,
             StudyAnswer(origin: .dictionary, text: "tapped")),
        ]
        for (target, chosenBy, answer) in cases {
            let id = try lookup(ledger)
            let note = try ledger.enroll(target, issuer: .live, language: "en", chosenBy: chosenBy,
                                         answer: answer, lookupID: id, at: now)
            let row = try #require(try ledger.reading(ofLookup: id))
            #expect(row.studyStatus == (try ledger.readiness(of: note.id)), "\(target)")
        }
    }

    /// Finishing the class: correcting a keep removes only an untouched draft's association, and a
    /// manual keep of an existing note is marked explicit once, by `enroll`.
    @Test func manualKeepOfAnExistingDraftMakesItExplicit() throws {
        let ledger = try Ledger(path: ":memory:")
        let a = try lookup(ledger)
        let target = StudyTarget.sense(dictionary: "noad", entryID: "e", senseKey: "s", senseKeyKind: .publisher)
        let answer = StudyAnswer(origin: .dictionary, text: "meaning")
        let note = try #require(try ledger.keep(target, issuer: .live, language: "en", chosenBy: .onlySense,
            answer: answer, lookupID: a, at: now, source: .automatic))
        _ = try ledger.keep(target, issuer: .live, language: "en", chosenBy: .onlySense,
            answer: answer, lookupID: a, at: now, source: .manual)
        _ = try ledger.changeDisposition(.discarded, lookups: [a], operation: UUID())
        #expect(try ledger.libraryCount(LibraryQuery()) == 1, "a manual keep survives discarding its reading")
        #expect(try ledger.notes().map(\.id) == [note.id])
    }

}
