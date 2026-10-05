import Foundation

/// Which of a study day's two reminders: the one the reader set a time for, or the one they asked for.
public enum ReminderKind: String, Sendable, Hashable, CaseIterable, Codable {
    /// Unrequested: at the reader's chosen time, at most once a study day.
    case daily
    /// Requested: Later, from a delivered reminder, at most once a study day.
    case later
}

/// **A study day, named by the calendar date it starts on** in the planning zone — `2026-10-31` is the
/// study day from 04:00 on the 31st to 04:00 on 1 November, and its 01:30 reminder fires on the 1st.
///
/// A date, not an instant: a reader who changes zone keeps the name of the day they are in, so the
/// log's "at most one a day" still holds for it. Validated on the way in — 30 February is refused, not
/// rolled over — because it is also read back from identifiers the system hands over.
public struct ReminderDay: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        // Four digits, so the identifier has one spelling; a date the calendar has.
        guard (1...9_999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let noon = Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
        else { return nil }
        let back = Self.utc.dateComponents([.year, .month, .day], from: noon)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// **The study day containing `instant`**, named by the date it began on: 01:30 on the 21st is the
    /// 20th's.
    public init(studyDayContaining instant: Date, in studyDay: StudyDay) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = studyDay.timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: studyDay.start(containing: instant))
        // A Gregorian calendar always answers these three; the fallback is the reference date's own
        // name, never a date invented from a half-answer.
        self = parts.year.flatMap { year in
            parts.month.flatMap { month in parts.day.flatMap { ReminderDay(year: year, month: month, day: $0) } }
        } ?? Self.reference
    }

    /// 2001-01-01, the reference date's own day.
    private static let reference = ReminderDay(validYear: 2_001, month: 1, day: 1)

    private init(validYear year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// `yyyy-MM-dd`, zero-padded, in ASCII digits: the identifier's spelling, and nothing a reader sees.
    public var description: String {
        "\(Self.padded(year, 4))-\(Self.padded(month, 2))-\(Self.padded(day, 2))"
    }

    /// **Read back strictly**: exactly `yyyy-MM-dd` in ASCII digits, and a date the calendar has.
    /// `Int("+026")` is 26 and `Character("２").isNumber` is true, so neither is asked.
    init?(_ text: Substring) {
        let characters = Array(text)
        guard characters.count == 10, characters[4] == "-", characters[7] == "-" else { return nil }
        let digits = characters.enumerated().filter { $0.offset != 4 && $0.offset != 7 }.map(\.element)
        guard digits.allSatisfy({ ("0"..."9").contains($0) && $0.isASCII }),
              let year = Int(String(characters[0..<4])), let month = Int(String(characters[5..<7])),
              let day = Int(String(characters[8..<10]))
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The day `days` calendar days on — a calendar date, so no daylight-saving change can move it.
    func adding(days: Int) -> ReminderDay? {
        guard let noon = Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12)),
              let moved = Self.utc.date(byAdding: .day, value: days, to: noon)
        else { return nil }
        let parts = Self.utc.dateComponents([.year, .month, .day], from: moved)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return ReminderDay(year: year, month: month, day: day)
    }

    /// When this study day begins: its cutoff on its own date, in the study day's zone, as `StudyDay`
    /// itself names it — so a cutoff the clock skips that night lands where `StudyDay` lands it.
    func start(in studyDay: StudyDay) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = studyDay.timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: studyDay.cutoffHour))
            .map(studyDay.start(containing:))
    }

    public static func < (lhs: ReminderDay, rhs: ReminderDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Calendar dates are compared and counted in UTC, where no day is 23 or 25 hours long.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

extension ReminderDay: Codable {
    /// As its identifier spells it.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let day = ReminderDay(Substring(text)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "expected a day spelled yyyy-MM-dd"))
        }
        self = day
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(description)
    }
}

/// **One reminder's identity: a study day and a kind.** Its identifier is what the system knows it by.
public struct ReminderKey: Sendable, Hashable, Comparable {
    public let day: ReminderDay
    public let kind: ReminderKind

    /// **Everything this app asks the system to deliver is named under it, and nothing else is
    /// touched** — the reconciler ignores every other identifier it is shown.
    public static let prefix = "review."

    public init(day: ReminderDay, kind: ReminderKind) {
        self.day = day
        self.kind = kind
    }

