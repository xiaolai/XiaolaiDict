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

    /// What a Selected sitting left out of the reader's selection, by reason, when it was drawn.
    /// `.none` for every other sitting, which gathers from the queue and so leaves nothing out.
    public let excluded: SittingExclusions

    /// A sitting whose every card is asked in one mode — `.graded` for Review, `.practice` for
    /// Practice.
    public init(id: UUID = UUID(), startedAt: Date, cards: [(id: UUID, revision: Int)],
                mode: ReviewEvent.Kind = .graded, beyondBatch: Int = 0, heldBack: Int = 0) {
        self.init(id: id, startedAt: startedAt,
                  drawn: cards.map { (id: $0.id, revision: $0.revision, mode: mode) },
                  beyondBatch: beyondBatch, heldBack: heldBack)
    }

    /// A sitting whose cards each carry the mode they were drawn in — a Selected sitting's (R4).
    public init(id: UUID = UUID(), startedAt: Date, drawn: [(id: UUID, revision: Int, mode: ReviewEvent.Kind)],
                beyondBatch: Int = 0, heldBack: Int = 0, excluded: SittingExclusions = .none) {
        self.id = id
        self.startedAt = startedAt
        self.presentations = drawn.map { Presentation(cardID: $0.id, revision: $0.revision, mode: $0.mode) }
        self.cursor = 0
        self.beyondBatch = beyondBatch
        self.heldBack = heldBack
        self.excluded = excluded
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
        /// **Which event a grade of it writes, fixed when it was drawn**: `.graded` goes to the
        /// scheduler, `.practice` is recorded and moves nothing (ADR-0036). Per card, because a
        /// Selected sitting holds both (R4) — and fixed, because a card that comes due while the
        /// reader is looking at it was drawn as practice and the surface told them so.
        public let mode: ReviewEvent.Kind
        /// **Per presentation, never persisted.** A review surface that remembered the answer was
        /// shown would show it again, and a card whose answer is already on screen is not a question.
        public fileprivate(set) var isRevealed: Bool = false
        public fileprivate(set) var outcome: Outcome?

        init(id: UUID = UUID(), cardID: UUID, revision: Int, mode: ReviewEvent.Kind = .graded) {
            self.id = id
            self.cardID = cardID
            self.revision = revision
            self.mode = mode
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
            /// **It left the sitting unanswered, because it can no longer be asked** — archived, paused,
            /// put off or no longer ready since the sitting was drawn (the final closing pass, finding 2).
            /// No grade of it would ever be taken, so holding it was a card refused at every press for
            /// good. **Not the reader's answer**: Undo passes over it, and nothing about it was written.
            case left(Departure)
        }

        /// Whether the reader answered it — graded, skipped or put off. **A card that left is not
        /// answered**: Undo takes back what the reader did, and the sitting did this.
        public var isAnswered: Bool {
            switch outcome {
            case .graded?, .skipped?, .postponed?: true
            case .left?, nil: false
            }
        }
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
    /// **The reader's most recent outcome**: a card that left the sitting is passed over, not taken back —
    /// the reader did not do that, and taking it back would only have it leave again. The cards after the
    /// one restored come round again in order, and each is asked again whether it can be asked.
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
        // the attempt, and the revision it will be committed against, are not. **The mode is the
        // card's, as drawn**: a practice card brought back and answered again is still practice.
        var renewed = Presentation(cardID: previous.cardID, revision: revision ?? previous.revision,
                                   mode: previous.mode)
        // The answer stays shown — the reader has already seen it, and hiding it again would
        // pretend the attempt had not happened.
        renewed.isRevealed = previous.isRevealed
        presentations[index] = renewed
        cursor = index
        return renewed
    }

    /// **The card in front of the reader, shown again at the revision it is at now.**
    ///
    /// A sitting takes every card's revision when it is planned, and a grade is committed against it.
    /// A card written to since — its answer edited in Saved while the sitting was held — was refused as
    /// stale at every attempt for the rest of the sitting, whatever the reader had been shown (closing
    /// pass after audit-fix round 3). The app layer reads the revision together with what it shows of
    /// the card, and asks for this where the two differ; this type holds no ledger and cannot.
    ///
    /// **A new identity**, as `undoLast` gives one: a press made on the display before names the old
    /// showing and is refused (WI-8), so nothing the reader did not see can be graded at the new
    /// revision — and the old id, never written, is not reused. The card's mode and reveal are kept.
    /// Nil, and nothing changed, unless `attempt` is the presentation in front of the reader.
    @discardableResult
    public mutating func renew(_ attempt: UUID, revision: Int) -> Presentation? {
        guard let index = liveIndex, presentations[index].id == attempt else { return nil }
        let previous = presentations[index]
        var renewed = Presentation(cardID: previous.cardID, revision: revision, mode: previous.mode)
        renewed.isRevealed = previous.isRevealed
        presentations[index] = renewed
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
    public func summary() -> Summary {
        Summary(graded: graded, skipped: skipped, stillDue: beyondBatch, heldBack: heldBack,
                postponed: postponed,
                wasPractice: !presentations.isEmpty && presentations.allSatisfy { $0.mode == .practice },
                practised: presentations.count {
                    if case .graded = $0.outcome { $0.mode == .practice } else { false }
                },
                skippedPractice: presentations.count { $0.outcome == .skipped && $0.mode == .practice },
                excluded: excluded,
                forgot: presentations.count { $0.outcome == .graded(.again) && $0.mode == .graded },
                forgotInPractice: presentations.count { $0.outcome == .graded(.again) && $0.mode == .practice },
                left: presentations.reduce(into: [:]) { left, presentation in
                    if case .left(let departure)? = presentation.outcome { left[departure, default: 0] += 1 }
                })
    }

    /// **The cards this sitting's scheduled answers said were forgotten**, in the order they were asked
    /// — what "Keeps slipping" is chosen from. Practice is not among them: it moved nothing and enters
    /// no figure (ADR-0036). An answer taken back is not either: undo renews its presentation, so only
    /// what stands is here.
    public var forgottenCards: [UUID] {
        presentations.filter { $0.outcome == .graded(.again) && $0.mode == .graded }.map(\.cardID)
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
        /// Whether every card of the sitting was drawn as practice. **Read off the presentations**,
        /// not passed in: a Selected sitting holds both modes, and a sitting-wide flag beside
        /// per-card modes is two answers to one question.
        public let wasPractice: Bool
        /// Of `graded`, the answers given in practice mode: recorded, and nothing scheduled by them.
        public let practised: Int
        /// Of `skipped`, the cards drawn as practice. **Not still due**: they were not due when drawn.
        public let skippedPractice: Int
        /// What a Selected sitting left out of the reader's selection, by reason.
        public let excluded: SittingExclusions
        /// Of the scheduled answers, how many were Forgot. **Said over `scheduled`**, never alone and
        /// never as a percentage (ADR-0036): "forgot 2 of 3".
        public let forgot: Int
        /// Forgot answers given in practice. **Counted apart and in no figure**: practice moved nothing,
        /// and a failure the schedule never heard about must not read as one it did.
        public let forgotInPractice: Int
        /// Cards that left the sitting because they can no longer be asked, by reason. **Not skipped and
        /// not due**: nothing the reader does in Review brings them back, and the end says what would.
        public let left: [Departure: Int]

        public init(graded: Int, skipped: Int, stillDue: Int, heldBack: Int = 0,
                    postponed: Int = 0, wasPractice: Bool = false, practised: Int = 0,
                    skippedPractice: Int = 0, excluded: SittingExclusions = .none,
                    forgot: Int = 0, forgotInPractice: Int = 0, left: [Departure: Int] = [:]) {
            self.graded = graded
            self.skipped = skipped
            self.stillDue = stillDue
            self.heldBack = heldBack
            self.postponed = postponed
            self.wasPractice = wasPractice
            self.practised = practised
            self.skippedPractice = skippedPractice
            self.excluded = excluded
            self.forgot = forgot
            self.forgotInPractice = forgotInPractice
            self.left = left
        }

        /// Skipped cards that were due when drawn, and still are.
        public var skippedStillDue: Int { skipped - skippedPractice }

        /// The answers the scheduler took — `forgot`'s denominator. Practice answers are not among
        /// them, and neither is a skip or a put-off, which answered nothing.
        public var scheduled: Int { graded - practised }
    }
}

/// **Why a card left a sitting unanswered**: what stands between it and being asked now, and so what
/// the reader would do about it in Saved. Each is counted on the end of the sitting by itself, because
/// each has its own remedy — the same reason `SittingExclusions` keeps its reasons apart.
public enum Departure: String, Sendable, Equatable, Hashable, CaseIterable {
    /// Archived, removed from study, or no longer wanted — no enrolled note is behind it any more.
    case noLongerInStudy
    /// Paused.
    case paused
    /// Put off past now — "not today" — elsewhere.
    case putOff
    /// Its note needs the reader first: its reading deleted, its answer gone, its meaning unconfirmed.
    case notReady
}
