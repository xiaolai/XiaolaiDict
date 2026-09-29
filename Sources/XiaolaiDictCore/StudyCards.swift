import Foundation

/// One question about one note, with its own schedule.
///
/// **A card is not a note.** A note is what the reader is learning; a card is one way of asking about
/// it. The second way — produce the word rather than recognise it — arrives with its own schedule and
/// must not inherit this one's, which is why the schedule lives here.
public struct StudyCard: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let noteID: UUID
    public let prompt: Prompt
    public let scheduled: ScheduledCard
    /// Eligibility, which is **not memory**. Pausing stops a card being asked; it does not stop time
    /// passing, and `S` is untouched by it.
    public let isPaused: Bool
    public let hiddenUntil: Date?
    /// Compare-and-swap. A grade computed against one state and committed over another is a lost
    /// update, and the review window's retries are exactly where that happens.
    public let revision: Int
    public let schedulerVersion: String
    public let createdAt: Date

    public enum Prompt: String, Codable, Sendable, CaseIterable {
        /// The reader's own sentence on the front, what the word meant there on the back.
        case meaning
    }

    public init(id: UUID = UUID(), noteID: UUID, prompt: Prompt = .meaning,
                scheduled: ScheduledCard = ScheduledCard(), isPaused: Bool = false,
                hiddenUntil: Date? = nil, revision: Int = 0,
                schedulerVersion: String = MemoryScheduler.version, createdAt: Date) {
        self.id = id
        self.noteID = noteID
        self.prompt = prompt
        self.scheduled = scheduled
        self.isPaused = isPaused
        self.hiddenUntil = hiddenUntil
        self.revision = revision
        self.schedulerVersion = schedulerVersion
        self.createdAt = createdAt
    }

    /// Whether this card's own schedule says it is due at `when`. **Eligibility is more than this** —
    /// the note must be enrolled and ready and in scope — so the queue is where the question is really
    /// answered, and this is only the half the card itself can see.
    public func isDue(at when: Date) -> Bool {
        guard !isPaused else { return false }
        if let hiddenUntil, hiddenUntil > when { return false }
        guard let due = scheduled.due else { return true }  // never reviewed: due as soon as it is ready
        return due <= when
    }
}

/// One deliberate recall attempt, as it happened.
///
/// **Immutable.** Undo marks it void and never deletes it: a history with holes cannot be replayed, and
/// replay is the only honest way to apply a parameter change to a reader's existing cards.
public struct ReviewEvent: Sendable, Equatable, Identifiable {
    /// The caller's idempotency key, and the row's identity. A retry after a failure nobody saw returns
    /// the first result rather than grading twice.
    public let id: UUID
    public let cardID: UUID
    public let grade: Grade
    public let reviewedAt: Date
    public let before: ScheduledCard
    public let after: ScheduledCard
    public let schedulerVersion: String
    public let retention: Double
    /// Which revision of the card this was applied to.
    public let cardRevision: Int
    /// Set when undone. **Excluded from every count** and from any retention figure.
    public let voidedAt: Date?

    public init(id: UUID = UUID(), cardID: UUID, grade: Grade, reviewedAt: Date,
                before: ScheduledCard, after: ScheduledCard,
                schedulerVersion: String = MemoryScheduler.version, retention: Double,
                cardRevision: Int, voidedAt: Date? = nil) {
        self.id = id
        self.cardID = cardID
        self.grade = grade
        self.reviewedAt = reviewedAt
        self.before = before
        self.after = after
        self.schedulerVersion = schedulerVersion
        self.retention = retention
        self.cardRevision = cardRevision
        self.voidedAt = voidedAt
    }

    public var isVoid: Bool { voidedAt != nil }
}

public enum ReviewError: Error, Equatable {
    /// The card was graded against a state it is no longer in. **Not retryable as-is**: the caller has
    /// to re-read the card, because the grade it collected was about a different question.
    case staleRevision(expected: Int, found: Int)
    case noSuchCard(UUID)
    /// The card cannot be asked — unenrolled, unconfirmed, no answer, paused, hidden, or its reading
    /// deleted. Checked again at commit, not only at presentation: a card can stop being askable while
    /// the reader is looking at it.
    case notEligible(UUID)
    case nothingToUndo(UUID)
    /// The event id has already been used and taken back. **Not the same as a retry**: a retry of a
    /// live event returns its result, while reusing the id of one the reader undid would answer a
    /// new attempt with the old, voided outcome and let the surface advance over a review that
    /// never happened. A fresh attempt needs a fresh id.
    case eventAlreadyVoided(UUID)
}
