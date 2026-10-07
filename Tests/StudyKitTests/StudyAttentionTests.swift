import CaptureModel
import DictionaryModel
import Foundation
import ReviewKit
import Testing
@testable import StudyKit

/// **What stands between a saved meaning and being asked it** — review-module-plan §8.3, WI-4.
///
/// `StudyReadiness` is the verdict and stays the one decision (ADR-0033). It is too coarse to say what
/// the reader should *do*: `.needsConfirmation` holds a proposal Confirm fixes and an entry rung
/// carrying the dictionary's text that Confirm cannot (ADR-0030), and `.needsRepair` holds both "write
/// an answer" and "the reading is gone". `StudyObstacle` is the remedy, derived from the same facts,
/// and these hold the two together — and the SQL count to the rows.
struct StudyAttentionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Every combination of the seven facts.
    private static let everyFact: [StudyReadiness.Facts] = (0..<128).map { bits in
        StudyReadiness.Facts(
            isConfirmed: bits & 1 != 0, hasUsableAnswer: bits & 2 != 0, answerIsPublishers: bits & 4 != 0,
            isEntryRung: bits & 8 != 0, hasReading: bits & 16 != 0, senseMoved: bits & 32 != 0,
            needsReading: bits & 64 != 0)
    }

    private static func confirmed(_ facts: StudyReadiness.Facts) -> StudyReadiness.Facts {
        StudyReadiness.Facts(
            isConfirmed: true, hasUsableAnswer: facts.hasUsableAnswer, answerIsPublishers: facts.answerIsPublishers,
            isEntryRung: facts.isEntryRung, hasReading: facts.hasReading, senseMoved: facts.senseMoved,
            needsReading: facts.needsReading)
    }

    @Test func theObstacleIsNoneExactlyWhenTheNoteIsReady() {
        for facts in Self.everyFact {
            #expect((StudyReadiness.obstacle(facts) == nil) == (StudyReadiness.of(facts) == .ready), "\(facts)")
        }
    }

    /// **"To confirm" means confirming is the remedy**, which is narrower than the verdict
    /// `.needsConfirmation`: an entry rung with the dictionary's own text is held there by ADR-0030 and
    /// stays there however often it is confirmed.
    @Test func confirmationIsTheObstacleExactlyWhereConfirmingMakesANoteReady() {
        for facts in Self.everyFact {
            let helps = StudyReadiness.of(facts) != .ready && StudyReadiness.of(Self.confirmed(facts)) == .ready
            #expect((StudyReadiness.obstacle(facts) == .confirmation) == helps, "\(facts)")
            if StudyReadiness.obstacle(facts) == .confirmation {
                #expect(StudyReadiness.of(facts) == .needsConfirmation, "\(facts)")
            }
        }
        let entryWithThePublishersText = StudyReadiness.Facts(
            isConfirmed: true, hasUsableAnswer: true, answerIsPublishers: true, isEntryRung: true,
            hasReading: true, senseMoved: false)
        #expect(StudyReadiness.of(entryWithThePublishersText) == .needsConfirmation)
        #expect(StudyReadiness.obstacle(entryWithThePublishersText) == .answer)
    }

    // MARK: - The count, and the rows it counts

    private func lookup(_ ledger: Ledger, _ word: String) throws -> Int {
        try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence holding \(word).", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil, script: .latin))
    }

    @discardableResult
    private func sense(_ ledger: Ledger, _ word: String, by chosen: SenseChoice?, dictionary: String = "noad",
                       answer: String? = "a meaning") throws -> StudyNote {
        try ledger.enroll(
            .sense(dictionary: dictionary, entryID: "e-\(word)", senseKey: "e-\(word).1", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: chosen,
            answer: answer.map { StudyAnswer(origin: .dictionary, text: $0) }, lookupID: try lookup(ledger, word), at: now)
    }

    @discardableResult
    private func entry(_ ledger: Ledger, _ word: String, by chosen: SenseChoice?, answer: String?) throws -> StudyNote {
        try ledger.enroll(
            .entry(dictionary: "noad", entryID: "e-\(word)"), issuer: .live, language: "en", chosenBy: chosen,
            answer: answer.map { StudyAnswer(origin: .dictionary, text: $0) }, lookupID: try lookup(ledger, word), at: now)
    }

    /// **Two spellings, one partition.** Review's empty state counts in SQL; the library's rows carry
    /// each note's obstacle from Swift. They are kept honest the way `thequeueAndReadinessAgree` keeps
    /// the queue honest, and the reasons add up to the one count they replace.
    @Test func theAttentionCountsAgreeWithEachRowsObstacle() throws {
        let ledger = try Ledger(path: ":memory:")
        try sense(ledger, "ready", by: .reader)
        try sense(ledger, "proposed", by: .model)
        let paused = try sense(ledger, "paused", by: .model)
        try ledger.setPaused(true, ofNotes: [paused.id])
        try entry(ledger, "answerless", by: .model, answer: nil)
        try entry(ledger, "whole", by: nil, answer: "the whole entry")
        try entry(ledger, "unconfirmedWhole", by: .model, answer: "the whole entry")
        let blank = try sense(ledger, "blank", by: .model, answer: " \u{3000}\n")
        #expect(try ledger.answer(of: blank.id)?.isUsable == false, "the premise: a blank answer")
        let deleted = try sense(ledger, "deleted", by: .model)
        try ledger.deleteReading(lookups: try ledger.lookupIDs(evidencing: deleted.id))
        let archived = try sense(ledger, "archived", by: .model)
        try ledger.setEnrollment(.archived, of: archived.id)
        try sense(ledger, "elsewhere", by: .model, dictionary: "oald")

        let counts = try ledger.attentionCounts(dictionary: "noad")
        let rows = try ledger.library(LibraryQuery(dictionary: "noad", state: .needsAttention, limit: 100))
        let byObstacle = Dictionary(grouping: rows) { $0.obstacle }.mapValues(\.count)
        #expect(rows.allSatisfy { $0.obstacle != nil }, "a row needing attention with nothing in its way")
        #expect(byObstacle[.senseMoved] == nil, "the library cannot ask a dictionary, so it never claims this")
        #expect(counts == StudyAttention(toConfirm: byObstacle[.confirmation] ?? 0, toAnswer: byObstacle[.answer] ?? 0,
                                         readingDeleted: byObstacle[.readingDeleted] ?? 0))
        #expect(counts == StudyAttention(toConfirm: 2, toAnswer: 4, readingDeleted: 1))
        #expect(counts.total == (try ledger.collectedCount(dictionary: "noad", needingAttention: true)))
        #expect(try ledger.attentionCounts(dictionary: nil).total == counts.total + 1, "nil is every dictionary")
    }

    /// **A reading carries the same remedy**, so the History inspector offers Confirm only where it
    /// changes something.
    @Test func aReadingSaysWhatStandsBetweenItsNoteAndReview() throws {
        let ledger = try Ledger(path: ":memory:")
        let proposed = try sense(ledger, "proposed", by: .model)
        let whole = try entry(ledger, "whole", by: nil, answer: "the whole entry")
        let ready = try sense(ledger, "ready", by: .reader)
        func reading(_ note: StudyNote) throws -> ReadingEntry? {
            try ledger.reading(ofLookup: try #require(try ledger.lookupIDs(evidencing: note.id).first))
        }
        #expect(try reading(proposed)?.studyObstacle == .confirmation)
        #expect(try reading(whole)?.studyStatus == .needsConfirmation)
        #expect(try reading(whole)?.studyObstacle == .answer)
        #expect(try reading(ready)?.studyStatus == .ready)
        #expect(try reading(ready)?.studyObstacle == nil)
    }

    // MARK: - A confirmation that hides its card (the cooldown's write)

    /// **The revision moves, and an existing hide is never shortened.** Hiding changes whether a card
    /// may be asked, which is the revision's whole job (WI-10); a card the reader put off until later
    /// stays put off until then.
    @Test func aConfirmationThatHidesMovesTheRevisionAndNeverShortensAHide() throws {
        let ledger = try Ledger(path: ":memory:")
        let fresh = try sense(ledger, "fresh", by: .model)
        let putOff = try sense(ledger, "putOff", by: .model)
        let later = now.addingTimeInterval(2 * 86_400), until = now.addingTimeInterval(8 * 3_600)
        try ledger.postpone(cardID: try ledger.card(of: putOff.id, at: now).id, until: later)
        let before = try ledger.card(of: fresh.id, at: now).revision

        try ledger.confirm(noteID: fresh.id, at: now, hidingCardsUntil: until)
        try ledger.confirm(noteID: putOff.id, at: now, hidingCardsUntil: until)

        #expect(try ledger.card(of: fresh.id, at: now).hiddenUntil == until)
        #expect(try ledger.card(of: fresh.id, at: now).revision == before + 1)
        #expect(try ledger.card(of: putOff.id, at: now).hiddenUntil == later)
        #expect(try ledger.readiness(of: fresh.id) == .ready)
        #expect(try ledger.dueCards(at: now, limit: 10, dictionary: nil, newAllowance: .max,
                                    dayStart: .distantPast).isEmpty, "hidden means not asked")
        #expect(try ledger.dueCards(at: until, limit: 10, dictionary: nil, newAllowance: .max,
                                    dayStart: .distantPast).map(\.noteID) == [fresh.id])
    }

    /// **A confirmation that did not happen hides nothing.** Confirming a confirmed note is a no-op
    /// (the first confirmation stands), so it is not a confirmation that showed anything.
    @Test func confirmingANoteAlreadyConfirmedHidesNothing() throws {
        let ledger = try Ledger(path: ":memory:")
        let ready = try sense(ledger, "ready", by: .reader)
        let card = try ledger.card(of: ready.id, at: now)
        try ledger.confirm(noteID: ready.id, at: now.addingTimeInterval(60), hidingCardsUntil: now.addingTimeInterval(8 * 3_600))
        #expect(try ledger.card(of: ready.id, at: now) == card)
        #expect(try ledger.notes().first?.confirmedAt == ready.confirmedAt)
    }
}
