import Foundation

/// **What the coming study days will ask: "What's coming" at the end of a sitting** (review-module-plan
/// §3 — a forecast is a must-have, because due dates are facts — §8.4, WI-5).
///
/// Pure, over the candidates a sitting is planned from and the planner it was planned with, so the
/// study day, the stored instant and the allowance are the sitting's own. For each of `days` study
/// days, today first, it counts the meanings that day will ask **if each day's work is done** — the
/// reader who keeps up, which is the only reader a per-day count can describe:
///
/// - **A card belongs to the study day its due falls in**, on the reader's calendar: the 04:00 cutoff,
///   days built from date components and never from `+ 86_400`, so a 25-hour day on a fall-back
///   weekend is one day and not a day and an hour (`StudyDay`).
/// - **Overdue work is today's**, counted once — never spread over the days it was missed, and never
///   carried into tomorrow, since a forecast that assumes today is done cannot also count it again.
/// - **A put-off card counts on the day it comes back**; a paused one on no day.
/// - **One meaning per note a day** (R08): a sitting asks a note once.
/// - **New meanings only up to each day's allowance**, as `SittingPlanner.askableCount(at:)` rations
///   them: today what is left of today's (its base, any one-day increase, less today's introductions),
///   every later day the base. A note with a card in progress that day is asked through it and spends
///   nothing. What a day introduces leaves the waiting pool, so held-back meanings are spread over the
///   days that will introduce them and **never counted as due**.
///
/// **A floor, not a promise.** A meaning introduced on one of these days comes back on a later one too,
/// at an interval its first grade decides; the forecast does not guess the grade. Every write the reader
/// makes changes the ledger it was read from.
public struct Forecast: Sendable, Equatable {
    /// How many study days the end of a sitting looks ahead, today included: a week, which is as far as
    /// a reader plans a habit around. The reminder plan's horizon is the same seven study days (§5.1).
    public static let horizon = 7

    public struct Day: Sendable, Equatable {
        /// 0 is today, 1 tomorrow — what the surface names a day by before it falls back on a weekday.
        public let offset: Int
        /// When this study day begins: 04:00 on its own calendar date, in `Forecast.timeZone`.
        public let start: Date
        /// Meanings with a card in progress that become askable on this day — overdue ones today.
        public let reviews: Int
        /// New meanings this day's allowance would introduce, out of those still waiting.
        public let introductions: Int

        /// What the day will ask.
        public var due: Int { reviews + introductions }

        public init(offset: Int, start: Date, reviews: Int, introductions: Int) {
            self.offset = offset
            self.start = start
            self.reviews = reviews
            self.introductions = introductions
        }
    }

    /// The zone the days were counted in — the sitting's frozen study day's — so a surface names each
    /// day on the same calendar it was counted on.
    public let timeZone: TimeZone
    /// Today first, one entry per study day.
    public let days: [Day]

    public init(from candidates: SittingCandidates, planner: SittingPlanner, days count: Int = Forecast.horizon) {
        timeZone = planner.studyDay.timeZone
        let count = max(0, count)
        guard count > 0 else {
            days = []
            return
        }
        // Boundaries, one more than the days: each the calendar's next study day after the last.
        var starts = [planner.today]
        for _ in 0..<count {
            starts.append(planner.studyDay.startOfNextDay(containing: starts[starts.count - 1]))
        }
        // **Which day an instant is askable on**: anything up to the end of today is today's, overdue
        // included; past the last day, none.
        func day(of instant: Date) -> Int? {
            guard instant >= starts[1] else { return 0 }
            return (1..<count).first { instant >= starts[$0] && instant < starts[$0 + 1] }
        }

        var reviewing = Array(repeating: Set<UUID>(), count: count)
        // Each note with a new card that is not paused, and the first day that card can be asked.
        var waitingFrom: [UUID: Int] = [:]
        for card in candidates.cards where !card.isPaused {
            // **Askable from the later of its due and the end of its put-off** — `isDue(at:)` and
            // `isHidden(at:)` both say so of the same instant. A card never scheduled is due at once.
            let due = card.scheduled.phase == .new ? nil : card.scheduled.due
            let askable = [due, card.hiddenUntil].compactMap { $0 }.max() ?? planner.now
            guard let offset = day(of: askable) else { continue }
            if card.scheduled.phase == .new {
                waitingFrom[card.noteID] = min(offset, waitingFrom[card.noteID] ?? offset)
            } else {
                reviewing[offset].insert(card.noteID)
            }
        }

        // The waiting pool in the order it is drawn from: the longest-waiting first, then by id so one
        // ledger always gives one forecast.
        let waiting = waitingFrom.sorted {
            $0.value != $1.value ? $0.value < $1.value : $0.key.uuidString < $1.key.uuidString
        }
        var introduced = Set<UUID>()
        var days: [Day] = []
        for offset in 0..<count {
            let allowance = offset == 0
                ? SittingPlanner.newCardsLeft(allowance: planner.allowanceToday,
                                              introduced: candidates.introducedToday)
                : max(0, planner.newCardsPerDay)
            var taken = 0
            for (note, from) in waiting where taken < allowance && from <= offset {
                guard !introduced.contains(note), !reviewing[offset].contains(note) else { continue }
                introduced.insert(note)
                taken += 1
            }
            days.append(Day(offset: offset, start: starts[offset], reviews: reviewing[offset].count,
                            introductions: taken))
        }
        self.days = days
    }
}