    /// **An identifier the system handed back, read strictly** — `review.<yyyy-MM-dd>` or
    /// `review.<yyyy-MM-dd>.later`, one spelling each. Anything else, under the prefix or not, is no key.
    public init?(identifier: String) {
        guard identifier.hasPrefix(Self.prefix) else { return nil }
        let rest = identifier.dropFirst(Self.prefix.count)
        let laterSuffix = ".\(ReminderKind.later.rawValue)"
        let kind: ReminderKind = rest.hasSuffix(laterSuffix) ? .later : .daily
        let date = kind == .later ? rest.dropLast(laterSuffix.count) : rest
        guard let day = ReminderDay(date) else { return nil }
        self.init(day: day, kind: kind)
    }

    /// `review.<yyyy-MM-dd>` for the daily reminder, `review.<yyyy-MM-dd>.later` for Later.
    public var identifier: String {
        switch kind {
        case .daily: "\(Self.prefix)\(day)"
        case .later: "\(Self.prefix)\(day).\(kind.rawValue)"
        }
    }

    public static func < (lhs: ReminderKey, rhs: ReminderKey) -> Bool {
        lhs.day != rhs.day ? lhs.day < rhs.day : (lhs.kind == .daily && rhs.kind == .later)
    }
}

/// **What a reminder says**, by type — **no case carries a `String`**, so no word, sentence or meaning
/// can reach a banner (review-module-plan §5.1). The words are WI-7's, in the view layer.
public enum ReminderContent: Sendable, Hashable {
    /// A sitting is waiting. `predictedCount` is how many meanings it would hold at the fire time
    /// (`SittingPlanner.askableCount(at:)`), or nil where the reader chose not to be told.
    case sittingReady(predictedCount: Int?)
}

extension ReminderContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind = "case"
        case predictedCount
    }

    private enum Kind: String, Codable {
        case sittingReady
    }

    /// A case this version does not know throws, and the log reads the record holding it as gone.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .sittingReady:
            self = .sittingReady(predictedCount: try values.decodeIfPresent(Int.self, forKey: .predictedCount)
                .map { max(0, $0) })
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sittingReady(let count):
            try values.encode(Kind.sittingReady, forKey: .kind)
            try values.encodeIfPresent(count, forKey: .predictedCount)
        }
    }
}

/// **What an add puts in the system under a reminder's identifier**: when, and what it says. The log
/// keeps it, so a changed count or time is seen and the pending request replaced.
public struct ReminderRequest: Sendable, Hashable {
    public let fireAt: Date
    public let content: ReminderContent

    public init(fireAt: Date, content: ReminderContent) {
        self.fireAt = fireAt
        self.content = content
    }
}

/// **One reminder the plan wants in the system.**
public struct PlannedReminder: Sendable, Hashable {
    public let key: ReminderKey
    /// Always after the instant it was planned at, and inside the study day `key` names.
    public let fireAt: Date
    /// The zone the fire time was chosen in — the study day's — which the trigger is pinned to.
    public let zone: TimeZone
    public let content: ReminderContent

    init(key: ReminderKey, fireAt: Date, zone: TimeZone, content: ReminderContent) {
        self.key = key
        self.fireAt = fireAt
        self.zone = zone
        self.content = content
    }

    /// `review.<yyyy-MM-dd>` or `review.<yyyy-MM-dd>.later`.
    public var id: String { key.identifier }

    public var request: ReminderRequest { ReminderRequest(fireAt: fireAt, content: content) }

    /// **The calendar trigger's date components, pinned so the process's zone cannot move them.**
    ///
    /// Pinned to the planning zone (§5.1): with `timeZone` set, `nextTriggerDate()` is the same in any
    /// process zone, and floating components follow it [measured]. Every daily reminder is named by
    /// that zone's wall clock, because it was built from it. **One instant is not**: the second 01:30
    /// of a fall-back night, which a Later can land on — components cannot say which 01:30, and
    /// resolve to the first, an hour early [measured]. That one, and only that one, is pinned to UTC,
    /// the zone that names every instant. Whole seconds; the system's trigger has no finer grain.
    public var triggerComponents: DateComponents {
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        var named = DateComponents()
        for zone in [zone, .gmt] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            named = calendar.dateComponents(fields, from: fireAt)
            named.calendar = calendar
            named.timeZone = zone
            if calendar.date(from: named) == fireAt { return named }
        }
        // Reached only by an instant with a fraction of a second, which nothing here plans: UTC's
        // components, which name the second it falls in.
        return named
    }
}

/// **What the planner wants in the system, and what it looked at and found nothing for** — the second
/// half is what lets the log say "nothing was askable at 19:00" rather than nothing at all.
public struct ReminderPlan: Sendable, Equatable {
    /// Whether reminders are on. Off, the plan is empty and the reconciler withdraws every open day.
    public let isEnabled: Bool
    /// In fire order.
    public let reminders: [PlannedReminder]
    /// Reminders inside the horizon, open in the log, with a fire instant ahead — and a sitting of
    /// nothing at it. **Not a verdict**: the next plan asks again (§5.2).
    public let nothingAskable: Set<ReminderKey>
    /// The instant planned at, as stored — the one the reconciler judges "passed" against.
    public let now: Date
    /// The study day containing `now`, which the log is pruned back from.
    public let today: ReminderDay

