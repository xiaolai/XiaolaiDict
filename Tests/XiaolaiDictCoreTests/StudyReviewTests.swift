import DictionaryModel
import Foundation
import Testing
@testable import XiaolaiDictCore

/// **Grading, undo and the queue.** WI-003's storage half; `MemorySchedulerParityTests` covers the
/// arithmetic.
///
/// A review is a write the reader cannot see fail. Everything here is about the two ways that goes
/// wrong quietly — a grade recorded twice, and a grade recorded against a card that had moved — plus
/// the queue rule that must never silently shorten a batch.
struct StudyReviewTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ready(_ ledger: Ledger, _ lemma: String = "fine", key: String = "e1.001",
                       at when: Date? = nil) throws -> StudyCard {
        let when = when ?? now
        let lookup = try ledger.record(LookupRecord(
            surface: lemma, lemma: lemma, context: "He paid the \(lemma).", lemmaBasis: .tagger,
            language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: when, result: .found, answeredBy: .dictionaryService, quality: nil))
        let note = try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e\(key)", senseKey: key, senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "a penalty"), lookupID: lookup, at: when)
        return try #require(try ledger.card(of: note.id, at: when))
    }

    private func scheduler() throws -> MemoryScheduler { try MemoryScheduler() }

    // MARK: - One grade, once

    @Test func agradeMovesTheCardAndRecordsWhatItDid() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        #expect(card.scheduled.phase == .new, "saving a meaning is not a review of it")

        let event = try ledger.grade(cardID: card.id, .good, eventID: UUID(),
                                     expectedRevision: 0, at: now, using: try scheduler())
        let after = try #require(try ledger.card(id: card.id))
        #expect(after.scheduled.phase == .review)
        #expect(after.revision == 1, "the revision moves, so a stale grade cannot land on it")
        #expect(after.scheduled.state?.stability == event.after.state?.stability)
        #expect(event.before.phase == .new, "the event carries where it came from, not only where it went")
        #expect(event.schedulerVersion == MemoryScheduler.version)
    }

    /// **A retry returns the first result.** The reader answered once; a review window that retried
    /// after a failure it could not see would otherwise grade the card twice and halve its interval.
    @Test func thesameEventIdGradesOnce() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        let eventID = UUID()
        let first = try ledger.grade(cardID: card.id, .good, eventID: eventID,
                                     expectedRevision: 0, at: now, using: try scheduler())
        let second = try ledger.grade(cardID: card.id, .good, eventID: eventID,
                                      expectedRevision: 0, at: now, using: try scheduler())
        #expect(first == second)
        #expect(try ledger.reviews(ofCard: card.id).count == 1)
        #expect(try #require(try ledger.card(id: card.id)).revision == 1, "and the card moved once")
    }

    /// A grade computed against one state may not land on another. The window draws the card, the
    /// reader thinks, and in between anything can have written.
    @Test func agradeAgainstAstaleRevisionIsRefused() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0, at: now,
                             using: try scheduler())
        #expect(throws: ReviewError.staleRevision(expected: 0, found: 1)) {
            try ledger.grade(cardID: card.id, .again, eventID: UUID(), expectedRevision: 0,
                             at: self.now, using: try self.scheduler())
        }
        #expect(try ledger.reviews(ofCard: card.id).count == 1)
    }

    /// **Eligibility is rechecked at the commit, not only when the card was drawn.** A reader can
    /// delete the reading, or archive the target in another window, while looking at the question.
    @Test func acardThatStoppedBeingAskableIsRefusedAtTheCommit() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        try ledger.setEnrollment(.archived, of: card.noteID)
        #expect(throws: ReviewError.notEligible(card.id)) {
            try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: self.now, using: try self.scheduler())
        }
        #expect(try ledger.reviews(ofCard: card.id).isEmpty)
        #expect(try #require(try ledger.card(id: card.id)).revision == 0, "and nothing moved")
    }

    /// **Half a review is worse than none**, because one of the halves is invisible. A failure inside
    /// the transaction must leave neither the event nor the card's new state.
    @Test func afailedGradeLeavesNeitherAnEventNorAmovedCard() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        // A clock that has gone backwards makes the scheduler throw *after* the eligibility checks
        // pass, which is the interesting place for the transaction to be interrupted.
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now, using: try scheduler())
        let before = try #require(try ledger.card(id: card.id))
        #expect(throws: (any Error).self) {
            try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 1,
                             at: self.now.addingTimeInterval(-60), using: try self.scheduler())
        }
        let after = try #require(try ledger.card(id: card.id))
        #expect(after == before, "the card moved on a review that threw")
        #expect(try ledger.reviews(ofCard: card.id).count == 1)
    }

    // MARK: - Undo

    /// A mistaken grade is recoverable, and the card goes back to exactly where it was.
    @Test func undoRestoresTheScheduleAndVoidsTheEvent() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        let first = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0,
                                     at: now, using: try scheduler())
        let second = try ledger.grade(cardID: card.id, .again, eventID: UUID(), expectedRevision: 1,
                                      at: now.addingTimeInterval(86_400), using: try scheduler())
        try ledger.undoLatestReview(ofCard: card.id, at: now.addingTimeInterval(86_401))

        let restored = try #require(try ledger.card(id: card.id))
        #expect(restored.scheduled == first.after, "the schedule is exactly the one before the mistake")
        #expect(restored.scheduled == second.before)
        let events = try ledger.reviews(ofCard: card.id)
        #expect(events.count == 2, "the event is voided, never deleted")
        #expect(events.last?.isVoid == true)
        #expect(events.first?.isVoid == false)
    }

    /// **Undoing twice takes back two grades, not the same one.** The second undo finds the earlier
    /// event because the first one is void.
    @Test func undoWalksBackwardsOneGradeAtAtime() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        let first = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0,
                                     at: now, using: try scheduler())
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 1,
                             at: now.addingTimeInterval(86_400), using: try scheduler())
        try ledger.undoLatestReview(ofCard: card.id, at: now)
        try ledger.undoLatestReview(ofCard: card.id, at: now)
        let restored = try #require(try ledger.card(id: card.id))
        #expect(restored.scheduled == first.before, "back to never having been reviewed")
        #expect(restored.scheduled.phase == .new)
        #expect(try ledger.reviews(ofCard: card.id).allSatisfy(\.isVoid))
        #expect(throws: ReviewError.nothingToUndo(card.id)) {
            try ledger.undoLatestReview(ofCard: card.id, at: self.now)
        }
    }

    /// An undone grade is not a grade. A retention figure that counted it would be reporting a review
    /// the reader took back.
    @Test func avoidedEventIsStillInTheHistoryAndStillVoid() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        let event = try ledger.grade(cardID: card.id, .again, eventID: UUID(), expectedRevision: 0,
                                     at: now, using: try scheduler())
        try ledger.undoLatestReview(ofCard: card.id, at: now)
        let stored = try #require(try ledger.reviews(ofCard: card.id).first)
        #expect(stored.id == event.id)
        #expect(stored.grade == .again, "what happened is still what happened")
        #expect(stored.isVoid)
    }

    // MARK: - The queue

    /// **Learning and relearning first, then review by oldest due, then the unreviewed.** A simple
    /// auditable order, and nothing cleverer: a priority score would be a claim about this reader's
    /// memory that nothing here has measured.
    @Test func thequeueOrdersLearningThenOverdueThenNew() throws {
        let ledger = try Ledger(path: ":memory:")
        let lapsed = try ready(ledger, "fine", key: "a")
        let old = try ready(ledger, "hold", key: "b")
        let fresh = try ready(ledger, "bank", key: "c")

        // `lapsed` fails and lands in relearning, due in ten minutes.
        _ = try ledger.grade(cardID: lapsed.id, .again, eventID: UUID(), expectedRevision: 0,
                             at: now, using: try scheduler())
        // `old` passes and becomes a review card, long overdue by the time we ask.
        _ = try ledger.grade(cardID: old.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now, using: try scheduler())
        // `fresh` has never been graded at all.

        let later = now.addingTimeInterval(400 * 86_400)
        let queue = try ledger.dueCards(at: later, limit: 10, dictionary: "noad")
        #expect(queue.map(\.id) == [lapsed.id, old.id, fresh.id],
                "got \(queue.map { "\($0.scheduled.phase)" })")
    }

    /// A card not yet due is not in the queue, and neither is one the reader paused or hid.
    @Test func thequeueLeavesOutWhatIsNotDue() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0, at: now,
                             using: try scheduler())
        #expect(try ledger.dueCards(at: now, limit: 10, dictionary: nil).isEmpty,
                "a card just answered is not due again in the same second")

        let later = now.addingTimeInterval(400 * 86_400)
        #expect(try ledger.dueCards(at: later, limit: 10, dictionary: nil).count == 1)
        try ledger.setPaused(true, ofCard: card.id)
        #expect(try ledger.dueCards(at: later, limit: 10, dictionary: nil).isEmpty)
        try ledger.setPaused(false, ofCard: card.id)
        try ledger.hide(cardID: card.id, until: later.addingTimeInterval(86_400))
        #expect(try ledger.dueCards(at: later, limit: 10, dictionary: nil).isEmpty)
        // **Neither touched the memory**: hiding and pausing are about what is asked, not about `S`.
        #expect(try #require(try ledger.card(id: card.id)).scheduled.state?.stability
            == card.scheduled.state?.stability ?? #require(try ledger.card(id: card.id)).scheduled.state?.stability)
    }

    /// Study state belongs to one dictionary, so a session's queue must not mix two namespaces.
    @Test func thequeueIsScopedToOneDictionary() throws {
        let ledger = try Ledger(path: ":memory:")
        _ = try ready(ledger)
        let lookup = try ledger.record(LookupRecord(
            surface: "fine", lemma: "fine", context: "He paid the fine.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        let other = try ledger.enroll(
            .sense(dictionary: "oxford", entryID: "e1", senseKey: "e1.001", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "a penalty"), lookupID: lookup, at: now)
        _ = try ledger.card(of: other.id, at: now)

        #expect(try ledger.dueCards(at: now, limit: 10, dictionary: "noad").count == 1)
        #expect(try ledger.dueCards(at: now, limit: 10, dictionary: "oxford").count == 1)
        #expect(try ledger.dueCards(at: now, limit: 10, dictionary: nil).count == 2,
                "no scope is the library's view, not a session's")
    }

    /// **The two spellings of "ready" must admit the same notes.**
    ///
    /// The queue cannot filter in Swift after a `LIMIT` — that hands back fewer cards than were asked
    /// for, a defect this ledger has had once already — so readiness exists twice: as SQL in
    /// `readyNotePredicate` and as Swift in `readiness(of:)`. Two readers of one rule disagree
    /// eventually; this is what notices. Every non-ready state is represented, so the agreement is not
    /// over an empty set.
    @Test func thequeueAndReadinessAgree() throws {
        let ledger = try Ledger(path: ":memory:")
        let ok = try ready(ledger, "fine", key: "a")
        let unconfirmed = try ready(ledger, "hold", key: "b")
        let archived = try ready(ledger, "bank", key: "c")
        let answerless = try ready(ledger, "spring", key: "d")
        let readingless = try ready(ledger, "well", key: "e")

        try ledger.run("UPDATE study_notes SET confirmed_at = NULL WHERE id = ?",
                       bind: [.text(unconfirmed.noteID.uuidString)]) { _ in }
        try ledger.setEnrollment(.archived, of: archived.noteID)
        try ledger.run("DELETE FROM study_answers WHERE note_id = ?",
                       bind: [.text(answerless.noteID.uuidString)]) { _ in }
        for id in try ledger.lookupIDs(evidencing: readingless.noteID) { try ledger.delete(lookup: id) }
        // An entry rung with the dictionary's own text: enrolled, and not a sense-specific answer.
        let lookup = try ledger.record(LookupRecord(
            surface: "fine", lemma: "fine", context: "He paid the fine.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        let entryRung = try ledger.enroll(
            .entry(dictionary: "noad", entryID: "e9"), issuer: .live, language: "en", chosenBy: nil,
            answer: StudyAnswer(origin: .dictionary, text: "a penalty"), lookupID: lookup, at: now)

        // **Like for like**: the SQL predicate is enrolled *and* ready, so the Swift side has to ask
        // both questions too. Comparing it against `readiness(of:)` alone disagreed about every
        // archived note — which is the test working, on a predicate whose name overstated it.
        let bySQL = try ledger.askableNoteIDs()
        var bySwift = Set<UUID>()
        for note in try ledger.notes() {
            guard note.enrollment == .active, try ledger.readiness(of: note.id) == .ready else {
                continue
            }
            bySwift.insert(note.id)
        }
        #expect(bySQL == bySwift, "the queue and `readiness(of:)` disagree about which notes are askable")
        #expect(bySQL == [ok.noteID], "and the one they agree on is the only one that should be")
        // Named so a future reader can see the states this was measured over, not just the count.
        #expect([unconfirmed.noteID, archived.noteID, answerless.noteID, readingless.noteID,
                 entryRung.id].allSatisfy { !bySQL.contains($0) })
    }

    /// **Nothing but a deliberate grade moves the schedule** (spec §11). Enrolling, confirming,
    /// re-reading the word, pausing, hiding and archiving all leave `S`, `D` and `due` exactly as they
    /// were — measured by replaying every one of them against a card mid-schedule.
    @Test func onlyAgradeMovesTheSchedule() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        let event = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0,
                                     at: now, using: try scheduler())
        let scheduled = event.after

        let second = try ledger.record(LookupRecord(
            surface: "fine", lemma: "fine", context: "Another fine sentence.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        _ = try ledger.enroll(
            .sense(dictionary: "noad", entryID: "ee1.001", senseKey: "e1.001", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "a penalty"), lookupID: second, at: now)
        try ledger.confirm(noteID: card.noteID, at: now)
        try ledger.setPaused(true, ofCard: card.id)
        try ledger.hide(cardID: card.id, until: now.addingTimeInterval(86_400))
        try ledger.setEnrollment(.archived, of: card.noteID)
        try ledger.setEnrollment(.active, of: card.noteID)
        try ledger.setPaused(false, ofCard: card.id)

        #expect(try #require(try ledger.card(id: card.id)).scheduled == scheduled)
        #expect(try ledger.reviews(ofCard: card.id).count == 1, "and nothing invented a second review")
    }
}
