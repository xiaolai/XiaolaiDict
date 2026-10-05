import Foundation

/// **After a confirmation that showed the answer, the card waits — an experiment, not a rule.**
///
/// review-module-plan §8.3(c), R1c: **the reader's option since 2026-10-05**, off by default — a switch
/// and a minimum chosen in Settings › General › Review. The app runs it only where the reader's
/// defaults switch it on.
///
/// What FSRS does and does not say: a new card's first grade sets its stability from the grade alone,
/// so a delay before that grade changes nothing in the schedule. Its only possible effect is whether
/// that first grade is *retrieval* or *recognition* of a meaning read seconds ago — a learning-science
/// argument, not a consequence of the scheduler. The evidence that would settle it is the Again rate at
/// the **second** graded review, compared between the two arms; that is what the arm is for.
///
/// The rule: hidden until the later of the next study day and a minimum delay. Without the minimum a
/// confirmation at 03:59:59 hides the card for one second, because the study day ends then.
public struct ConfirmationCooldown: Sendable, Equatable {
    /// **8 h, and a guess.** Nothing here has measured how long a meaning read on the back of a card
    /// stays recognisable rather than recallable; this is a placeholder for an experiment, named so
    /// that nobody mistakes it for a finding.
    public static let placeholderMinimumDelay: TimeInterval = 8 * 60 * 60

    /// **The minimums a reader may choose**: 4, 8 and 12 hours, the placeholder in the middle. Each is
    /// a guess like the placeholder; a small set rather than a slider, because nothing measured says
    /// one minute more or less matters.
    public static let minimumDelayChoices: [TimeInterval] = [4 * 60 * 60, placeholderMinimumDelay, 12 * 60 * 60]

    /// **The minimum a stored value means**: one of the choices as it is, anything else — absent, off
    /// the menu, not a duration — the placeholder. The one rule the Settings picker and the confirmation
    /// both read, so the picker never shows a minimum the confirmation is not using.
    public static func minimumDelay(stored: TimeInterval?) -> TimeInterval {
        guard let stored, minimumDelayChoices.contains(stored) else { return placeholderMinimumDelay }
        return stored
    }

    public let studyDay: StudyDay
    public let minimumDelay: TimeInterval

    public init(studyDay: StudyDay = .standard, minimumDelay: TimeInterval = placeholderMinimumDelay) {
        self.studyDay = studyDay
        self.minimumDelay = minimumDelay
    }

    /// What the confirming surface had on screen. **Two cases rather than a flag**, so a call site
    /// says which surface it is instead of passing a `true` nobody can read.
    public enum Exposure: Sendable, Equatable {
        /// The meaning was displayed beside the control the reader pressed.
        case answerShown
        /// It may never have been opened — a list of rows confirmed in bulk.
        case answerNotShown
    }

    /// Which half of the experiment a note is in.
    enum Arm: Sendable, Equatable, CaseIterable {
        case cooldown
        case control
    }

    /// **The parity of the id's last byte: odd waits, even does not.** Deterministic and stored
    /// nowhere — the comparison can be run later, on any ledger, from the ids alone — and the last
    /// byte of a random UUID is random, so the two arms are halves.
    static func arm(of noteID: UUID) -> Arm {
        noteID.uuid.15 & 1 == 1 ? .cooldown : .control
    }

    /// The rule's own arithmetic: the later of the next study day and `minimumDelay` from `confirmedAt`.
    func hiddenUntil(confirmedAt: Date) -> Date {
        max(studyDay.startOfNextDay(containing: confirmedAt), confirmedAt.addingTimeInterval(minimumDelay))
    }

    /// **The whole decision, for one confirmation.** Nil hides nothing: a surface that did not show
    /// the answer, or a note in the control arm.
    public func hiddenUntil(noteID: UUID, confirmedAt: Date, exposure: Exposure) -> Date? {
        guard exposure == .answerShown, Self.arm(of: noteID) == .cooldown else { return nil }
        return hiddenUntil(confirmedAt: confirmedAt)
    }
}
