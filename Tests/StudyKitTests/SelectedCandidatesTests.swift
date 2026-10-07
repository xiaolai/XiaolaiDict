import CaptureModel
import DictionaryModel
import Foundation
import ReviewKit
import Testing
@testable import StudyKit

/// **A Selected sitting against a real ledger** (review-module-plan §8.2, WI-3b). `SelectedSittingTests`
/// proves the planner's rules on values; these prove the ledger hands it the right set, that each
/// card's frozen mode reaches the call it names, and that the commit still refuses what the draw
/// should never have offered.
struct SelectedCandidatesTests {
    /// 2027-01-15 08:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func studyDay() throws -> StudyDay {
        StudyDay(timeZone: try #require(TimeZone(identifier: "UTC")), cutoffHour: 4)
    }

    private func planner(at when: Date? = nil, perDay: Int = 5) throws -> SittingPlanner {
        SittingPlanner(studyDay: try studyDay(), now: when ?? now, batchSize: 10, newCardsPerDay: perDay)
    }

    @discardableResult
    private func ready(_ ledger: Ledger, _ word: String, dictionary: String = "noad") throws -> StudyCard {
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence with \(word).", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        let note = try ledger.enroll(
            .sense(dictionary: dictionary, entryID: "e-\(word)", senseKey: "e-\(word).1",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "what \(word) means"),
            lookupID: lookup, at: now)
        return try ledger.card(of: note.id, at: now)
    }

    /// A card placed in `phase`, due at `due`, the way the ledger writes a schedule; read back.
    @discardableResult
    private func place(_ ledger: Ledger, _ card: StudyCard, _ phase: SchedulePhase = .review,
                       due: Date) throws -> StudyCard {
        try ledger.run("""
            UPDATE study_cards SET phase = ?, stability = 10.0, difficulty = 5.0, last_review = ?, due = ?
            WHERE id = ?
            """, bind: [.text(phase.rawValue), .real(due.addingTimeInterval(-10 * day).timeIntervalSince1970),
                        .real(due.timeIntervalSince1970), .text(card.id.uuidString)]) { _ in }
        return try #require(try ledger.card(id: card.id))
    }

    private func dayStart() throws -> Date { try studyDay().start(containing: now) }

    // MARK: - The read

    /// **The selection's read is the queue's read**, so readiness is the ledger's SQL and nothing else,
    /// and the end of the sitting counts what is still due from the set the batch was drawn from.
    /// Beside it: the chosen notes in the order listed, each once, and which of them belong to another
    /// study dictionary — none, when the sitting has no scope.
    @Test func theSelectedCandidatesAreTheQueuesReadAndTheSelectionsNamespaces() throws {
        let ledger = try Ledger(path: ":memory:")
        let here = try ready(ledger, "here")
        let unconfirmed = try ready(ledger, "unconfirmed")
        try ledger.run("UPDATE study_notes SET confirmed_at = NULL WHERE id = ?",
                       bind: [.text(unconfirmed.noteID.uuidString)]) { _ in }
        let there = try ready(ledger, "there", dictionary: "oxford")
        let nobody = UUID()
        let chosen = [there.noteID, here.noteID, unconfirmed.noteID, nobody, here.noteID]

        let read = try ledger.selectedCandidates(noteIDs: chosen, dictionary: "noad", introducedSince: dayStart())
        #expect(read.queue == (try ledger.sittingCandidates(dictionary: "noad", introducedSince: dayStart())))
        #expect(read.selection == [there.noteID, here.noteID, unconfirmed.noteID, nobody])
        #expect(read.elsewhere == [there.noteID], "an unconfirmed or unknown note is not another dictionary's")
        let unscoped = try ledger.selectedCandidates(noteIDs: chosen, dictionary: nil, introducedSince: dayStart())
        #expect(unscoped.elsewhere.isEmpty, "with no scope, every namespace is the sitting's")
        #expect(unscoped.queue.cards.contains { $0.id == there.id })
    }

    // MARK: - A mixed selection

    /// **A mixed selection draws exactly the right cards, each in the right mode, and counts the rest
    /// by reason** — due, reviewed and not due, two new under an allowance of one, paused, put off, a
    /// note with a second card, an unconfirmed note, an archived note, another dictionary's note.
    @Test func aMixedSelectionDrawsTheRightCardsInTheRightModes() throws {
        let ledger = try Ledger(path: ":memory:")
        let due = try place(ledger, try ready(ledger, "due"), due: now.addingTimeInterval(-day))
        let notDue = try place(ledger, try ready(ledger, "notdue"), due: now.addingTimeInterval(3 * day))
        let firstNew = try ready(ledger, "first"), secondNew = try ready(ledger, "second")
        let paused = try place(ledger, try ready(ledger, "paused"), due: now.addingTimeInterval(-day))
        try ledger.setPaused(true, ofCard: paused.id)
        let hidden = try place(ledger, try ready(ledger, "hidden"), due: now.addingTimeInterval(-day))
        try ledger.postpone(cardID: hidden.id, until: now.addingTimeInterval(day))
        let pair = try place(ledger, try ready(ledger, "pair"), due: now.addingTimeInterval(-day))
        let second = try ledger.card(of: pair.noteID, prompt: .production, at: now)
        let unconfirmed = try ready(ledger, "unconfirmed")
        try ledger.run("UPDATE study_notes SET confirmed_at = NULL WHERE id = ?",
                       bind: [.text(unconfirmed.noteID.uuidString)]) { _ in }
        let archived = try ready(ledger, "archived")
        try ledger.setEnrollment(.archived, of: archived.noteID)
        let elsewhere = try ready(ledger, "elsewhere", dictionary: "oxford")
        try place(ledger, try ready(ledger, "unselected"), due: now.addingTimeInterval(-day))

        let chosen = [due, notDue, firstNew, secondNew, paused, hidden, pair, unconfirmed, archived, elsewhere]
            .map(\.noteID)
        let plan = try planner(perDay: 1).selectedSitting(
            from: try ledger.selectedCandidates(noteIDs: chosen + [due.noteID], dictionary: "noad",
                                                introducedSince: dayStart()),
            order: .asListed)

        #expect(plan.batch.map(\.card.id) == [due.id, notDue.id, firstNew.id, pair.id],
                "asked \(plan.batch.map(\.card.id))")
        #expect(plan.batch.map(\.mode) == [.graded, .practice, .graded, .graded])
        #expect(!plan.batch.contains { $0.card.id == second.id }, "both cards of one note")
        #expect(plan.heldBack == 1, "the second new card is the allowance's")
        #expect(plan.excluded == SittingExclusions(notAskable: 2, otherDictionary: 1, pausedOrHidden: 2, siblings: 1),
                "\(plan.excluded)")
        // Due now in the queue: `due`, `pair`, `unselected`, and one new under the allowance of one.
        // The sitting grades three of those four; the fourth, which nobody chose, is still due.
        #expect(plan.stillDue == 1)
    }

    // MARK: - The mode reaches its call

    /// **A card that is not due moves no schedule** (R4): drawn as practice, it writes a practice event
    /// and leaves the card exactly as it was, revision included, and spends no introduction — while a
    /// due card in the same sitting writes a scheduled event and moves.
    @Test func aSelectedCardThatIsNotDueMovesNoSchedule() throws {
        let ledger = try Ledger(path: ":memory:")
        let due = try place(ledger, try ready(ledger, "due"), due: now.addingTimeInterval(-day))
        let notDue = try place(ledger, try ready(ledger, "notdue"), due: now.addingTimeInterval(3 * day))
        let fresh = try ready(ledger, "fresh")
        let plan = try planner().selectedSitting(
            from: try ledger.selectedCandidates(noteIDs: [due.noteID, notDue.noteID, fresh.noteID],
                                                dictionary: "noad", introducedSince: dayStart()),
            order: .asListed)
        try #require(plan.batch.map(\.mode) == [.graded, .practice, .graded])

        let scheduler = try MemoryScheduler()
        for drawn in plan.batch {
            switch drawn.mode {
            case .graded:
                _ = try ledger.grade(cardID: drawn.card.id, .good, eventID: UUID(),
                                     expectedRevision: drawn.card.revision, at: now, using: scheduler)
            case .practice:
                _ = try ledger.practise(cardID: drawn.card.id, .good, eventID: UUID(), at: now)
            }
        }
        #expect(try ledger.reviews(ofCard: notDue.id).map(\.kind) == [.practice])
        #expect(try ledger.card(id: notDue.id) == notDue, "practice moved the card")
        #expect(try ledger.reviews(ofCard: due.id).map(\.kind) == [.graded])
        #expect(try #require(try ledger.card(id: due.id)).scheduled.due ?? .distantPast > now,
                "the due card's grade did not reschedule it")
        #expect(try ledger.reviews(ofCard: fresh.id).map(\.kind) == [.graded])
        #expect(try ledger.introductions(since: dayStart(), dictionary: "noad") == 1,
                "only the new card's first review is an introduction")
    }

    /// **A held-back new card is never practised**: the plan holds it back rather than drawing it as
    /// practice, and the ledger refuses a practice attempt at it even from a surface that tried.
    @Test func aHeldBackNewCardCannotBePractised() throws {
        let ledger = try Ledger(path: ":memory:")
        let fresh = try ready(ledger, "fresh")
        let plan = try planner(perDay: 0).selectedSitting(
            from: try ledger.selectedCandidates(noteIDs: [fresh.noteID], dictionary: "noad",
                                                introducedSince: dayStart()),
            order: .asListed)
        #expect(plan.batch.isEmpty && plan.heldBack == 1)
        #expect(throws: ReviewError.notYetReviewed(fresh.id)) {
            try ledger.practise(cardID: fresh.id, .good, eventID: UUID(), at: self.now)
        }
        #expect(try ledger.reviews(ofCard: fresh.id).isEmpty)
        #expect(try ledger.introductions(since: dayStart(), dictionary: "noad") == 0)
    }

    // MARK: - The commit contract (WI-11)

    /// **A card drawn while hidden is refused at the commit**, in either mode. The Selected draw leaves
    /// a put-off card out and counts it; a surface that skipped that filter holds the card's current
    /// revision, so only the commit's own hidden check stands between it and a write. And the two
    /// agree at the boundary: at an instant storage moves onto the put-off time, the draw offers the
    /// card and the commit takes it — the draw canonicalises its instant as the commit does (WI-11).
    @Test func aSelectedCardDrawnWhileHiddenIsRefusedAtCommit() throws {
        let ledger = try Ledger(path: ":memory:")
        let instant = Date(timeIntervalSinceReferenceDate: 800_965_756.388_499_6)
        let until = ReviewInstant.stored(instant)
        try #require(instant < until, "the fixture needs storage to move the instant later")
        let due = try place(ledger, try ready(ledger, "due"), due: until.addingTimeInterval(-2 * day))
        let ahead = try place(ledger, try ready(ledger, "ahead"), due: until.addingTimeInterval(3 * day))
        for card in [due, ahead] { try ledger.postpone(cardID: card.id, until: until) }
        let chosen = [due.noteID, ahead.noteID]
        let before = until.addingTimeInterval(-3_600)

        let refused = try planner(at: before).selectedSitting(
            from: try ledger.selectedCandidates(noteIDs: chosen, dictionary: "noad", introducedSince: before),
            order: .asListed)
        #expect(refused.batch.isEmpty)
        #expect(refused.excluded == SittingExclusions(pausedOrHidden: 2))
        // The draw that skipped the filter: the cards as they are now, revision and all.
        let current = try [due, ahead].map { try #require(try ledger.card(id: $0.id)) }
        #expect(throws: ReviewError.notEligible(due.id)) {
            try ledger.grade(cardID: due.id, .good, eventID: UUID(), expectedRevision: current[0].revision,
                             at: before, using: try MemoryScheduler())
        }
        #expect(throws: ReviewError.notEligible(ahead.id)) {
            try ledger.practise(cardID: ahead.id, .good, eventID: UUID(), at: before)
        }
        #expect(try ledger.reviews(ofCard: due.id).isEmpty && ledger.reviews(ofCard: ahead.id).isEmpty)
        #expect(try [due, ahead].compactMap { try ledger.card(id: $0.id) } == current, "a refused commit moved a card")

        // At the boundary, judged at the stored instant by both: offered, and taken.
        let offered = try planner(at: instant).selectedSitting(
            from: try ledger.selectedCandidates(noteIDs: chosen, dictionary: "noad", introducedSince: before),
            order: .asListed)
        #expect(offered.batch.map(\.card.id) == [due.id, ahead.id])
        #expect(offered.batch.map(\.mode) == [.graded, .practice])
        _ = try ledger.grade(cardID: due.id, .good, eventID: UUID(), expectedRevision: current[0].revision,
                             at: instant, using: try MemoryScheduler())
        _ = try ledger.practise(cardID: ahead.id, .good, eventID: UUID(), at: instant)
        #expect(try ledger.reviews(ofCard: due.id).map(\.kind) == [.graded])
        #expect(try ledger.reviews(ofCard: ahead.id).map(\.kind) == [.practice])
    }
}
