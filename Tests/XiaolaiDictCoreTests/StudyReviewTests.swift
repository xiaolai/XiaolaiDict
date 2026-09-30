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

    /// **One spelling of the target**, so re-enrolling it in a test cannot accidentally make a
    /// different note while the test goes on claiming the schedule survived.
    private func target(key: String = "e1.001") -> StudyTarget {
        .sense(dictionary: "noad", entryID: "e\(key)", senseKey: key, senseKeyKind: .publisher)
    }

    private func ready(_ ledger: Ledger, _ lemma: String = "fine", key: String = "e1.001",
                       at when: Date? = nil) throws -> StudyCard {
        let when = when ?? now
        let lookup = try ledger.record(LookupRecord(
            surface: lemma, lemma: lemma, context: "He paid the \(lemma).", lemmaBasis: .tagger,
            language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: when, result: .found, answeredBy: .dictionaryService, quality: nil))
        let note = try ledger.enroll(
            target(key: key),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "a penalty"), lookupID: lookup, at: when)
        return try ledger.card(of: note.id, at: when)
    }

    private func scheduler() throws -> MemoryScheduler { try MemoryScheduler() }

    // MARK: - Practice leaves the schedule alone, on the way back out too

    /// **A practice event read back must say what it said when it was written.**
    ///
    /// `after.lastReview` is not a column — it is derived from `reviewed_at`, which is right for a
    /// grade and wrong for practice: practice moves nothing, so the card's last review is still
    /// whenever it was last *graded*. Reconstructed as the practice timestamp, the stored event
    /// disagreed with the one `practise` returned, and a retry of the same attempt answered with a
    /// different value than the first call.
    @Test func apracticeEventSurvivesTheRoundTripUnchanged() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now, using: try scheduler())

        let eventID = UUID()
        let later = now.addingTimeInterval(3_600)
        let written = try ledger.practise(cardID: card.id, .good, eventID: eventID, at: later)
        #expect(written.after == written.before, "practice records that nothing moved")

        let read = try #require(try ledger.reviews(ofCard: card.id).first { $0.id == eventID })
        #expect(read.after == read.before, "and it still says so when it is read back")
        #expect(read.after.lastReview == written.after.lastReview,
                "the practice timestamp is not the card's last review")
        // The idempotency path answers with the stored event, so it must answer the same thing.
        let retried = try ledger.practise(cardID: card.id, .good, eventID: eventID, at: later)
        #expect(retried.after.lastReview == written.after.lastReview)
    }

    /// **Undo still works after a practice attempt**, which is what the round trip above is
    /// protecting. Undo guards on the card still being in the state the latest event produced; a
    /// practice event that claimed to have moved `lastReview` failed that guard and reported a
    /// stale revision to a reader whose card nothing had touched.
    @Test func undoWorksAfterApracticeAttempt() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now, using: try scheduler())
        _ = try ledger.practise(cardID: card.id, .again, eventID: UUID(),
                                at: now.addingTimeInterval(3_600))

        let undone = try ledger.undoLatestReview(ofCard: card.id, at: now.addingTimeInterval(7_200))
        #expect(undone.kind == .practice, "the practice attempt is the latest thing to take back")
    }

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
        // A clock that has gone backwards makes the scheduler throw after the eligibility checks.
        //
        // **This does not exercise the savepoint's rollback, and must not be read as doing so.**
        // Every throw in `grade` happens before both of its writes — idempotency, the card, the
        // revision, eligibility and the scheduler all come first — so there is nothing for
        // `ROLLBACK TO` to undo. Reaching the window between `insert` and `write` needs a failure
        // the ledger cannot currently produce: the scheduler refuses to return a `new` phase with
        // a stability, which is the one `study_cards` CHECK an injected value could violate. A
        // test-only seam in transaction code would reach it and is a design decision, not an
        // effort one. What this *does* prove is that a throw leaves neither an event nor a moved
        // card behind.
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now, using: try scheduler())
        let before = try #require(try ledger.card(id: card.id))
        // **The error this expects, not any error.** `(any Error).self` passed for a typo in the
        // fixture as readily as for the refusal being asserted.
        #expect(throws: SchedulerError.self) {
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

    /// **A voided event's id is spent, not reusable.** Re-grading after an undo reused the
    /// presentation's id, the idempotency check found the voided row and returned it as though the
    /// new grade had committed, and the surface advanced over a review that never happened. Returning
    /// a *voided* event as a successful result is the defect; the id is refused instead.
    @Test func regradingWithAvoidedEventIdIsRefusedRatherThanSilentlyDropped() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        let eventID = UUID()
        _ = try ledger.grade(cardID: card.id, .again, eventID: eventID, expectedRevision: 0,
                             at: now, using: try scheduler())
        try ledger.undoLatestReview(ofCard: card.id, at: now)

        #expect(throws: ReviewError.eventAlreadyVoided(eventID)) {
            try ledger.grade(cardID: card.id, .good, eventID: eventID, expectedRevision: 0,
                             at: self.now, using: try self.scheduler())
        }
        // A *fresh* attempt lands, which is what the reader is actually doing after an undo.
        let replacement = try ledger.grade(cardID: card.id, .good, eventID: UUID(),
                                           expectedRevision: 2, at: now, using: try scheduler())
        let live = try ledger.reviews(ofCard: card.id).filter { !$0.isVoid }
        #expect(live.map(\.id) == [replacement.id])
        #expect(try #require(try ledger.card(id: card.id)).scheduled == replacement.after)
    }

    // MARK: - The queue

    /// **Learning and relearning first, then review by oldest due, then the unreviewed.** A simple
    /// auditable order, and nothing cleverer: a priority score would be a claim about this reader's
    /// memory that nothing here has measured.
    @Test func thequeueOrdersLearningThenOverdueThenNew() throws {
        let ledger = try Ledger(path: ":memory:")
        let lapsed = try ready(ledger, "fine", key: "a")
        let older = try ready(ledger, "hold", key: "b")
        let newer = try ready(ledger, "bank", key: "c")
        let fresh = try ready(ledger, "keen", key: "d")

        // **`lapsed` is genuinely relearning**, which takes two grades: a new card answered
        // `.again` lands in *learning*, and the comment here used to say relearning while the
        // fixture produced something else. The queue treats the two alike, so the fixture was
        // never exercising the phase it named.
        _ = try ledger.grade(cardID: lapsed.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now, using: try scheduler())
        let lapsedRevision = try #require(try ledger.card(id: lapsed.id)).revision
        _ = try ledger.grade(cardID: lapsed.id, .again, eventID: UUID(),
                             expectedRevision: lapsedRevision,
                             at: now.addingTimeInterval(200_000), using: try scheduler())
        #expect(try #require(try ledger.card(id: lapsed.id)).scheduled.phase == .relearning)

        // **Two review cards, due at different times**, so "oldest due first" is a claim the
        // fixture can refute. With one, any ordering put it in the right place.
        _ = try ledger.grade(cardID: older.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now, using: try scheduler())
        _ = try ledger.grade(cardID: newer.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: now.addingTimeInterval(86_400), using: try scheduler())
        let olderCard = try #require(try ledger.card(id: older.id))
        let newerCard = try #require(try ledger.card(id: newer.id))
        let olderDue = try #require(olderCard.scheduled.due)
        let newerDue = try #require(newerCard.scheduled.due)
        #expect(olderDue < newerDue, "the fixture's two review cards are due at the same time")
        // `fresh` has never been graded at all.

        let later = now.addingTimeInterval(400 * 86_400)
        let queue = try ledger.dueCards(at: later, limit: 10, dictionary: "noad",
                                        newAllowance: .max, dayStart: .distantPast)
        #expect(queue.map(\.id) == [lapsed.id, older.id, newer.id, fresh.id],
                "got \(queue.map { "\($0.scheduled.phase)" })")
    }

    /// A card not yet due is not in the queue, and neither is one the reader paused or hid.
    @Test func thequeueLeavesOutWhatIsNotDue() throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0, at: now,
                             using: try scheduler())
        // What the grade produced, which is what pausing and postponing must leave alone.
        let answered = try #require(try ledger.card(id: card.id))
        let graded = answered.scheduled.state?.stability
        let due = answered.scheduled.due
        #expect(graded != nil, "the fixture has a memory state to protect")
        #expect(try ledger.dueCards(at: now, limit: 10, dictionary: nil,
                                        newAllowance: .max, dayStart: .distantPast).isEmpty,
                "a card just answered is not due again in the same second")

        let later = now.addingTimeInterval(400 * 86_400)
        #expect(try ledger.dueCards(at: later, limit: 10, dictionary: nil,
                                        newAllowance: .max, dayStart: .distantPast).count == 1)
        try ledger.setPaused(true, ofCard: card.id)
        #expect(try ledger.dueCards(at: later, limit: 10, dictionary: nil,
                                        newAllowance: .max, dayStart: .distantPast).isEmpty)
        try ledger.setPaused(false, ofCard: card.id)
        // **The unpause is asserted before the postpone is.** Without this a broken resume kept
        // the queue empty and the postpone below looked like it was working.
        #expect(try ledger.dueCards(at: later, limit: 10, dictionary: nil,
                                        newAllowance: .max, dayStart: .distantPast).count == 1,
                "resuming did not bring the card back, so nothing below is testing postpone")

        try ledger.postpone(cardID: card.id, until: later.addingTimeInterval(86_400))
        #expect(try ledger.dueCards(at: later, limit: 10, dictionary: nil,
                                        newAllowance: .max, dayStart: .distantPast).isEmpty)
        // **Neither touched the memory**: hiding and pausing are about what is asked, not about
        // `S`. Compared against the stability the *grade* produced — the original card is `new`
        // with none, so the old `??` fell through to comparing the current value with itself and
        // any corruption in between passed.
        #expect(try #require(try ledger.card(id: card.id)).scheduled.state?.stability == graded,
                "pausing or postponing moved the memory state")
        #expect(try #require(try ledger.card(id: card.id)).scheduled.due == due,
                "…or the due date")
    }

    /// Study state belongs to one dictionary, so a session's queue must not mix two namespaces.
    @Test func thequeueIsScopedToOneDictionary() throws {
        let ledger = try Ledger(path: ":memory:")
        let mineCard = try ready(ledger)
        let note = try #require(try ledger.notes().first { $0.target.dictionary == "noad" })
        _ = mineCard
        let lookup = try ledger.record(LookupRecord(
            surface: "fine", lemma: "fine", context: "He paid the fine.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        let other = try ledger.enroll(
            .sense(dictionary: "oxford", entryID: "e1", senseKey: "e1.001", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "a penalty"), lookupID: lookup, at: now)
        _ = try ledger.card(of: other.id, at: now)

        // **Which card, not how many.** Both scopes hold exactly one card, so a count of 1 is
        // satisfied by returning the *other* dictionary's — the precise failure this is for.
        let mine = try #require(try ledger.existingCard(of: note.id))
        let theirs = try #require(try ledger.existingCard(of: other.id))
        func queue(_ dictionary: String?) throws -> [UUID] {
            try ledger.dueCards(at: now, limit: 10, dictionary: dictionary,
                                newAllowance: .max, dayStart: .distantPast).map(\.id)
        }
        #expect(try queue("noad") == [mine.id])
        #expect(try queue("oxford") == [theirs.id])
        #expect(try Set(queue(nil)) == [mine.id, theirs.id],
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

        // **And the filtering happens before the `LIMIT`, which the comparison above cannot see.**
        // `askableNoteIDs()` has no limit and does not go through `dueCards`, so moving
        // eligibility into a Swift filter *after* the queue's `LIMIT` — the defect this ledger has
        // had once — would leave every assertion above passing. Six askable cards behind five
        // unaskable ones: asked for three, a queue that filters afterwards hands back none.
        for index in 0..<6 {
            _ = try ready(ledger, "wanted\(index)", key: "w\(index)")
        }
        let batch = try ledger.dueCards(at: now, limit: 3, dictionary: "noad",
                                        newAllowance: .max, dayStart: .distantPast)
        #expect(batch.count == 3,
                "asked for 3 of 7 askable cards and got \(batch.count) — filtered after the LIMIT")
        // Named so a future reader can see the states this was measured over, not just the count.
        #expect([unconfirmed.noteID, archived.noteID, answerless.noteID, readingless.noteID,
                 entryRung.id].allSatisfy { !bySQL.contains($0) })
    }

    /// **The two judges of "usable" must agree about whitespace too.**
    ///
    /// SQL's `trim()` removes ordinary spaces and nothing else; Swift's `.whitespacesAndNewlines`
    /// removes tabs, newlines and the ideographic space as well. So an answer of `"\n\t\u{3000}"`
    /// was unusable to `readiness(of:)`, usable to the queue, and blank on the card — a question
    /// with nothing behind it, offered and gradable. The agreement test never found it because it
    /// never constructed one.
    @Test(arguments: ["\n", "\t", "\u{3000}", " \n\t\u{3000} ", "\u{00a0}"])
    func anAnswerOfOnlyWhitespaceIsUnusableToBothJudges(text: String) throws {
        let ledger = try Ledger(path: ":memory:")
        let card = try ready(ledger)
        try ledger.setAnswer(StudyAnswer(origin: .dictionary, text: text), of: card.noteID, at: now)

        #expect(try ledger.readiness(of: card.noteID) == .needsRepair)
        #expect(try ledger.askableNoteIDs().isEmpty, "the queue admitted a card with a blank answer")
        #expect(try ledger.dueCards(at: now, limit: 10, dictionary: nil,
                                        newAllowance: .max, dayStart: .distantPast).isEmpty)
        #expect(throws: ReviewError.notEligible(card.id)) {
            try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0,
                             at: self.now, using: try self.scheduler())
        }
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
        let again = try ledger.enroll(
            target(), issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "a penalty"), lookupID: second, at: now)
        // **The same note, which is what makes the rest of this a test.** Spelling the target
        // out here duplicated `ready`'s construction, so changing the helper would have made a
        // second note quietly and left the assertions below true of a card nothing touched.
        #expect(again.id == card.noteID, "re-enrolling made a different note")
        try ledger.confirm(noteID: card.noteID, at: now)
        try ledger.setPaused(true, ofCard: card.id)
        try ledger.postpone(cardID: card.id, until: now.addingTimeInterval(86_400))
        try ledger.setEnrollment(.archived, of: card.noteID)
        try ledger.setEnrollment(.active, of: card.noteID)
        try ledger.setPaused(false, ofCard: card.id)

        #expect(try #require(try ledger.card(id: card.id)).scheduled == scheduled)
        #expect(try ledger.reviews(ofCard: card.id).count == 1, "and nothing invented a second review")
    }
}
