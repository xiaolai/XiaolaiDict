import Foundation
@testable import ReviewKit
import Testing

/// **What the coming study days hold, counted by study day** (review-module-plan §3, §8.4, WI-5).
///
/// The end of a sitting says "What's coming" as text: how many meanings each of the next seven study
/// days will ask. Three things make that number honest or not, and each has a test here: the day a
/// card belongs to is the *study day* its due falls in — a calendar date with a 04:00 cutoff, not a
/// multiple of 24 hours from now; a new meaning the allowance holds back is never counted as due;
/// and a card the reader put away is counted on the day it comes back, or never.
struct ForecastTests {
    // MARK: - Fixture

    private func zone(_ identifier: String) throws -> TimeZone {
        try #require(TimeZone(identifier: identifier))
    }

    private func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// 2026-`month`-`day` at `hour`:`minute`, on the wall clock of `zone`.
    private func local(_ zone: TimeZone, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
        try #require(calendar(zone).date(from: DateComponents(year: 2026, month: month, day: day,
                                                              hour: hour, minute: minute)))
    }

    private func planner(_ zone: TimeZone, at now: Date, perDay: Int = 5, increase: Int = 0) -> SittingPlanner {
        SittingPlanner(studyDay: StudyDay(timeZone: zone, cutoffHour: 4), now: now, batchSize: 10,
                       newCardsPerDay: perDay, increaseToday: increase)
    }

    private func review(note: UUID = UUID(), due: Date, paused: Bool = false, hiddenUntil: Date? = nil) -> StudyCard {
        StudyCard(noteID: note, scheduled: ScheduledCard(
                      state: MemoryState(stability: 10, difficulty: 5), phase: .review,
                      lastReview: due.addingTimeInterval(-10 * 86_400), due: due),
                  isPaused: paused, hiddenUntil: hiddenUntil, createdAt: .distantPast)
    }

    private func fresh(note: UUID = UUID(), paused: Bool = false, hiddenUntil: Date? = nil) -> StudyCard {
        StudyCard(noteID: note, isPaused: paused, hiddenUntil: hiddenUntil, createdAt: .distantPast)
    }

    private func forecast(_ cards: [StudyCard], introducedToday: Int = 0, _ planner: SittingPlanner) -> Forecast {
        Forecast(from: SittingCandidates(cards: cards, introducedToday: introducedToday), planner: planner)
    }

    // MARK: - Study days, not 24 hours

    /// **A card belongs to the study day its due falls in.** New York leaves daylight saving at 02:00
    /// on Sunday 2026-11-01, so Saturday's study day — 04:00 Saturday to 04:00 Sunday — is 25 hours
    /// long. A forecast that cut the week into 24-hour slices from today's start would put the card
    /// due at 03:30 on Sunday into Sunday (it is Saturday's: the cutoff has not come) and the one due
    /// at 03:30 the next Friday past the seventh day (it is Thursday's). Shanghai has no daylight
    /// saving and the same wall-clock fixture gives the same answer, which is the point: the answer
    /// is about the reader's calendar, and only one of the two zones can tell the slices apart.
    @Test(arguments: ["America/New_York", "Asia/Shanghai"])
    func theForecastCountsByStudyDayAcrossDaylightSaving(_ identifier: String) throws {
        let zone = try zone(identifier)
        let now = try local(zone, 10, 30, 10)  // Friday morning
        let cards = [
            review(due: try local(zone, 10, 29, 9)),        // overdue: today's
            review(due: try local(zone, 10, 30, 20)),       // later today
            review(due: try local(zone, 11, 1, 3, 30)),     // Sunday before the cutoff: Saturday's
            review(due: try local(zone, 11, 1, 4, 30)),     // Sunday's
            review(due: try local(zone, 11, 6, 3, 30)),     // Friday before the cutoff: Thursday's, the seventh day
            review(due: try local(zone, 11, 6, 4, 30)),     // Friday's: past the seventh day
        ]
        let coming = forecast(cards, planner(zone, at: now))

        #expect(coming.days.map(\.reviews) == [2, 1, 1, 0, 0, 0, 1], "\(identifier): \(coming.days.map(\.reviews))")
        #expect(coming.days.map(\.offset) == Array(0..<7))
        #expect(coming.timeZone == zone)
        // Each day starts at 04:00 on its own calendar date, wherever the clock changed in between.
        let first = try local(zone, 10, 30, 4)
        for day in coming.days {
            let expected = try #require(calendar(zone).date(byAdding: .day, value: day.offset, to: first))
            let parts = calendar(zone).dateComponents([.hour, .minute], from: day.start)
            #expect(day.start == expected, "\(identifier): day \(day.offset) starts \(day.start)")
            #expect(parts.hour == 4 && parts.minute == 0)
        }
        // The control that makes the zones different: Saturday is 25 hours in New York, 24 in Shanghai.
        let saturday = coming.days[2].start.timeIntervalSince(coming.days[1].start)
        #expect(saturday == (identifier == "America/New_York" ? 25 : 24) * 3_600)
    }

    /// **Overdue work belongs to today, and only to today.** A card due a week ago is today's work,
    /// counted once, never spread over the days it was missed or carried into tomorrow.
    @Test func overdueWorkIsTodaysAndIsCountedOnce() throws {
        let zone = try zone("UTC")
        let now = try local(zone, 3, 10, 12)
        let coming = forecast([review(due: try local(zone, 3, 3, 12)), review(due: try local(zone, 3, 10, 11))],
                              planner(zone, at: now))
        #expect(coming.days.map(\.due) == [2, 0, 0, 0, 0, 0, 0])
    }

    // MARK: - The allowance

    /// **A new meaning the allowance holds back is never counted as due.** Today's allowance is spent,
    /// so today introduces nothing; each later day introduces the base allowance, out of what is still
    /// waiting, until nothing is. Twelve new meanings at five a day are 0, 5, 5, 2 — not twelve on any
    /// day. A one-day increase raises today and no other day.
    @Test func aForecastNeverCountsHeldBackCardsAsDue() throws {
        let zone = try zone("UTC")
        let now = try local(zone, 3, 10, 12)
        let waiting = (0..<12).map { _ in fresh() }
        let tomorrow = [review(due: try local(zone, 3, 11, 12)), review(due: try local(zone, 3, 11, 13))]

        let spent = forecast(waiting + tomorrow, introducedToday: 5, planner(zone, at: now))
        #expect(spent.days.map(\.introductions) == [0, 5, 5, 2, 0, 0, 0], "\(spent.days.map(\.introductions))")
        #expect(spent.days.map(\.reviews) == [0, 2, 0, 0, 0, 0, 0])
        #expect(spent.days.map(\.due) == [0, 7, 5, 2, 0, 0, 0])
        #expect(spent.days.allSatisfy { $0.introductions <= 5 }, "a day introduced more than its allowance")

        let raised = forecast(waiting + tomorrow, introducedToday: 5, planner(zone, at: now, increase: 3))
        #expect(raised.days.map(\.introductions) == [3, 5, 4, 0, 0, 0, 0], "\(raised.days.map(\.introductions))")

        // Nothing introduced yet today: today's allowance is whole, and is today's alone.
        let whole = forecast(waiting, planner(zone, at: now))
        #expect(whole.days.map(\.introductions) == [5, 5, 2, 0, 0, 0, 0])

        // **Today agrees with the planner's own count** at the sitting's instant, where nothing is
        // capped by the batch: one rule, read two ways.
        let roomy = SittingPlanner(studyDay: StudyDay(timeZone: zone, cutoffHour: 4), now: now, batchSize: 100,
                                   newCardsPerDay: 5)
        let candidates = SittingCandidates(cards: waiting + [review(due: try local(zone, 3, 9, 12))],
                                           introducedToday: 2)
        #expect(Forecast(from: candidates, planner: roomy).days[0].due == roomy.askableCount(at: now, in: candidates))
    }

    /// **An allowance with no limit, or none at all, is honoured without overflow.**
    @Test func anUnlimitedOrEmptyAllowanceIsHonoured() throws {
        let zone = try zone("UTC")
        let now = try local(zone, 3, 10, 12)
        let waiting = (0..<4).map { _ in fresh() }
        #expect(forecast(waiting, introducedToday: 9, planner(zone, at: now, perDay: .max, increase: .max))
                    .days.map(\.introductions) == [4, 0, 0, 0, 0, 0, 0])
        #expect(forecast(waiting, planner(zone, at: now, perDay: 0)).days.map(\.introductions) == [0, 0, 0, 0, 0, 0, 0])
        #expect(Forecast(from: SittingCandidates(cards: waiting, introducedToday: 0), planner: planner(zone, at: now),
                         days: 0).days.isEmpty)
    }

    // MARK: - What the reader put away

    /// **Paused is never; put off is the day it comes back.** A paused card is not asked on any day,
    /// new or not. A card put off past its due comes back on the day its put-off ends — and a put-off
    /// that ends exactly at a study day's start belongs to that day, because a card put off until nine
    /// is askable at nine.
    @Test func aPausedCardIsNeverForecastAndAPutOffOneComesBackOnItsDay() throws {
        let zone = try zone("UTC")
        let now = try local(zone, 3, 10, 12)
        let coming = forecast([
            review(due: try local(zone, 3, 11, 12), paused: true),
            fresh(paused: true),
            review(due: try local(zone, 3, 9, 12), hiddenUntil: try local(zone, 3, 12, 10)),
            review(due: try local(zone, 3, 9, 12), hiddenUntil: try local(zone, 3, 11, 4)),
            fresh(hiddenUntil: try local(zone, 3, 13, 9)),
        ], planner(zone, at: now))
        #expect(coming.days.map(\.reviews) == [0, 1, 1, 0, 0, 0, 0], "\(coming.days.map(\.reviews))")
        #expect(coming.days.map(\.introductions) == [0, 0, 0, 1, 0, 0, 0], "\(coming.days.map(\.introductions))")
    }

    /// **One card per note a day** (R08): a sitting asks a note once, so two of its cards due on one
    /// day are one meaning to answer that day.
    @Test func aNoteIsCountedOnceADay() throws {
        let zone = try zone("UTC")
        let now = try local(zone, 3, 10, 12)
        let note = UUID()
        let coming = forecast([
            review(note: note, due: try local(zone, 3, 11, 9)),
            review(note: note, due: try local(zone, 3, 11, 15)),
            review(due: try local(zone, 3, 11, 10)),
        ], planner(zone, at: now))
        #expect(coming.days.map(\.reviews) == [0, 2, 0, 0, 0, 0, 0])
    }

    /// **Judged at the stored instant**, as the planner judges everything: the forecast's today is the
    /// planner's today, and a card due exactly at the sitting's stored instant is today's.
    @Test func theForecastIsThePlannersStudyDay() throws {
        let zone = try zone("UTC")
        let planner = planner(zone, at: Date(timeIntervalSince1970: 1_793_620_800.000_000_1))
        let coming = forecast([review(due: planner.now)], planner)
        #expect(coming.days.first?.start == planner.today)
        #expect(coming.days.first?.reviews == 1)
    }
}
