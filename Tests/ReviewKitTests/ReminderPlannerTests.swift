import Foundation
@testable import ReviewKit
import Testing

/// **Which reminders the coming study days should have, and what each would say** (review-module-plan
/// §5.1, §5.4, WI-6).
///
/// A reminder's N is `SittingPlanner.askableCount(at: fireAt)` — the sitting's own rule asked about the
/// fire instant, not about now — so a card due tonight is not in a morning reminder's count, a card
/// put off past the fire time is not either, and a one-day increase raises today and nothing else.
/// The fire instant is built from the study day's calendar date and the reader's wall-clock time in
/// the planning zone, never from `+ 86_400`, and nothing is ever planned at or before now.
struct ReminderPlannerTests {
    private typealias F = ReminderFixture

    // MARK: - N is the count at the fire instant

    /// §5.4. A card due at 20:00 is not part of a sitting drawn at 09:00, so a 09:00 reminder over it
    /// would announce a sitting that does not exist yet. Today has nothing at nine; tomorrow's nine
    /// has the card.
    @Test func aReminderAtNineDoesNotCountACardDueAtTwenty() throws {
        let zone = try F.zone("UTC")
        let tonight = F.review(due: try F.local(zone, 10, 20, 20))
        let plan = F.plan(F.on(hour: 9), F.sitting(zone, at: try F.local(zone, 10, 20, 8)), [tonight])

        let today = try F.day(2026, 10, 20), tomorrow = try F.day(2026, 10, 21)
        #expect(plan.nothingAskable.contains(F.daily(today)), "today's 09:00 counted the card due at 20:00")
        #expect(!plan.reminders.contains { $0.key.day == today }, "\(plan.reminders.map(\.id))")
        let next = try #require(plan.reminders.first { $0.key == F.daily(tomorrow) })
        #expect(next.content == .sittingReady(predictedCount: 1))
        let nine = try F.local(zone, 10, 21, 9)
        #expect(next.fireAt == nine)
    }