    init(isEnabled: Bool, reminders: [PlannedReminder], nothingAskable: Set<ReminderKey>, now: Date,
         today: ReminderDay) {
        self.isEnabled = isEnabled
        self.reminders = reminders
        self.nothingAskable = nothingAskable
        self.now = now
        self.today = today
    }
}

/// **Which reminders the coming study days should have, and what each would say** (review-module-plan
/// §5.1, WI-6).
///
/// Pure: settings, the sitting's own planner — its frozen study day, its stored instant, its batch and
/// its allowance with today's one-day increase — the candidates a sitting is planned from, and the log.
/// The rules, in the order they are asked:
///
/// - **Nothing while disabled.**
/// - **Each of the horizon's study days, today first**, each with at most one daily reminder and at
///   most one Later. A day the log has closed — gone, skipped, sat — is never planned again.
/// - **The daily fire instant is the reader's wall-clock time on the study day's own calendar date** —
///   the next date when the time is before the cutoff — built from date components in the planning
///   zone, never from `+ 86_400`. A time the clock skips resolves forward and a repeated one to its
///   first occurrence, as the system's own trigger resolves them [measured]; an instant that would fall
///   outside its own study day (a cutoff in the skipped hour) is not planned.
/// - **Later's instant is the one the reader asked for**, kept in the log, and is dropped if it is not
///   inside its study day in the planning zone.
/// - **Never at or before now**, which is also why nothing catches up: a fire time that passed with
///   nothing planned is simply over.
/// - **N is `SittingPlanner.askableCount(at: fireAt)`**, so one counting rule serves the sitting and
///   the reminder: due at that instant, not paused or hidden at it, one card a note, new ones within
///   that study day's allowance, no more than a batch. **Zero plans nothing** and is recorded as such.
public enum ReminderPlanner {
    public static func plan(settings: ReminderSettings, sitting: SittingPlanner,
                            candidates: SittingCandidates, log: ReminderLog) -> ReminderPlan {
        let studyDay = sitting.studyDay
        let today = ReminderDay(studyDayContaining: sitting.now, in: studyDay)
        guard settings.isEnabled else {
            return ReminderPlan(isEnabled: false, reminders: [], nothingAskable: [], now: sitting.now, today: today)
        }
        var reminders: [PlannedReminder] = []
        var nothingAskable: Set<ReminderKey> = []
        var start = sitting.today
        for _ in 0..<settings.horizon {
            let end = studyDay.startOfNextDay(containing: start)
            let day = ReminderDay(studyDayContaining: start, in: studyDay)
            for kind in ReminderKind.allCases {
                let key = ReminderKey(day: day, kind: kind)
                if let state = log[key], state.isTerminal { continue }
                guard let fireAt = fireInstant(of: key, settings: settings, studyDay: studyDay, log: log),
                      fireAt > sitting.now, fireAt >= start, fireAt < end
                else { continue }
                let count = sitting.askableCount(at: fireAt, in: candidates)
                guard count > 0 else {
                    nothingAskable.insert(key)
                    continue
                }
                reminders.append(PlannedReminder(
                    key: key, fireAt: fireAt, zone: studyDay.timeZone,
                    content: .sittingReady(predictedCount: settings.showsPredictedCount ? count : nil)))
            }
            start = end
        }
        reminders.sort { $0.fireAt != $1.fireAt ? $0.fireAt < $1.fireAt : $0.key < $1.key }
        return ReminderPlan(isEnabled: true, reminders: reminders, nothingAskable: nothingAskable,
                            now: sitting.now, today: today)
    }

    /// When a reminder would fire, or nil when it has no instant: a Later nobody asked for.
    static func fireInstant(of key: ReminderKey, settings: ReminderSettings, studyDay: StudyDay,
                            log: ReminderLog) -> Date? {
        switch key.kind {
        case .later:
            return log.laterAsked[key.day]
        case .daily:
            // **Before the cutoff is the next calendar date**: 01:30 ends the study day that began at
            // 04:00 the day before. The cutoff's minute is zero, so the hour decides.
            guard let date = settings.hour < studyDay.cutoffHour ? key.day.adding(days: 1) : key.day
            else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = studyDay.timeZone
            return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day,
                                                      hour: settings.hour, minute: settings.minute, second: 0))
        }
    }
}
