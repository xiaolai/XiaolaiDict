import Foundation
import Testing
import ReviewKit

/// **The rules of a sitting**, without a window or a ledger.
///
/// Each of these is a way a review surface lies to the reader: a reveal that quietly grades, a double
/// press that grades twice, a batch that says "all done" over a backlog, a skip counted as a review.
struct ReviewSessionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ count: Int = 3, beyond: Int = 0) -> ReviewSession {
        ReviewSession(startedAt: now,
                      cards: (0..<count).map { _ in (id: UUID(), revision: 0) },
                      beyondBatch: beyond)
    }

    /// **Reveal does not grade.** A reader who has seen the answer has not said whether they knew it,
    /// and inferring "forgot" from a reveal records a failure they never reported.
    @Test func revealingShowsTheAnswerAndNothingElse() {
        var session = session()
        let first = session.current
        session.reveal()
        #expect(session.current?.isRevealed == true)
        #expect(session.current?.outcome == nil)
        #expect(session.current?.id == first?.id, "revealing does not advance")
        #expect(session.graded == 0)
    }

    /// A presentation takes one outcome. A second press — a key repeat, an impatient click — must not
    /// become a second grade even if every layer below were willing to write it.
    @Test func onePresentationTakesOneOutcome() {
        var session = session()
        let first = session.current
        // Outside `#expect`: the macro captures its operand immutably, so a mutating call there
        // will not compile — and hiding the call inside an assertion reads as if it were free of
        // effect, which this one is not.
        let recorded = session.record(.graded(.good))
        #expect(recorded)
        #expect(session.current?.id != first?.id, "and it moved on")
        // The second call lands on the *next* presentation, not the graded one.
        let second = session.record(.graded(.again))
        #expect(second)
        #expect(session.presentations[0].outcome == .graded(.good))
        #expect(session.presentations[1].outcome == .graded(.again))
        #expect(session.graded == 2)
    }

    /// **A skip is not a review.** It consumes no grade, and the card is exactly as due afterwards.
    @Test func askipIsCountedApartFromAgrade() {
        var session = session()
        session.record(.skipped)
        session.record(.graded(.good))
        #expect(session.graded == 1)
        #expect(session.skipped == 1)
    }

    /// Undo puts the card back in front of the reader with its answer still showing — they have
    /// already seen it, and hiding it again would pretend the attempt had not happened.
    @Test func undoPutsTheCardBackWithItsAnswerStillShowing() {
        var session = session()
        session.reveal()
        let graded = session.current
        session.record(.graded(.again))
        #expect(session.current?.id != graded?.id)

        let restored = session.undoLast()
        // **The same card, a new attempt.** This asserted the same presentation *id* until
        // 2026-09-29, which is what let a re-grade after an undo collide with the voided event and
        // be answered with its result — see `undoGivesTheCardAfreshPresentationIdentity`.
        #expect(restored?.cardID == graded?.cardID)
        #expect(session.current?.cardID == graded?.cardID)
        #expect(session.current?.outcome == nil, "the grade is gone")
        #expect(session.current?.isRevealed == true, "and the answer is not un-seen")
        #expect(session.graded == 0)
    }

    /// **The card comes back as a new attempt, with a new identity.** The presentation's id is the
    /// grade's idempotency key: reusing it after an undo made the replacement grade collide with the
    /// voided one, and the ledger answered with the old result as though the new one had committed.
    @Test func undoGivesTheCardAfreshPresentationIdentity() {
        var session = session()
        let first = session.current
        session.record(.graded(.again))
        let restored = session.undoLast()
        #expect(restored?.cardID == first?.cardID, "the same card")
        #expect(restored?.id != first?.id, "and a new attempt at it")
    }

    /// Undo with nothing to undo is nothing, not a crash and not a silent state change.
    @Test func undoOnAnUntouchedSessionDoesNothing() {
        var session = session()
        let nothing = session.undoLast()
        #expect(nothing == nil)
        #expect(session.cursor == 0)
        #expect(session.graded == 0)
    }

    /// A finished batch takes no more outcomes: the surface is closed, and a late key press from a
    /// window that has not yet dismissed must not write anything.
    @Test func afinishedBatchTakesNothingMore() {
        var session = session(2)
        session.record(.graded(.good))
        session.record(.graded(.good))
        #expect(session.isFinished)
        #expect(session.current == nil)
        let late = session.record(.graded(.again))
        #expect(late == false)
        #expect(session.graded == 2)
        // And undo still works at the end, because the last grade is the likeliest mistake.
        let undone = session.undoLast()
        #expect(undone != nil)
        #expect(session.isFinished == false)
    }

    /// **The end of a batch never claims the work is done.** A sitting is bounded; the reader's debt
    /// is not, and a surface that hides the remainder teaches them it is smaller than it is.
    @Test func thesummaryKeepsTheBacklogVisible() {
        var session = session(2, beyond: 18)
        session.record(.graded(.good))
        session.record(.skipped)
        #expect(session.summary() == ReviewSession.Summary(graded: 1, skipped: 1, stillDue: 18))
    }

    /// **A card that left the sitting is counted by reason, is not answered, and Undo passes over it** (the
    /// final closing pass, finding 2): the reader did not do it, and taking it back would only have it leave
    /// again. The card restored is the reader's last answer, and the ones after it come round in order.
    @Test func aCardThatLeftIsCountedByReasonAndNotTakenBack() {
        var session = session(4, beyond: 2)
        session.record(.graded(.good))
        session.record(.left(.noLongerInStudy))
        session.record(.left(.paused))
        session.record(.left(.noLongerInStudy))
        #expect(session.isFinished)
        #expect(session.summary() == ReviewSession.Summary(
            graded: 1, skipped: 0, stillDue: 2, left: [.noLongerInStudy: 2, .paused: 1]))
        #expect(session.presentations.map(\.isAnswered) == [true, false, false, false])

        let undone = session.undoLast()
        #expect(undone?.cardID == session.presentations[0].cardID, "Undo took back what the sitting did")
        #expect(session.cursor == 0)
        session.record(.graded(.hard))
        #expect(session.current?.cardID == session.presentations[1].cardID,
                "the card after the one restored did not come round again")
        #expect(session.undoLast() != nil, "the reader's grade is still theirs to take back")
        #expect(session.undoLast() == nil, "nothing the reader did is left, so Undo has nothing")
    }

    /// The presentation carries the revision it was drawn at, so the grade can be committed against
    /// that and refused if anything wrote in between.
    @Test func apresentationRemembersTheRevisionItWasDrawnAt() {
        let card = UUID()
        let session = ReviewSession(startedAt: now, cards: [(id: card, revision: 7)])
        #expect(session.current?.cardID == card)
        #expect(session.current?.revision == 7)
    }

    /// **A card shown again at the revision it is at now is a new attempt at it** (closing pass after
    /// audit-fix round 3, #100). The app reads a card's revision with what it shows, and renews a card
    /// that moved since it was drawn: the same card at the revision read, its mode and its reveal kept,
    /// and a new identity — so a press made on the display before names the old one and is refused
    /// (WI-8). Nothing else in the sitting moves, and only the card in front of the reader is renewed.
    @Test func renewingTheCardInFrontKeepsItsPlaceAndTakesANewIdentity() {
        var session = ReviewSession(startedAt: now, drawn: [(id: UUID(), revision: 3, mode: .practice),
                                                             (id: UUID(), revision: 0, mode: .graded)])
        session.reveal()
        guard let drawn = session.current else {
            Issue.record("a sitting of two has nothing in front of the reader")
            return
        }
        let renewed = session.renew(drawn.id, revision: 4)
        #expect(renewed != nil, "the card in front of the reader was not renewed")
        #expect(renewed?.id != drawn.id, "a renewed card kept its identity, so a press on the old display still names it")
        #expect(session.current?.id == renewed?.id)
        #expect(session.current?.cardID == drawn.cardID, "a different card was put in front of the reader")
        #expect(session.current?.revision == 4)
        #expect(session.current?.mode == .practice, "the mode is the card's, as drawn")
        #expect(session.current?.isRevealed == true, "the answer the reader asked for was un-seen")
        #expect(session.current?.outcome == nil)
        #expect(session.cursor == 0)
        #expect(session.presentations.count == 2)
        #expect(session.presentations[1].revision == 0, "a card not in front was renewed")

        // **Only for the attempt in front of the reader**: the identity it had, or none at all.
        let late = session.renew(drawn.id, revision: 5)
        #expect(late == nil, "a renewal named an attempt that is no longer in front of the reader")
        #expect(session.current?.revision == 4)
        session.record(.graded(.good))
        session.record(.skipped)
        let after = session.renew(session.presentations[1].id, revision: 9)
        #expect(after == nil, "a finished sitting renewed a card")
        #expect(session.presentations[1].revision == 0)
    }

    /// Every presentation has its own identity, so two showings of one card are two attempts and a
    /// retry of one showing is the same attempt.
    @Test func everyPresentationHasItsOwnIdentity() {
        let card = UUID()
        let session = ReviewSession(startedAt: now, cards: [(id: card, revision: 0), (id: card, revision: 0)])
        #expect(session.presentations[0].id != session.presentations[1].id)
    }

    /// **"Forgot k" is said with its denominator, and practice is counted apart** (ADR-0036,
    /// review-module-plan §8.4). Of three scheduled answers two were Forgot: "forgot 2 of 3". The
    /// practice answers moved nothing, so a Forgot among them is counted on its own and never enters
    /// the scheduled figure — a practice Forgot folded into it would be a failure the schedule never
    /// heard about.
    @Test func theSummaryCountsForgottenAnswersWithTheirDenominator() {
        let cards = (0..<5).map { _ in UUID() }
        var session = ReviewSession(startedAt: now, drawn: [
            (id: cards[0], revision: 0, mode: .graded), (id: cards[1], revision: 0, mode: .graded),
            (id: cards[2], revision: 0, mode: .practice), (id: cards[3], revision: 0, mode: .graded),
            (id: cards[4], revision: 0, mode: .practice),
        ])
        session.record(.graded(.again))
        session.record(.graded(.good))
        session.record(.graded(.again))
        session.record(.graded(.again))
        session.record(.graded(.good))
        let summary = session.summary()
        #expect(summary.forgot == 2)
        #expect(summary.scheduled == 3, "the denominator is the scheduled answers, not every answer")
        #expect(summary.forgotInPractice == 1)
        #expect(summary.practised == 2)
        #expect(session.forgottenCards == [cards[0], cards[3]], "practice is not a scheduled Forgot")
    }

    /// **An answer taken back is not counted.** Undo voids the event and renews the presentation, so a
    /// Forgot the reader took back and answered again as Remembered is one Remembered.
    @Test func aForgetTakenBackIsNotCounted() {
        var session = session(1)
        session.record(.graded(.again))
        #expect(session.summary().forgot == 1)
        session.undoLast()
        #expect(session.summary().forgot == 0)
        #expect(session.forgottenCards.isEmpty)
        session.record(.graded(.good))
        #expect(session.summary().forgot == 0)
        #expect(session.summary().scheduled == 1)
        // Skipped and put-off cards were not answered at all: neither forgot nor reviewed.
        var put = self.session(2)
        put.record(.skipped)
        put.record(.postponed)
        #expect(put.summary().forgot == 0 && put.summary().scheduled == 0)
    }

    /// An empty batch is finished before it starts, and says so rather than drawing a card that is
    /// not there.
    @Test func anEmptyBatchIsFinishedAndSaysSo() {
        let session = session(0, beyond: 4)
        #expect(session.isFinished)
        #expect(session.current == nil)
        #expect(session.summary() == ReviewSession.Summary(graded: 0, skipped: 0, stillDue: 4))
    }
}
