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

    /// **Decoded through the initialiser, so the clamp is not optional.** Synthesised `Codable`
    /// assigns the stored properties directly, so a persisted or hand-written `cutoffHour` of 99
    /// came back as 99 and `start(containing:)` answered a date three days out.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(timeZone: try values.decode(TimeZone.self, forKey: .timeZone),
                  cutoffHour: try values.decode(Int.self, forKey: .cutoffHour))
    }

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
        let calendar = self.calendar
        // **Built from the day's own components, never from midnight plus seconds.** Adding
        // `4 * 3600` is real-time arithmetic across a local-time boundary: on a spring-forward
        // day an hour is missing, so it lands at 05:00, and on a fall-back day an hour repeats,
        // so it lands at 03:00. A reader in a DST zone had a study day that began an hour early
        // or an hour late, twice a year — and the new-card allowance turns over on it.
        //
        // `date(bySettingHour:)` is still not used: it searches forward and would answer
        // *tomorrow's* cutoff for a time before today's, which is the opposite of what is wanted.
        var parts = calendar.dateComponents([.year, .month, .day], from: when)
        parts.hour = cutoffHour
        // Nil is unreachable for a Gregorian calendar and a clamped hour; falling back to the old
        // arithmetic keeps a wrong-by-an-hour answer rather than inventing one.
        guard let today = calendar.date(from: parts) else {
            return calendar.startOfDay(for: when).addingTimeInterval(TimeInterval(cutoffHour) * 3_600)
        }
        if when >= today { return today }
        // **One calendar day back, not 86,400 seconds**, for the same reason.
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
    }

    /// The instant the study day *after* the one containing `when` begins.
    ///
    /// Named here rather than left to callers, because "tomorrow" spelled as `+ 86_400` is the
    /// same defect as the one above: `postpone` used it, so a card put off on a fall-back evening
    /// came back an hour early.
    public func startOfNextDay(containing when: Date) -> Date {
        let today = start(containing: when)
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
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
