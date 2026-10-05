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
        studyDate(containing: when, in: calendar).start
    }

    /// The instant the study day *after* the one containing `when` begins.
    ///
    /// Named here rather than left to callers, because "tomorrow" spelled as `+ 86_400` is the
    /// same defect as the one above: `postpone` used it, so a card put off on a fall-back evening
    /// came back an hour early.
    public func startOfNextDay(containing when: Date) -> Date {
        let calendar = self.calendar
        let today = studyDate(containing: when, in: calendar)
        return today.date.flatMap { cutoff(of: $0, plus: 1, in: calendar) } ?? today.start.addingTimeInterval(86_400)
    }

    /// The calendar date a study day is named by — nil only where the calendar could not name it, which
    /// a Gregorian calendar never does — and the instant it began.
    ///
    /// **Built from the day's own components, never from midnight plus seconds.** Adding
    /// `4 * 3600` is real-time arithmetic across a local-time boundary: on a spring-forward
    /// day an hour is missing, so it lands at 05:00, and on a fall-back day an hour repeats,
    /// so it lands at 03:00. A reader in a DST zone had a study day that began an hour early
    /// or an hour late, twice a year — and the new-card allowance turns over on it.
    ///
    /// **And each neighbour from its own date, never by stepping from this day's instant.** A cutoff
    /// the clock skips resolves forward — New York's 02:00 on 2026-03-08 is 03:00 EDT — and a calendar
    /// day added to *that* keeps the resolved hour: the 7th began at 03:00 when asked from the 8th and
    /// at 02:00 when asked from the 7th, and the 9th at 03:00 (audit-fix round 1). One day, one start.
    ///
    /// `date(bySettingHour:)` is still not used: it searches forward and would answer *tomorrow's*
    /// cutoff for a time before today's, which is the opposite of what is wanted.
    private func studyDate(containing when: Date, in calendar: Calendar) -> (date: DateComponents?, start: Date) {
        let date = calendar.dateComponents([.year, .month, .day], from: when)
        // Nil is unreachable for a Gregorian calendar and a clamped hour; falling back to the old
        // arithmetic keeps a wrong-by-an-hour answer rather than inventing one.
        guard let today = cutoff(of: date, plus: 0, in: calendar) else {
            return (date, calendar.startOfDay(for: when).addingTimeInterval(TimeInterval(cutoffHour) * 3_600))
        }
        if when >= today { return (date, today) }
        guard let before = shifted(date, by: -1, in: calendar), let start = cutoff(of: before, plus: 0, in: calendar) else {
            return (nil, today.addingTimeInterval(-86_400))
        }
        return (before, start)
    }

    /// The cutoff on the calendar date `days` after `date`, from that date's own components.
    private func cutoff(of date: DateComponents, plus days: Int, in calendar: Calendar) -> Date? {
        guard var parts = days == 0 ? date : shifted(date, by: days, in: calendar) else { return nil }
        parts.hour = cutoffHour
        return calendar.date(from: parts)
    }

    /// The calendar date `days` after `date`. **Stepped at noon**, an hour no zone's clock skips, so
    /// the step is a date's and never a transition's.
    private func shifted(_ date: DateComponents, by days: Int, in calendar: Calendar) -> DateComponents? {
        var noon = date
        noon.hour = 12
        guard let anchor = calendar.date(from: noon),
              let moved = calendar.date(byAdding: .day, value: days, to: anchor) else { return nil }
        return calendar.dateComponents([.year, .month, .day], from: moved)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
