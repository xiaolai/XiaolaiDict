import Foundation
@testable import ReviewKit
import Testing

/// **A Selected sitting: exactly the notes the reader chose in Saved, filtered before anything is
/// shown and counted by reason** (review-module-plan §8.2, R4, WI-3b).
///
/// The planner is handed the reader's selection beside the one read a Review sitting is planned from —
/// every card of every askable note — so readiness is never judged here. What it decides is the rest:
/// put away or not, one card per note, the new-card allowance, and the mode each card is asked in,
/// fixed at the draw.
struct SelectedSittingTests {
    // MARK: - Fixture

    private func utc() throws -> TimeZone { try #require(TimeZone(identifier: "UTC")) }

    /// 2027-01-`day` at `hour`:`minute` UTC. Whole seconds, so each is its own stored form.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try utc()
        return try #require(calendar.date(from: DateComponents(
            year: 2027, month: 1, day: day, hour: hour, minute: minute, second: second)))
    }

    private func planner(at now: Date, perDay: Int = 5, increase: Int = 0) throws -> SittingPlanner {
        SittingPlanner(studyDay: StudyDay(timeZone: try utc(), cutoffHour: 4), now: now,
                       batchSize: 10, newCardsPerDay: perDay, increaseToday: increase)
    }

    private func card(id: UUID = UUID(), note: UUID = UUID(), _ phase: SchedulePhase = .review,
                      due: Date?, paused: Bool = false, hiddenUntil: Date? = nil) -> StudyCard {
        StudyCard(id: id, noteID: note, scheduled: ScheduledCard(
                      state: phase == .new ? nil : MemoryState(stability: 10, difficulty: 5),
                      phase: phase, lastReview: nil, due: phase == .new ? nil : due),
                  isPaused: paused, hiddenUntil: hiddenUntil, createdAt: .distantPast)
    }

    private func newCard(note: UUID = UUID()) -> StudyCard { card(note: note, .new, due: nil) }

    private func candidates(_ selected: [StudyCard], plus others: [StudyCard] = [], introduced: Int = 0,
                            selection: [UUID]? = nil, elsewhere: Set<UUID> = []) -> SelectedCandidates {
        SelectedCandidates(selection: selection ?? selected.map(\.noteID),
                           queue: SittingCandidates(cards: selected + others, introducedToday: introduced),
                           elsewhere: elsewhere)
    }

    // MARK: - The allowance

    /// **Ten new cards selected and an allowance of five: five are introduced, five are held back** —
    /// and what is left of the allowance is what counts, so two introduced earlier leave three. Taken
    /// in the order listed: the reader's own first choices are the ones asked.
    @Test func aSelectedSittingOfTenNewCardsIntroducesAtMostTheRemainingAllowance() throws {
        let fresh = (0..<10).map { _ in newCard() }
        let listed = fresh.map(\.noteID)
        for (introduced, asked) in [(0, 5), (2, 3), (5, 0), (9, 0)] {
            let plan = try planner(at: at(20, 10), perDay: 5)
                .selectedSitting(from: candidates(fresh, introduced: introduced), order: .asListed)
            #expect(plan.batch.count == asked, "\(introduced) introduced today: \(plan.batch.count) asked")
            #expect(plan.heldBack == 10 - asked, "\(introduced) introduced today: \(plan.heldBack) held back")
            #expect(plan.batch.map(\.card.noteID) == Array(listed.prefix(asked)), "not the first ones listed")
            #expect(plan.batch.allSatisfy { $0.mode == .graded }, "a first introduction is a review")
        }
        let unlimited = try planner(at: at(20, 10), perDay: .max, increase: 3)
            .selectedSitting(from: candidates(fresh), order: .asListed)
        #expect(unlimited.batch.count == 10 && unlimited.heldBack == 0)
    }

    /// **"Due" by the value predicate is not "offered".** A new card has no due date, so
    /// `StudyCard.isDue(at:)` says yes as soon as it is ready; the allowance is what says no, and a
    /// held-back card is not late, so it is not counted as still due either.
    @Test func aHeldBackNewCardIsNotOfferedThoughItIsDue() throws {
        let fresh = newCard()
        let now = try at(20, 10)
        try #require(fresh.isDue(at: now), "the premise: a new card is due by the value predicate")
        let plan = try planner(at: now, perDay: 1)
            .selectedSitting(from: candidates([fresh], introduced: 1), order: .asListed)
        #expect(plan.batch.isEmpty, "a held-back card was offered")
        #expect(plan.heldBack == 1)
        #expect(plan.stillDue == 0, "a card the allowance holds is not a backlog")
    }

    /// **A held-back new card never becomes practice** (§8.2): it has no memory state for practice to
    /// leave unchanged, and `practise` refuses it (`ReviewError.notYetReviewed`). Over every allowance
    /// and every count already spent, a card with no state is either graded or not drawn, and only a
    /// card reviewed before and not due is ever practised.
    @Test func aHeldBackNewCardIsNeverPractised() throws {
        let now = try at(20, 10)
        let fresh = (0..<4).map { _ in newCard() }
        let ahead = (0..<3).map { _ in card(due: now.addingTimeInterval(2 * 86_400)) }
        let behind = (0..<2).map { _ in card(due: now.addingTimeInterval(-86_400)) }
        let all = fresh + ahead + behind
        for perDay in 0...6 {
            for introduced in 0...6 {
                let plan = try planner(at: now, perDay: perDay)
                    .selectedSitting(from: candidates(all, introduced: introduced), order: .asListed)
                let left = max(0, perDay - introduced)
                let label = "allowance \(perDay), \(introduced) spent"
                #expect(!plan.batch.contains { $0.card.scheduled.state == nil && $0.mode == .practice },
                        "\(label): a card with no memory state was drawn as practice")
                #expect(plan.batch.filter { $0.mode == .practice }
                    .allSatisfy { $0.card.scheduled.state != nil && !$0.card.isDue(at: now) }, "\(label)")
                #expect(plan.batch.count { $0.card.scheduled.phase == .new } == min(left, fresh.count), "\(label)")
                #expect(plan.heldBack == fresh.count - min(left, fresh.count), "\(label)")
                #expect(plan.batch.count { $0.mode == .practice } == ahead.count, "\(label)")
            }
        }
    }

    // MARK: - Put away

    /// **Paused and put off are left out, and counted.** Judged at the stored instant, as the commit
    /// judges it: a card put off until exactly the instant storage moves `now` to is askable then, and
    /// one put off a second longer is not.
    @Test func aHiddenSelectedCardIsExcludedAndCounted() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_965_756.388_499_6)
        let stored = ReviewInstant.stored(now)
        try #require(now < stored, "the fixture needs storage to move the instant later")
        let past = now.addingTimeInterval(-86_400)
        let hidden = card(due: past, hiddenUntil: stored.addingTimeInterval(1))
        let paused = card(due: past, paused: true)
        let backNow = card(due: past, hiddenUntil: stored)
        let plain = card(due: past)
        let plan = try planner(at: now).selectedSitting(
            from: candidates([hidden, paused, backNow, plain]), order: .asListed)
        #expect(plan.batch.map(\.card.id) == [backNow.id, plain.id])
        #expect(plan.excluded == SittingExclusions(pausedOrHidden: 2), "\(plan.excluded)")
        #expect(plan.heldBack == 0)
    }

    // MARK: - The mode

    /// **The mode is decided once, by whether the card is due when the sitting is drawn** (R4): due —
    /// a new card included — is graded; reviewed and not due yet is practice. The boundary is the
    /// stored instant: due at exactly it is due.
    @Test func theModeIsWhetherTheCardIsDueWhenDrawn() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_965_756.388_499_6)
        let stored = ReviewInstant.stored(now)
        let overdue = card(due: now.addingTimeInterval(-86_400))
        let exactly = card(due: stored)
        let aSecondLater = card(due: stored.addingTimeInterval(1))
        let learningLater = card(.learning, due: now.addingTimeInterval(600))
        let fresh = newCard()
        let plan = try planner(at: now).selectedSitting(
            from: candidates([overdue, exactly, aSecondLater, learningLater, fresh]), order: .asListed)
        let modes = Dictionary(uniqueKeysWithValues: plan.batch.map { ($0.card.id, $0.mode) })
        #expect(modes == [overdue.id: .graded, exactly.id: .graded, aSecondLater.id: .practice,
                          learningLater.id: .practice, fresh.id: .graded])
    }

    /// **A note with work waiting is reviewed, not practised.** Its learning card comes first in the
    /// queue's order but is not due for ten minutes; its review card is due. A sitting that took the
    /// queue's order alone would practise the note and leave the due card due.
    @Test func aNoteIsAskedThroughItsDueCardBeforeOneThatIsNot() throws {
        let now = try at(20, 10)
        let note = UUID()
        let learningLater = card(note: note, .learning, due: now.addingTimeInterval(600))
        let reviewDue = card(note: note, due: now.addingTimeInterval(-86_400))
        let plan = try planner(at: now).selectedSitting(
            from: candidates([learningLater, reviewDue], selection: [note]), order: .asListed)
        #expect(plan.batch == [SelectedCard(card: reviewDue, mode: .graded)])
        #expect(plan.excluded == SittingExclusions(siblings: 1))
    }

    /// **A held-back new card does not take its note's reviewed card with it.** The new card is never
    /// practised — it has no memory state — but its sibling has, so with the allowance spent the note
    /// is practised through it rather than reported as "a new meaning" waiting for tomorrow. With the
    /// allowance whole, the new card is due and comes first.
    @Test func aNoteWhoseNewCardIsHeldBackIsAskedThroughItsReviewedCard() throws {
        let now = try at(20, 10)
        let note = UUID()
        let fresh = newCard(note: note)
        let reviewed = card(note: note, due: now.addingTimeInterval(2 * 86_400))
        let input = { (introduced: Int) in self.candidates([fresh, reviewed], introduced: introduced, selection: [note]) }
        let spent = try planner(at: now, perDay: 1).selectedSitting(from: input(1), order: .asListed)
        #expect(spent.batch == [SelectedCard(card: reviewed, mode: .practice)])
        #expect(spent.heldBack == 0 && spent.excluded == SittingExclusions(siblings: 1))
        let whole = try planner(at: now, perDay: 1).selectedSitting(from: input(0), order: .asListed)
        #expect(whole.batch == [SelectedCard(card: fresh, mode: .graded)])
        #expect(whole.excluded == SittingExclusions(siblings: 1))
    }

    // MARK: - Everything at once

    /// **A mixed selection, accounted for once by reason.** Due, reviewed and not due, two new under an
    /// allowance of one, paused, put off, a note with two cards, a note the ledger will not ask, a note
    /// from another study dictionary, and one note listed twice. The cards asked are exactly the right
    /// ones in the listed order with the right modes; everything else is a count, and the counts with
    /// the batch add up to the selection.
    @Test func aMixedSelectionIsAccountedForOnceByReason() throws {
        let now = try at(20, 10)
        let past = now.addingTimeInterval(-86_400), ahead = now.addingTimeInterval(3 * 86_400)
        let due = card(due: past)
        let notDue = card(due: ahead)
        let firstNew = newCard(), secondNew = newCard()
        let paused = card(due: past, paused: true)
        let hidden = card(due: past, hiddenUntil: now.addingTimeInterval(3_600))
        let pair = UUID()
        let pairDue = card(note: pair, due: past), pairAhead = card(note: pair, due: ahead)
        let notAskable = UUID(), elsewhere = UUID()
        let unselected = (0..<3).map { _ in card(due: past) }
        let selection = [due.noteID, notDue.noteID, firstNew.noteID, secondNew.noteID, paused.noteID,
                         hidden.noteID, pair, notAskable, elsewhere, due.noteID]
        let plan = try planner(at: now, perDay: 1).selectedSitting(
            from: candidates([due, notDue, firstNew, secondNew, paused, hidden, pairAhead, pairDue],
                             plus: unselected, selection: selection, elsewhere: [elsewhere]),
            order: .asListed)

        #expect(plan.batch == [SelectedCard(card: due, mode: .graded), SelectedCard(card: notDue, mode: .practice),
                               SelectedCard(card: firstNew, mode: .graded), SelectedCard(card: pairDue, mode: .graded)])
        #expect(plan.heldBack == 1)
        #expect(plan.excluded == SittingExclusions(notAskable: 1, otherDictionary: 1, pausedOrHidden: 2, siblings: 1),
                "\(plan.excluded)")
        let accounted = plan.batch.count + plan.heldBack + plan.excluded.notAskable
            + plan.excluded.otherDictionary + plan.excluded.pausedOrHidden
        #expect(accounted == Set(selection).count, "a chosen note was dropped or counted twice")
        // The queue is due 3 + 2 + one new of two = 6 now; this sitting grades `due`, one new and
        // `pairDue`, so the three nobody selected are what is still due at its end.
        #expect(plan.stillDue == unselected.count)
    }

    /// **Over two hundred random selections, every rule at once**: a note is asked at most once and
    /// only if chosen; the batch, the held back and the exclusions account for every chosen note; the
    /// allowance holds; nothing new is practised; and what is still due is exactly the queue's count
    /// with this sitting's graded cards taken out and its introductions spent — whatever the order.
    @Test func everyRuleHoldsOverRandomSelections() throws {
        var generator = Seeded(state: 20_261_004)
        let now = try at(20, 10)
        let phases = SchedulePhase.allCases
        for round in 0..<200 {
            let notes = (0..<Int.random(in: 1...8, using: &generator)).map { _ in UUID() }
            let cards = (0..<Int.random(in: 0...20, using: &generator)).map { _ -> StudyCard in
                let phase = phases[Int.random(in: 0..<phases.count, using: &generator)]
                let due = now.addingTimeInterval(TimeInterval(Int.random(in: -4...3, using: &generator)) * 43_200)
                let hidden: Date? = Int.random(in: 0..<5, using: &generator) == 0 ? now.addingTimeInterval(3_600) : nil
                return card(note: notes[Int.random(in: 0..<notes.count, using: &generator)], phase, due: due,
                            paused: Int.random(in: 0..<8, using: &generator) == 0, hiddenUntil: hidden)
            }
            let chosen = notes.filter { _ in Bool.random(using: &generator) } + [UUID()]
            let elsewhere: Set<UUID> = Bool.random(using: &generator) ? [chosen[chosen.count - 1]] : []
            let perDay = Int.random(in: 0...4, using: &generator), introduced = Int.random(in: 0...3, using: &generator)
            let planner = try planner(at: now, perDay: perDay)
            let input = SelectedCandidates(selection: chosen,
                                           queue: SittingCandidates(cards: cards, introducedToday: introduced),
                                           elsewhere: elsewhere)
            for order in [SittingOrder.asListed, .shuffled] {
                let plan = planner.selectedSitting(from: input, order: order)
                let label = "round \(round), \(order)"
                let asked = plan.batch.map(\.card.noteID)
                #expect(Set(asked).count == asked.count, "\(label): a note asked twice")
                #expect(Set(asked).isSubset(of: Set(chosen)), "\(label): a note nobody chose")
                #expect(plan.batch.allSatisfy { !$0.card.isPaused && !$0.card.isHidden(at: planner.now) }, "\(label)")
                let accounted = plan.batch.count + plan.heldBack + plan.excluded.notAskable
                    + plan.excluded.otherDictionary + plan.excluded.pausedOrHidden
                #expect(accounted == Set(chosen).count, "\(label): \(accounted) of \(Set(chosen).count) accounted for")
                let left = SittingPlanner.newCardsLeft(allowance: perDay, introduced: introduced)
                let fresh = plan.batch.count { $0.card.scheduled.phase == .new }
                #expect(fresh <= left, "\(label): \(fresh) new over an allowance of \(left)")
                #expect(!plan.batch.contains { $0.card.scheduled.state == nil && $0.mode == .practice }, "\(label)")
                #expect(plan.batch.allSatisfy { ($0.mode == .graded) == $0.card.isDue(at: planner.now) }, "\(label)")
                let graded = Set(plan.batch.filter { $0.mode == .graded }.map(\.card.id))
                let after = SittingPlanner.counts(of: cards.filter { !graded.contains($0.id) }, at: now,
                                                  newCardsLeft: left - fresh)
                #expect(plan.stillDue == after.due, "\(label): still due \(plan.stillDue), the queue after it \(after.due)")
            }
        }
    }

    // MARK: - Order

    /// **As listed, or shuffled by the sitting's own instant.** The shuffle is a permutation of what
    /// as-listed asks, one instant always gives one order, the next second another, and the input's
    /// own order does not leak into it. Under a shuffle the allowance goes to whichever new cards the
    /// shuffle puts first, and is still the allowance.
    @Test func aSelectedSittingIsAskedAsListedOrShuffledByItsInstant() throws {
        let yesterday = try at(19, 9)
        let reviewed = (0..<12).map { _ in card(due: yesterday) }
        let fresh = (0..<4).map { _ in newCard() }
        let listed = (reviewed + fresh).map(\.noteID)
        let input = candidates(reviewed + fresh)
        let planner = try planner(at: at(20, 10), perDay: 2)
        let asListed = planner.selectedSitting(from: input, order: .asListed)
        #expect(asListed.batch.map(\.card.noteID) == Array(listed.prefix(14)), "twelve reviewed, then the first two new")
        #expect(asListed.heldBack == 2)

        let shuffled = planner.selectedSitting(from: input, order: .shuffled)
        let order = shuffled.batch.map(\.card.noteID)
        let freshNotes = Set(fresh.map(\.noteID))
        #expect(Set(order.filter { !freshNotes.contains($0) }) == Set(reviewed.map(\.noteID)),
                "the shuffle lost or invented a reviewed card")
        #expect(order.count { freshNotes.contains($0) } == 2 && shuffled.heldBack == 2,
                "the allowance does not hold under a shuffle")
        #expect(order != asListed.batch.map(\.card.noteID), "the shuffle is the listing")
        #expect(planner.selectedSitting(from: input, order: .shuffled) == shuffled, "one instant, two orders")
        let reversed = SelectedCandidates(selection: listed,
                                          queue: SittingCandidates(cards: (reviewed + fresh).reversed(), introducedToday: 0))
        #expect(planner.selectedSitting(from: reversed, order: .shuffled) == shuffled, "the candidates' order leaked")
        let nextSecond = try self.planner(at: at(20, 10, 0, 1), perDay: 2).selectedSitting(from: input, order: .shuffled)
        #expect(nextSecond.batch.map(\.card.noteID) != order, "asking for a shuffle again gave the same order")
    }

    // MARK: - The sitting carries the mode

    /// **The mode survives an undo.** The restored card is a new attempt with a new identity, but the
    /// same card drawn the same way: a practice card brought back by undo and then answered must not
    /// reach the scheduler.
    @Test func aPresentationKeepsItsModeThroughUndo() {
        var session = ReviewSession(startedAt: .distantPast, drawn: [
            (id: UUID(), revision: 0, mode: .graded), (id: UUID(), revision: 3, mode: .practice),
        ])
        session.record(.graded(.good))
        let practising = session.current
        session.record(.graded(.again))
        let restored = session.undoLast(revision: 4)
        #expect(restored?.cardID == practising?.cardID)
        #expect(restored?.id != practising?.id)
        #expect(restored?.mode == .practice, "undo turned a practice card into a scheduled one")
        #expect(session.presentations.map(\.mode) == [.graded, .practice])
    }

    /// **The end of a sitting counts by mode.** Practice answers are said apart from reviews, a
    /// skipped practice card is not "still due", and a sitting is practice only if every card was.
    @Test func theSummaryCountsPracticeAndSkipsByMode() {
        var mixed = ReviewSession(startedAt: .distantPast, drawn: [
            (id: UUID(), revision: 0, mode: .graded), (id: UUID(), revision: 0, mode: .practice),
            (id: UUID(), revision: 0, mode: .practice), (id: UUID(), revision: 0, mode: .graded),
        ], beyondBatch: 7, heldBack: 2, excluded: SittingExclusions(notAskable: 1, pausedOrHidden: 2))
        mixed.record(.graded(.good))
        mixed.record(.graded(.again))
        mixed.record(.skipped)
        mixed.record(.skipped)
        let summary = mixed.summary()
        #expect(summary == ReviewSession.Summary(
            graded: 2, skipped: 2, stillDue: 7, heldBack: 2, wasPractice: false, practised: 1,
            skippedPractice: 1, excluded: SittingExclusions(notAskable: 1, pausedOrHidden: 2),
            forgotInPractice: 1), "\(summary)")
        #expect(summary.skippedStillDue == 1)

        var practice = ReviewSession(startedAt: .distantPast, cards: [(id: UUID(), revision: 0)], mode: .practice)
        practice.record(.skipped)
        #expect(practice.summary().wasPractice)
        #expect(practice.summary().skippedStillDue == 0, "a practice card was never due")
        #expect(!ReviewSession(startedAt: .distantPast, cards: []).summary().wasPractice,
                "an empty sitting is not a practice sitting")
    }

    /// SplitMix64, seeded, so a failing round can be found again.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
