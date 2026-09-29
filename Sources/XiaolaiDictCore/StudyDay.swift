import Foundation

/// **When one day of studying ends and the next begins.**
///
/// Not midnight. A reader who reviews at half past midnight is finishing the day they have been
/// awake for, and a cutoff at 00:00 hands them a second day's worth of new cards at the exact moment
/// they are least able to judge that. Anki's default is 04:00 and so is this one.
///
/// **The policy is frozen into a session, not read at every question.** A reader who crosses a
/// timezone mid-sitting must not have the day boundary move under them — and the allowance must not
/// be replenished twice in one real day by travelling or by changing the setting, which is what
/// recomputing it from the current timezone on every read would do.
public struct StudyDay: Sendable, Equatable, Codable {
    public let timeZone: TimeZone
    /// The hour a study day starts, local. 4 means 04:00.
    public let cutoffHour: Int

    /// The hour every part of this app means by "a day", unless it was told otherwise. **One
    /// spelling**: SQL counting distinct days of failure and Swift counting today's introductions
    /// must not disagree about when yesterday ended.
    public static let defaultCutoffHour = 4

    /// The default: the reader's own timezone, and Anki's cutoff.
    public static var standard: StudyDay { StudyDay(timeZone: .current, cutoffHour: defaultCutoffHour) }

    public init(timeZone: TimeZone = .current, cutoffHour: Int = StudyDay.defaultCutoffHour) {
        self.timeZone = timeZone
        // A cutoff outside the clock is a setting nobody can act on; clamped rather than refused,
        // because this is a preference and not a boundary anything hostile reaches.
        self.cutoffHour = min(23, max(0, cutoffHour))
    }

    /// The instant the study day containing `when` began.
    ///
    /// **Before the cutoff belongs to yesterday.** 01:00 on Tuesday is Monday's study day, which is
    /// the whole point of a cutoff that is not midnight.
    public func start(containing when: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let midnight = calendar.startOfDay(for: when)
        // `date(bySettingHour:)` is deliberately not used: it searches forward and would answer
        // *tomorrow's* cutoff for a time before today's, which is the opposite of what is wanted.
        let cutoff = midnight.addingTimeInterval(TimeInterval(cutoffHour) * 3_600)
        return when >= cutoff ? cutoff : cutoff.addingTimeInterval(-86_400)
    }
}

extension Ledger {
    /// How many cards were introduced in the study day that began at `since`.
    ///
    /// **A first introduction is a card's first graded review**, which is the only event that turns
    /// a `new` card into a scheduled one. Practice cannot introduce anything — it never touches a
    /// card with no memory state — and a voided introduction is not one, so undoing a first review
    /// gives the allowance back without anything having to remember to.
    public func introductions(since: Date, dictionary: String?) throws -> Int {
        var bind: [SQLiteValue] = [.real(since.timeIntervalSince1970)]
        var scope = ""
        if let dictionary {
            scope = "AND n.dictionary = ?2"
            bind.append(.text(dictionary))
        }
        var count = 0
        try run("""
            SELECT COUNT(*) FROM review_events e
            JOIN study_cards c ON c.id = e.card_id
            JOIN study_notes n ON n.id = c.note_id
            WHERE e.reviewed_at >= ?1
              AND e.before_phase = 'new'
              AND e.kind = 'graded'
              AND e.voided_at IS NULL
              \(scope)
            """, bind: bind) { count = $0.integer(0) }
        return count
    }
}