    /// §5.4. A card put off past the fire time is not askable at it; one put off until exactly the
    /// fire time is (equal is not hidden, `StudyCard.isHidden`).
    @Test func aCardHiddenUntilAfterFireAtIsNotCounted() throws {
        let zone = try F.zone("UTC")
        let overdue = try F.local(zone, 10, 19, 9)
        let pastIt = F.review(due: overdue, hiddenUntil: try F.local(zone, 10, 20, 21))
        let untilIt = F.review(due: overdue, hiddenUntil: try F.local(zone, 10, 20, 19))
        let plan = F.plan(F.on(hour: 19), F.sitting(zone, at: try F.local(zone, 10, 20, 8)), [pastIt, untilIt])

        let counts = Dictionary(uniqueKeysWithValues: plan.reminders.map { ($0.key.day, $0.content) })
        #expect(counts[try F.day(2026, 10, 20)] == .sittingReady(predictedCount: 1),
                "today's 19:00 counted a card put off until 21:00")
        #expect(counts[try F.day(2026, 10, 21)] == .sittingReady(predictedCount: 2))
    }

    /// §5.4. Today's allowance is the base, the one-day increase and today's introductions; every later
    /// day's is the base (`SittingPlanner.askableCount`, WI-5's `OneDayIncrease`).
    @Test func aOneDayIncreaseRaisesOnlyThatDaysPredictedCount() throws {
        let zone = try F.zone("UTC")
        let now = try F.local(zone, 10, 20, 8)
        let waiting = (0..<8).map { _ in F.fresh() }
        func counts(increase: Int) -> [Int?] {
            F.plan(F.on(hour: 19, horizon: 3), F.sitting(zone, at: now, perDay: 2, increase: increase), waiting,
                   introduced: 1).reminders.map {
                guard case .sittingReady(let count) = $0.content else { return nil }
                return count
            }
        }
        #expect(counts(increase: 3) == [4, 2, 2], "two, three more today, one spent: four today and the base after")
        #expect(counts(increase: 0) == [1, 2, 2])
    }

    // MARK: - Never in the past, never caught up

    /// §5.4. A fire instant at or before now is never planned — so a past instant can never alert —
    /// and it is not "nothing askable" either: it is simply over. One second before, it is planned.
    @Test func noFireInstantIsPlannedInThePast() throws {
        let zone = try F.zone("UTC")
        let card = F.review(due: try F.local(zone, 10, 19, 9))
        let today = F.daily(try F.day(2026, 10, 20))

        let atIt = F.plan(F.on(hour: 19), F.sitting(zone, at: try F.local(zone, 10, 20, 19)), [card])
        #expect(!atIt.reminders.contains { $0.key == today }, "planned at its own fire instant")
        #expect(!atIt.nothingAskable.contains(today), "a passed fire time was called empty")
        let before = F.plan(F.on(hour: 19), F.sitting(zone, at: try F.local(zone, 10, 20, 18, 59, 59)), [card])
        #expect(before.reminders.first?.key == today)

        // Over two hundred random instants, times and zones: nothing at or before now, ever.
        var generator = SeededGenerator(state: 20_261_004)
        let zones = try ["UTC", "America/New_York", "Asia/Shanghai", "Australia/Lord_Howe"].map(F.zone)
        for round in 0..<200 {
            let zone = zones[Int.random(in: 0..<zones.count, using: &generator)]
            let now = try F.local(zone, 10, 25, 0).addingTimeInterval(
                TimeInterval(Int.random(in: 0..<(14 * 86_400), using: &generator)))
            let settings = F.on(hour: Int.random(in: 0...23, using: &generator),
                                minute: Int.random(in: 0...59, using: &generator))
            let plan = F.plan(settings, F.sitting(zone, at: now), [card])
            #expect(plan.reminders.allSatisfy { $0.fireAt > plan.now }, "round \(round)")
            #expect(!plan.reminders.isEmpty, "round \(round): nothing planned over a week of due work")
        }
    }

    // MARK: - The study day a fire time belongs to

    /// **A fire time before the cutoff belongs to the previous study day** (§5.1): 01:30 ends the
    /// study day that began at 04:00 the day before, so it is named for that day and fires on the next
    /// calendar date. At 01:00 on the 21st it is still the 20th's, half an hour ahead.
    @Test func aFireTimeBeforeTheCutoffBelongsToThePreviousStudyDay() throws {
        let zone = try F.zone("UTC")
        let card = F.review(due: try F.local(zone, 10, 19, 9))
        let evening = F.plan(F.on(hour: 1, minute: 30), F.sitting(zone, at: try F.local(zone, 10, 20, 10)), [card])
        let first = try #require(evening.reminders.first)
        #expect(first.id == "review.2026-10-20")
        let half = try F.local(zone, 10, 21, 1, 30)
        #expect(first.fireAt == half)

        let night = F.plan(F.on(hour: 1, minute: 30), F.sitting(zone, at: try F.local(zone, 10, 21, 1)), [card])
        #expect(night.today == (try F.day(2026, 10, 20)))
        #expect(night.reminders.first?.id == "review.2026-10-20")

        // The cutoff itself is the first instant of the study day it starts — not the last of the one
        // before — so at 03:00, inside the 19th's study day, the next 04:00 is the 20th's reminder.
        let atCutoff = F.plan(F.on(hour: 4), F.sitting(zone, at: try F.local(zone, 10, 20, 3)), [card])
        let four = try F.local(zone, 10, 20, 4)
        #expect(atCutoff.today == (try F.day(2026, 10, 19)))
        #expect(atCutoff.reminders.first?.fireAt == four)
        #expect(atCutoff.reminders.first?.id == "review.2026-10-20", "04:00 was named for the study day it ends")
    }

    /// **Every fire instant lies inside the study day it is named for**, in any zone, at any time of
    /// day, across both of 2026's clock changes.
    @Test func everyFireInstantLiesInsideItsOwnStudyDay() throws {
        var generator = SeededGenerator(state: 4_102_026)
        let zones = try ["UTC", "America/New_York", "Europe/London", "Asia/Shanghai", "Australia/Lord_Howe"]
            .map(F.zone)
        let card = F.fresh()
        for round in 0..<300 {
            let zone = zones[Int.random(in: 0..<zones.count, using: &generator)]
            let month = [3, 4, 10, 11][Int.random(in: 0..<4, using: &generator)]
            let now = try F.local(zone, month, Int.random(in: 1...20, using: &generator),
                                  Int.random(in: 0...23, using: &generator))
            let settings = F.on(hour: Int.random(in: 0...23, using: &generator),
                                minute: [0, 15, 30, 59][Int.random(in: 0..<4, using: &generator)])
            let plan = F.plan(settings, F.sitting(zone, at: now), [card])
            for reminder in plan.reminders {
                #expect(ReminderDay(studyDayContaining: reminder.fireAt, in: F.studyDay(zone)) == reminder.key.day,
                        "round \(round): \(reminder.id) fires at \(reminder.fireAt), in another study day")
            }
            #expect(Set(plan.reminders.map(\.key.day)).count == plan.reminders.count, "round \(round): a day twice")
        }
    }

    // MARK: - Daylight saving, and the zone

    /// **New York leaves daylight saving at 02:00 on 2026-11-01.** 19:00 every day is 19:00 on each
    /// calendar date — Saturday 19:00 to Sunday 19:00 is 25 hours — and 01:30, before the cutoff, is
    /// the first 01:30 of the repeated hour, still Saturday's study day. Shanghai, with no daylight
    /// saving, has the same wall clock and 24-hour steps: the control that makes the cases differ.
    @Test(arguments: ["America/New_York", "Asia/Shanghai"])
    func theFallBackWeekendKeepsTheWallClock(_ identifier: String) throws {
        let zone = try F.zone(identifier)
        let card = F.review(due: try F.local(zone, 10, 29, 9))
        let sitting = F.sitting(zone, at: try F.local(zone, 10, 30, 10))

        let evening = F.plan(F.on(hour: 19), sitting, [card])
        try #require(evening.reminders.map(\.id) == (30...31).map { "review.2026-10-\($0)" }
                         + (1...5).map { "review.2026-11-0\($0)" })
        for reminder in evening.reminders {
            let parts = F.calendar(zone).dateComponents([.hour, .minute], from: reminder.fireAt)
            #expect(parts.hour == 19 && parts.minute == 0, "\(identifier): \(reminder.id)")
        }
        let saturday = evening.reminders[2].fireAt.timeIntervalSince(evening.reminders[1].fireAt)
        #expect(saturday == (identifier == "America/New_York" ? 25 : 24) * 3_600)

        let night = F.plan(F.on(hour: 1, minute: 30), sitting, [card])
        let fallBack = try #require(night.reminders.first { $0.id == "review.2026-10-31" })
        let firstOneThirty = try F.local(zone, 11, 1, 1, 30)
        #expect(fallBack.fireAt == firstOneThirty)
        if identifier == "America/New_York" {
            #expect(fallBack.fireAt == Date(timeIntervalSince1970: 1_793_511_000), "01:30 EDT, measured")
        }
    }

    /// **New York skips 02:00–03:00 on 2026-03-08.** A 02:30 reminder — before the cutoff, so the 7th's
    /// — has no 02:30 that night; it fires at 03:30 EDT, as Foundation and the system trigger both
    /// resolve it (measured), and that is still before the 8th's 04:00 cutoff. 19:00 to 19:00 across
    /// the change is 23 hours.
    @Test func theSpringForwardNightResolvesTheSkippedTimeForward() throws {
        let zone = try F.zone("America/New_York")
        let card = F.review(due: try F.local(zone, 3, 5, 9))
        let sitting = F.sitting(zone, at: try F.local(zone, 3, 6, 10))

        let skipped = F.plan(F.on(hour: 2, minute: 30), sitting, [card])
        let seventh = try #require(skipped.reminders.first { $0.id == "review.2026-03-07" })
        let threeThirty = try F.local(zone, 3, 8, 3, 30)
        #expect(seventh.fireAt == threeThirty)
        let wall = F.calendar(zone).dateComponents([.hour, .minute], from: seventh.fireAt)
        #expect(wall.hour == 3 && wall.minute == 30, "\(wall)")

        let evening = F.plan(F.on(hour: 19), sitting, [card])
        let saturday = try #require(evening.reminders.first { $0.id == "review.2026-03-07" })
        let sunday = try #require(evening.reminders.first { $0.id == "review.2026-03-08" })
        #expect(sunday.fireAt.timeIntervalSince(saturday.fireAt) == 23 * 3_600)
    }

    /// **The trigger is pinned to the planning zone, so the process's zone cannot move it** (§5.1).
    /// Each planned reminder carries the study day's zone; its trigger components name that zone and
    /// resolve to the fire instant whatever zone the resolving calendar is in. The same components
    /// left floating resolve elsewhere — the control that shows the pin is what holds it.
    @Test func thePlanningZoneIsCarriedAndAProcessZoneChangeDoesNotMoveAnInstant() throws {
        let shanghai = try F.zone("Asia/Shanghai")
        let elsewhere = try ["America/New_York", "UTC", "Asia/Kolkata", "Pacific/Chatham"].map(F.zone)
        let card = F.review(due: try F.local(shanghai, 10, 29, 9))
        let plan = F.plan(F.on(hour: 19), F.sitting(shanghai, at: try F.local(shanghai, 10, 30, 10)), [card])
        try #require(!plan.reminders.isEmpty)
        for reminder in plan.reminders {
            #expect(reminder.zone == shanghai)
            let pinned = reminder.triggerComponents
            #expect(pinned.timeZone == shanghai, "\(reminder.id)")
            for zone in elsewhere {
                #expect(F.calendar(zone).date(from: pinned) == reminder.fireAt, "\(reminder.id) resolved in \(zone)")
                var floating = pinned
                floating.timeZone = nil
                #expect(F.calendar(zone).date(from: floating) != reminder.fireAt, "the control: unpinned in \(zone)")
            }
        }
        // The zone is the one passed in: one instant, two planning zones, two fire instants.
        let now = try F.local(shanghai, 10, 30, 10)
        let newYork = F.plan(F.on(hour: 19), F.sitting(try F.zone("America/New_York"), at: now), [card])
        #expect(newYork.reminders.first?.fireAt != plan.reminders.first?.fireAt)
    }

    /// **An instant the zone's wall clock cannot name is pinned to UTC instead.** On the fall-back
    /// night 01:30 happens twice and `DateComponents` cannot say which; a Later asked at 00:30 EDT
    /// lands on the second. Components in New York would resolve to the first — an hour early — so the
    /// trigger names the instant in UTC. A daily reminder, built from the wall clock, never needs it.
    @Test func anInstantInTheRepeatedHourIsPinnedToUTC() throws {
        let newYork = try F.zone("America/New_York")
        let first = Date(timeIntervalSince1970: 1_793_511_000)  // 01:30 EDT, measured
        let second = first.addingTimeInterval(3_600)             // 01:30 EST
        let key = F.later(try F.day(2026, 10, 31))
        for (fireAt, zone) in [(first, newYork), (second, TimeZone.gmt)] {
            let reminder = PlannedReminder(key: key, fireAt: fireAt, zone: newYork,
                                           content: .sittingReady(predictedCount: 1))
            #expect(reminder.triggerComponents.timeZone == zone, "\(fireAt)")
            #expect(F.calendar(try F.zone("Asia/Shanghai")).date(from: reminder.triggerComponents) == fireAt)
        }
    }

    /// **Nothing in the reminder files reads the process's zone or clock** — read from the source
    /// with comments removed. The zone is the study day's and the instant is the planner's, both passed
    /// in; `TimeZone.current` would make the plan follow the machine, which is what pinning is for.
    @Test func theReminderFilesReadNeitherTheProcessZoneNorTheClock() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["ReminderSettings", "ReminderPlanner", "ReminderLog", "ReminderReconciler"] {
            let source = try String(contentsOf: root.appending(path: "Sources/ReviewKit/\(name).swift"), encoding: .utf8)
            #expect(Self.ambient(in: source).isEmpty, "\(name).swift names \(Self.ambient(in: source))")
        }
        // Positive controls: each spelling is seen in code, and none in a comment.
        #expect(Self.ambient(in: "let zone = TimeZone.current") == [".current"])
        #expect(Self.ambient(in: "calendar.timeZone = .autoupdatingCurrent") == ["autoupdatingCurrent"])
        #expect(Self.ambient(in: "let now = Date()") == ["Date()"])
        #expect(Self.ambient(in: "let now = Date.now") == ["Date.now"])
        #expect(Self.ambient(in: "/// never TimeZone.current or Date()").isEmpty)
    }

    private static func ambient(in source: String) -> [String] {
        let code = source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.range(of: "//").map { String(line[line.startIndex..<$0.lowerBound]) } ?? String(line)
        }.joined(separator: "\n")
        return [".current", "autoupdatingCurrent", "Date()", "Date.now", "NSTimeZone"].filter { code.contains($0) }
    }

    // MARK: - What a reminder may say

    /// **No case of the content carries a `String`** (§5.1): a banner can say a sitting is waiting and
    /// how big, never a word, a sentence or a meaning. The switch below is exhaustive and names each
    /// payload's type, so a new case or a new payload is a compile error here; the reflection walk
    /// finds a string at any depth, and its control shows it can.
    @Test func theContentCarriesNoString() {
        for content in [ReminderContent.sittingReady(predictedCount: 7), .sittingReady(predictedCount: nil)] {
            switch content {
            case .sittingReady(let count):
                let _: Int? = count
            }
            #expect(Self.strings(in: content).isEmpty, "\(content)")
        }
        enum Leaky { case word(String), nested(count: Int, note: Substring?) }
        #expect(Self.strings(in: Leaky.word("laconic")) == ["laconic"])
        #expect(Self.strings(in: Leaky.nested(count: 1, note: "terse")) == ["terse"])
    }

    private static func strings(in value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let text = value as? Substring { return [String(text)] }
        if let character = value as? Character { return [String(character)] }
        return Mirror(reflecting: value).children.flatMap { strings(in: $0.value) }
    }

    /// **With N hidden, the content says only that a sitting is waiting** — and the count is still
    /// asked, because a reminder is never planned into an empty queue.
    @Test func aHiddenCountSaysOnlyThatASittingIsWaiting() throws {
        let zone = try F.zone("UTC")
        let sitting = F.sitting(zone, at: try F.local(zone, 10, 20, 8))
        let hidden = F.plan(F.on(hour: 19, showsCount: false), sitting, [F.review(due: try F.local(zone, 10, 19, 9))])
        #expect(!hidden.reminders.isEmpty)
        #expect(hidden.reminders.allSatisfy { $0.content == .sittingReady(predictedCount: nil) })
        let empty = F.plan(F.on(hour: 19, showsCount: false), sitting, [])
        #expect(empty.reminders.isEmpty)
        #expect(empty.nothingAskable.count == 7)
    }

    // MARK: - Off, the horizon, and determinism

    /// **Nothing while disabled** (§5.1, H1) — not with work waiting, and not over a log that holds
    /// requests: the reconciler removes what the empty plan does not name.
    @Test func disabledPlansNothing() throws {
        let zone = try F.zone("UTC")
        let card = F.review(due: try F.local(zone, 10, 19, 9))
        let sitting = F.sitting(zone, at: try F.local(zone, 10, 20, 8))
        let on = F.plan(F.on(hour: 19), sitting, [card])
        let log = F.afterAdding(ReminderReconciler.reconcile(on, log: ReminderLog(), pending: [], delivered: []))
        let off = F.plan(ReminderSettings(isEnabled: false, hour: 19), sitting, [card], log: log)
        #expect(off.reminders.isEmpty && off.nothingAskable.isEmpty)
        #expect(F.plan(.recommended, sitting, [card]).reminders.isEmpty, "the recommendation is off")
    }

    /// **The horizon is that many study days, today first** — none beyond it, and none at all for a
    /// horizon of zero.
    @Test func theHorizonIsThatManyStudyDays() throws {
        let zone = try F.zone("UTC")
        let card = F.review(due: try F.local(zone, 10, 19, 9))
        let sitting = F.sitting(zone, at: try F.local(zone, 10, 20, 8))
        #expect(F.plan(F.on(hour: 19, horizon: 3), sitting, [card]).reminders.map(\.id)
                    == ["review.2026-10-20", "review.2026-10-21", "review.2026-10-22"])
        #expect(F.plan(F.on(hour: 19), sitting, [card]).reminders.count == 7)
        #expect(F.plan(F.on(hour: 19, horizon: 0), sitting, [card]).reminders.isEmpty)
    }

    /// **Planning twice with the same inputs gives the same plan**, and the order the candidates arrive
    /// in does not reach it — re-planning is how every trigger works (WI-7), so it must be a function.
    @Test func planningIsIdempotent() throws {
        let zone = try F.zone("America/New_York")
        let sitting = F.sitting(zone, at: try F.local(zone, 10, 30, 10))
        var cards = (0..<6).map { offset in F.review(due: Date(timeIntervalSince1970: 1_793_400_000 + Double(offset) * 40_000)) }
        cards += (0..<4).map { _ in F.fresh() }
        let log = ReminderLog().withdrawing(try F.day(2026, 11, 2), .skipped)
        let once = F.plan(F.on(hour: 7, minute: 45), sitting, cards, introduced: 2, log: log)
        let twice = F.plan(F.on(hour: 7, minute: 45), sitting, cards, introduced: 2, log: log)
        #expect(once == twice)
        #expect(F.plan(F.on(hour: 7, minute: 45), sitting, cards.reversed(), introduced: 2, log: log) == once)
        #expect(once.reminders == once.reminders.sorted { $0.fireAt < $1.fireAt }, "in fire order")
    }

    // MARK: - Settings

    /// **Settings decode whatever was kept**: an absent field is the recommendation, an extra one is
    /// ignored, and a value off the clock is clamped — the horizon to the 32 study days two identifiers
    /// a day fit in the system's 64 pending requests.
    @Test func settingsDecodeWithDefaultsAndClamp() throws {
        let decoded = try JSONDecoder().decode(ReminderSettings.self, from: Data("{}".utf8))
        #expect(decoded == .recommended)
        #expect(ReminderSettings.recommended == ReminderSettings(
            isEnabled: false, hour: 19, minute: 0, showsPredictedCount: true, laterDelay: 7_200, horizon: 7))
        let wild = try JSONDecoder().decode(ReminderSettings.self, from: Data("""
            {"isEnabled": true, "hour": 31, "minute": -4, "laterDelay": -60, "horizon": 400,
             "quietHours": [22, 7], "aFieldFromLater": {"x": 1}}
            """.utf8))
        #expect(wild == ReminderSettings(isEnabled: true, hour: 23, minute: 0, showsPredictedCount: true,
                                         laterDelay: 0, horizon: 32))
        let round = F.on(hour: 6, minute: 5, showsCount: false, horizon: 3, later: 1_800)
        #expect(try JSONDecoder().decode(ReminderSettings.self, from: JSONEncoder().encode(round)) == round)
    }

    /// **How long Later waits is the reader's, from a small set** (R3, 2026-10-05), and the instant it
    /// asks for is that long after the click — each choice, and only it.
    @Test func laterWaitsTheDelayTheReaderChose() throws {
        #expect(ReminderSettings.laterDelayChoices == [3_600, 7_200, 14_400])
        #expect(ReminderSettings.laterDelayChoices.contains(ReminderRecommendation.laterDelay))
        let zone = try F.zone("Asia/Shanghai")
        let clicked = try F.local(zone, 10, 5, 13, 5)
        let day = try F.day(2026, 10, 5)
        for choice in ReminderSettings.laterDelayChoices {
            let asked = ReminderLog().askingLater(on: day, at: clicked, settings: F.on(later: choice),
                                                  studyDay: F.studyDay(zone))
            guard case .asked(let update) = asked else {
                Issue.record("Later refused at \(choice) s: \(asked)")
                continue
            }
            #expect(update.log.laterAsked[day] == clicked.addingTimeInterval(choice))
        }
    }

    /// **What Settings offers is the set, and the value kept if it is not in it** — written by another
    /// version, or by the `reminder` stage — so the picker never shows a choice the planner is not using.
    @Test func theLaterChoicesOfferedIncludeTheOneKept() {
        #expect(F.on(later: 7_200).offeredLaterDelays == [3_600, 7_200, 14_400])
        #expect(F.on(later: 10_800).offeredLaterDelays == [3_600, 7_200, 10_800, 14_400])
    }
}
