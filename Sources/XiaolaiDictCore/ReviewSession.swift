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

    public init(id: UUID = UUID(), startedAt: Date, cards: [(id: UUID, revision: Int)],
                beyondBatch: Int = 0) {
        self.id = id
        self.startedAt = startedAt
        self.presentations = cards.map { Presentation(cardID: $0.id, revision: $0.revision) }
        self.cursor = 0
        self.beyondBatch = beyondBatch
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
    @discardableResult
    public mutating func record(_ outcome: Presentation.Outcome) -> Bool {
        guard let index = liveIndex else { return false }
        presentations[index].outcome = outcome
        cursor = index + 1
        return true
    }

    /// Takes back the most recent outcome and puts that card back in front of the reader.
    ///
    /// **The session's half of undo.** The ledger's half is voiding the event; this restores the
    /// cursor and clears the outcome, and the answer is shown again because the reader has already
    /// seen it — hiding it now would pretend the attempt had not happened.
    @discardableResult
    public mutating func undoLast() -> Presentation? {
        guard let index = presentations.lastIndex(where: { $0.isAnswered }) else { return nil }
        presentations[index].outcome = nil
        cursor = index
        return presentations[index]
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

    /// How many are still to come in this batch.
    public var remaining: Int { presentations.count - (liveIndex ?? presentations.count) }

    /// What the end of the batch may claim.
    ///
    /// **Never "all done".** A batch is a sitting; the work beyond it is still there, and a surface
    /// that hides it teaches the reader their backlog is smaller than it is.
    public var summary: Summary {
        Summary(graded: graded, skipped: skipped, stillDue: beyondBatch)
    }

    public struct Summary: Sendable, Equatable {
        public let graded: Int
        public let skipped: Int
        /// Eligible cards that did not fit in this batch, as counted when it was drawn. **A floor, not
        /// a promise**: time has passed, and more may have come due since.
        public let stillDue: Int

        public init(graded: Int, skipped: Int, stillDue: Int) {
            self.graded = graded
            self.skipped = skipped
            self.stillDue = stillDue
        }
    }
}
