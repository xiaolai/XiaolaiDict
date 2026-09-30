import Foundation

/// **One sitting: a finite batch, a cursor, and what the reader has done with each card.**
///
/// Pure. It holds no ledger and commits nothing — the app layer writes the grade and then tells this
/// what happened. Keeping the rules here is what makes them testable without a window, and the rules
/// are the part that goes wrong: a reveal that grades, a grade that lands twice, an advance that
/// happens before the write.
///
/// **A batch bounds a sitting, not the reader's debt.** Ten presentations is how much is offered now;
/// the due work that does not fit stays due and stays visible. Nothing here moves a due date to make a
/// backlog look smaller.
public struct ReviewSession: Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date
    /// Fixed at the start, in the order the queue gave. **Stable**, because a presentation the reader
    /// is looking at must not be renumbered by anything happening behind it.
    public private(set) var presentations: [Presentation]
    /// Which presentation is in front of the reader. Equal to `presentations.count` when the batch is
    /// finished.
    public private(set) var cursor: Int

    /// How many cards were eligible beyond this batch when it was drawn.
    ///
    /// **Carried so the end of a batch can tell the truth.** "All done today" over a backlog is the
    /// one thing a review surface must never say; this is what lets it say "18 more due" instead.
    public let beyondBatch: Int

    /// New cards today's allowance is holding back, when this batch was drawn.
    ///
    /// **Separate from `beyondBatch`, because they are different sentences.** Work that did not fit
    /// is still due now; work the allowance is holding is not late at all. Merging them would make
    /// the surface offer "review another batch" over cards no batch today will contain.
    public let heldBack: Int

    public init(id: UUID = UUID(), startedAt: Date, cards: [(id: UUID, revision: Int)],
                beyondBatch: Int = 0, heldBack: Int = 0) {
        self.id = id
        self.startedAt = startedAt
        self.presentations = cards.map { Presentation(cardID: $0.id, revision: $0.revision) }
        self.cursor = 0
        self.beyondBatch = beyondBatch
        self.heldBack = heldBack
    }

    /// One card, once, as it was drawn.
    public struct Presentation: Sendable, Equatable, Identifiable {
        /// Stable for this showing. The grade names it, so a retry of the same attempt is the same
        /// attempt and a second attempt at the same card is not.
        public let id: UUID
        public let cardID: UUID
        /// The card's revision when it was drawn. The grade is committed against this, so anything
        /// that wrote in between refuses the write rather than overwriting it.
        public let revision: Int
        /// **Per presentation, never persisted.** A review surface that remembered the answer was
        /// shown would show it again, and a card whose answer is already on screen is not a question.
        public fileprivate(set) var isRevealed: Bool = false
        public fileprivate(set) var outcome: Outcome?

        init(id: UUID = UUID(), cardID: UUID, revision: Int) {
            self.id = id
            self.cardID = cardID
            self.revision = revision
        }

        public enum Outcome: Sendable, Equatable {
            /// A deliberate grade, committed. **The only thing that moves a schedule.**
            case graded(Grade)
            /// Put aside for this sitting. Consumes no grade and no first-introduction budget, and
            /// the card stays exactly as due as it was.
            case skipped
            /// Put out of the way until the next study day (R05). **Not a skip**: a skipped card is
            /// still due today and the next batch can have it, and this one is gone until tomorrow.
            /// The schedule is untouched — "not now" is not a statement about memory.
            case postponed
        }

        public var isAnswered: Bool { outcome != nil }
    }

    // MARK: - What the reader does

    /// Shows the answer. **Never grades**: a reader who reveals has not said whether they knew it, and
    /// inferring "forgot" from a reveal would record a failure they did not report.
    public mutating func reveal() {
        guard let index = liveIndex else { return }
        presentations[index].isRevealed = true
    }

    /// Records what the caller has already committed, and moves on.
    ///
    /// **Called after the write, not before.** The session advancing before the ledger has the grade
    /// is how a reader ends a batch believing ten reviews are saved when nine are: the UI must not run
    /// ahead of the durable result.
    ///
    /// Refuses a second outcome for the same presentation, so a double press cannot grade twice even
    /// if the ledger's idempotency key were mishandled.
    ///
    /// **`for` names the attempt the outcome belongs to, and is checked against what is in front
    /// of the reader.** Every outcome but a skip is written to the ledger first and recorded on
    /// the way back, so two presses overlap: both completions reached here and each advanced the
    /// sitting, taking a card the reader was never shown. Measured on "Not today", which has no
    /// commit guard because the button is only disabled while a *grade* is in flight. The second
    /// completion now finds a different presentation current and does nothing.
    ///
    /// Nil is for a caller with no attempt to name — a skip, which is synchronous and cannot be
    /// overtaken by anything.
    @discardableResult
    public mutating func record(_ outcome: Presentation.Outcome, for attempt: UUID? = nil) -> Bool {
        guard let index = liveIndex else { return false }
        if let attempt, presentations[index].id != attempt { return false }
        presentations[index].outcome = outcome
        cursor = index + 1
        return true
    }

    /// Takes back the most recent outcome and puts that card back in front of the reader.
    ///
    /// **The session's half of undo.** The ledger's half is voiding the event; this restores the
    /// cursor and clears the outcome, and the answer is shown again because the reader has already
    /// seen it — hiding it now would pretend the attempt had not happened.
    /// `revision` is the card's revision **after** the ledger's half of the undo, or nil where no
    /// ledger write happened (a skip, a postponement).
    ///
    /// **An undo is a write, so the card has moved twice by now** — once for the grade, once for
    /// taking it back. Keeping the revision the card was *drawn* at meant the reader's next answer
    /// to the restored card was refused as stale: they had deliberately gone back to a card and
    /// then could not answer it. Nothing here can compute the new number — this type holds no
    /// ledger — so the caller that did the write supplies it.
    @discardableResult
    public mutating func undoLast(revision: Int? = nil) -> Presentation? {
        guard let index = presentations.lastIndex(where: { $0.isAnswered }) else { return nil }
        let previous = presentations[index]
        // **A new identity for a new attempt.** The presentation's id is the grade's idempotency
        // key: reusing it after an undo made the replacement collide with the voided event, and the
        // ledger answered the new attempt with the old, taken-back result. The card is the same;
        // the attempt, and the revision it will be committed against, are not.
        var renewed = Presentation(cardID: previous.cardID, revision: revision ?? previous.revision)
        // The answer stays shown — the reader has already seen it, and hiding it again would
        // pretend the attempt had not happened.
        renewed.isRevealed = previous.isRevealed
        presentations[index] = renewed
        cursor = index
        return renewed
    }

    // MARK: - What the surface asks

    /// The card in front of the reader, or nil when the batch is finished.
    public var current: Presentation? { liveIndex.map { presentations[$0] } }

    private var liveIndex: Int? {
        guard cursor >= 0, cursor < presentations.count else { return nil }
        return cursor
    }

    public var isFinished: Bool { liveIndex == nil }

    /// How many of the batch have been graded — **not** how many were shown. A skip is not a review.
    public var graded: Int {
        presentations.count { if case .graded = $0.outcome { return true } else { return false } }
    }

    public var skipped: Int {
        presentations.count { $0.outcome == .skipped }
    }

    public var postponed: Int {
        presentations.count { $0.outcome == .postponed }
    }

    /// How many are still to come in this batch.
    public var remaining: Int { presentations.count - (liveIndex ?? presentations.count) }

    /// What the end of the batch may claim.
    ///
    /// **Never "all done".** A batch is a sitting; the work beyond it is still there, and a surface
    /// that hides it teaches the reader their backlog is smaller than it is.
    public func summary(wasPractice: Bool = false) -> Summary {
        Summary(graded: graded, skipped: skipped, stillDue: beyondBatch, heldBack: heldBack,
                postponed: postponed, wasPractice: wasPractice)
    }

    public struct Summary: Sendable, Equatable {
        public let graded: Int
        public let skipped: Int
        /// Eligible cards that did not fit in this batch, as counted when it was drawn. **A floor, not
        /// a promise**: time has passed, and more may have come due since.
        public let stillDue: Int
        /// New cards the daily allowance is holding for tomorrow. **Not part of `stillDue`**: they
        /// are not late, and nothing the reader does today will be offered them.
        public let heldBack: Int
        /// Put off until the next study day. **Its own count**, because a skipped card is still
        /// due now and a postponed one is not, and one number for both would say neither.
        public let postponed: Int
        /// Whether this was a practice sitting. **Carried, because the words differ**: practice
        /// includes cards that are not due, so "skipped, still due" is a claim about the
        /// schedule a practice batch cannot make.
        public let wasPractice: Bool

        public init(graded: Int, skipped: Int, stillDue: Int, heldBack: Int = 0,
                    postponed: Int = 0, wasPractice: Bool = false) {
            self.graded = graded
            self.skipped = skipped
            self.stillDue = stillDue
            self.heldBack = heldBack
            self.postponed = postponed
            self.wasPractice = wasPractice
        }
    }
}
