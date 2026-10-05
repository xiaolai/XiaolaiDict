import Foundation
@testable import ReviewKit
import Testing

/// **What the reminder tests share**: instants on a named zone's wall clock, cards, and a sitting
/// planner built the way the Review window builds one (batch 10, five new meanings a day, the 04:00
/// cutoff). Whole seconds throughout, so every instant here is its own stored form.
enum ReminderFixture {
    static func zone(_ identifier: String) throws -> TimeZone {
        try #require(TimeZone(identifier: identifier))
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// 2026-`month`-`day` at `hour`:`minute`:`second` on the wall clock of `zone`. A time the clock
    /// skips resolves forward and a time it repeats resolves to its first occurrence — measured, and
    /// what the planner's own arithmetic does.
    static func local(_ zone: TimeZone, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0,
                      _ second: Int = 0) throws -> Date {
        try #require(calendar(zone).date(from: DateComponents(year: 2026, month: month, day: day,
                                                              hour: hour, minute: minute, second: second)))
    }

    static func studyDay(_ zone: TimeZone) -> StudyDay { StudyDay(timeZone: zone, cutoffHour: 4) }

    static func sitting(_ zone: TimeZone, at now: Date, perDay: Int = 5, increase: Int = 0,
                        batch: Int = 10) -> SittingPlanner {
        SittingPlanner(studyDay: studyDay(zone), now: now, batchSize: batch, newCardsPerDay: perDay,
                       increaseToday: increase)
    }

    static func review(note: UUID = UUID(), due: Date, paused: Bool = false, hiddenUntil: Date? = nil) -> StudyCard {
        StudyCard(noteID: note, scheduled: ScheduledCard(
                      state: MemoryState(stability: 10, difficulty: 5), phase: .review,
                      lastReview: due.addingTimeInterval(-10 * 86_400), due: due),
                  isPaused: paused, hiddenUntil: hiddenUntil, createdAt: .distantPast)
    }

    static func fresh(note: UUID = UUID(), hiddenUntil: Date? = nil) -> StudyCard {
        StudyCard(noteID: note, hiddenUntil: hiddenUntil, createdAt: .distantPast)
    }

    static func candidates(_ cards: [StudyCard], introduced: Int = 0) -> SittingCandidates {
        SittingCandidates(cards: cards, introducedToday: introduced)
    }

    /// Reminders **on**, at `hour`:`minute`; everything else as recommended.
    static func on(hour: Int = 19, minute: Int = 0, showsCount: Bool = true, horizon: Int = 7,
                   later: TimeInterval = 2 * 3_600) -> ReminderSettings {
        ReminderSettings(isEnabled: true, hour: hour, minute: minute, showsPredictedCount: showsCount,
                         laterDelay: later, horizon: horizon)
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) throws -> ReminderDay {
        try #require(ReminderDay(year: year, month: month, day: day))
    }

    static func daily(_ day: ReminderDay) -> ReminderKey { ReminderKey(day: day, kind: .daily) }
    static func later(_ day: ReminderDay) -> ReminderKey { ReminderKey(day: day, kind: .later) }

    /// The plan for these inputs.
    static func plan(_ settings: ReminderSettings, _ sitting: SittingPlanner, _ cards: [StudyCard],
                     introduced: Int = 0, log: ReminderLog = ReminderLog()) -> ReminderPlan {
        ReminderPlanner.plan(settings: settings, sitting: sitting,
                             candidates: candidates(cards, introduced: introduced), log: log)
    }

    /// The actions an update releases once its log is written, by a writer that always succeeds.
    static func released(_ update: ReminderUpdate) -> [ReminderAction] {
        update.actions { _ in }
    }

    static func adds(_ update: ReminderUpdate) -> [PlannedReminder] {
        released(update).compactMap { action in
            guard case .add(let reminder) = action else { return nil }
            return reminder
        }
    }

    static func removals(_ update: ReminderUpdate) -> [String] {
        released(update).compactMap { action in
            guard case .removePending(let id) = action else { return nil }
            return id
        }
    }

    /// The log after each add in `update` succeeded and was recorded.
    static func afterAdding(_ update: ReminderUpdate) -> ReminderLog {
        adds(update).reduce(update.log) { log, reminder in log.recordingAdd(.added, of: reminder) }
    }
}

/// SplitMix64, seeded, so a failing round can be found again.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
