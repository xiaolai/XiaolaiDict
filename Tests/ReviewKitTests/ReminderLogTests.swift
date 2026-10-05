import Foundation
@testable import ReviewKit
import Testing

/// **The reminder log: one state per study day and kind, and the transitions between them**
/// (review-module-plan §5.2, WI-6).
///
/// Notification Center is not a history, so this is. Every transition is a pure function returning a
/// new log; the reconciler's are in `ReminderReconcilerTests`, the reader's and the add outcomes here.
struct ReminderLogTests {
    private typealias F = ReminderFixture

    // MARK: - Later

    /// §5.4. **Later is the reader's request: once a study day, under its own identifier**, at +2 h,
    /// and it takes the delivered original away. The original is gone from the log at once, so nothing
    /// re-adds it; the Later is planned and added like any reminder, as `review.<day>.later`; and a
    /// second Later the same study day — from the Later banner itself — is refused.
    @Test func laterOncePerDayUnderItsOwnIdentifier() throws {
        let zone = try F.zone("UTC")
        let day = try F.day(2026, 10, 20)
        let card = F.review(due: try F.local(zone, 10, 19, 9))
        let atSeven = try F.local(zone, 10, 20, 8)
        let first = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: atSeven), [card]),
                                                 log: ReminderLog(), pending: [], delivered: [])
        let delivered = F.afterAdding(first)

        let asked = try F.local(zone, 10, 20, 19, 5, 30)
        guard case .asked(let update) = delivered.askingLater(on: day, at: asked.addingTimeInterval(0.25),
                                                              settings: F.on(), studyDay: F.studyDay(zone))
        else { Issue.record("Later was refused"); return }
        let laterAt = try F.local(zone, 10, 20, 21, 5, 30)
        #expect(update.log.laterAsked[day] == laterAt, "two hours on, in whole seconds")
        #expect(update.log[F.daily(day)] == .gone, "the original could be re-added")
        #expect(F.released(update) == [.removeDelivered(id: "review.2026-10-20")])

        let plan = F.plan(F.on(), F.sitting(zone, at: asked), [card], log: update.log)
        let later = try #require(plan.reminders.first { $0.key == F.later(day) })
        #expect(later.id == "review.2026-10-20.later")
        #expect(later.fireAt == laterAt)
        #expect(later.content == .sittingReady(predictedCount: 1))
        #expect(!plan.reminders.contains { $0.key == F.daily(day) })
        let added = ReminderReconciler.reconcile(plan, log: update.log, pending: [], delivered: [])
        #expect(F.adds(added).map(\.id).contains("review.2026-10-20.later"))

        let again = F.afterAdding(added).askingLater(on: day, at: laterAt.addingTimeInterval(60),
                                                     settings: F.on(), studyDay: F.studyDay(zone))
        #expect(again == .refused(.alreadyAsked))
    }

    /// **A lost log costs today, and only today** (WI-8). Today's daily reminder may have been
    /// delivered and dismissed with nothing left to say so, so `lost(today:)` closes both of today's
    /// kinds; every other day is as an empty log leaves it. Planned against it, a time moved later
    /// today adds nothing for today and everything after it; Later is refused for today.
    @Test func aLostLogSpendsTodayAndNothingElse() throws {
        let zone = try F.zone("Asia/Shanghai")
        let today = try F.day(2026, 10, 20)
        let lost = ReminderLog.lost(today: today)
        #expect(lost[F.daily(today)] == .gone && lost[F.later(today)] == .gone)
        #expect(lost.entries.count == 2 && lost.laterAsked.isEmpty)

        let evening = try F.local(zone, 10, 20, 19, 30)
        let card = F.review(due: try F.local(zone, 10, 19, 9))
        let plan = F.plan(F.on(hour: 21), F.sitting(zone, at: evening), [card], log: lost)
        #expect(!plan.reminders.contains { $0.key.day == today }, "a second banner was planned for today")
        #expect(plan.reminders.map(\.key) == (1..<7).compactMap { today.adding(days: $0) }.map(F.daily),
                "the days ahead were not planned")
        // **The control**: an empty log plans today's 21:00 — the second banner `lost` exists to refuse.
        let empty = F.plan(F.on(hour: 21), F.sitting(zone, at: evening), [card])
        #expect(empty.reminders.first?.key == F.daily(today))
        #expect(lost.askingLater(on: today, at: evening, settings: F.on(), studyDay: F.studyDay(zone))
                == .refused(.alreadyAsked))
    }

    /// §5.4. **Later is dropped if it would land in the next study day** — at its start or after. With
    /// the 04:00 cutoff, asking at 01:59:59 lands at 03:59:59 and stands; at 02:00 it would land on the
    /// next day's first instant. Across New York's fall-back night the day is 25 hours long, so asking
    /// at the second 01:30 still lands inside it.
    @Test func laterNeverCrossesIntoTheNextStudyDay() throws {
        let utc = try F.zone("UTC")
        let day = try F.day(2026, 10, 20)
        func ask(_ instant: Date, _ zone: TimeZone, on day: ReminderDay) -> LaterOutcome {
            ReminderLog().askingLater(on: day, at: instant, settings: F.on(), studyDay: F.studyDay(zone))
        }
        if case .refused(let why) = ask(try F.local(utc, 10, 21, 1, 59, 59), utc, on: day) {
            Issue.record("refused at 01:59:59: \(why)")
        }
        #expect(ask(try F.local(utc, 10, 21, 2), utc, on: day) == .refused(.crossesIntoTheNextStudyDay))
        #expect(ask(try F.local(utc, 10, 21, 3), utc, on: day) == .refused(.crossesIntoTheNextStudyDay))
        #expect(ask(try F.local(utc, 10, 22, 9), utc, on: day) == .refused(.crossesIntoTheNextStudyDay),
                "a banner answered the next morning")

        let newYork = try F.zone("America/New_York")
        let secondOneThirty = Date(timeIntervalSince1970: 1_793_511_000 + 3_600)
        let saturday = try F.day(2026, 10, 31)
        guard case .asked(let update) = ask(secondOneThirty, newYork, on: saturday) else {
            Issue.record("refused inside the 25-hour day"); return
        }
        #expect(update.log.laterAsked[saturday] == secondOneThirty.addingTimeInterval(7_200))
        #expect(ask(secondOneThirty.addingTimeInterval(3_600), newYork, on: saturday)
                    == .refused(.crossesIntoTheNextStudyDay))

        // **Checked again when planned**: an instant past its own day in the planning zone — a zone
        // changed since it was asked — is not planned.
        let stray = ReminderLog(entries: [:], laterAsked: [day: try F.local(utc, 10, 21, 5)])
        let plan = F.plan(F.on(), F.sitting(utc, at: try F.local(utc, 10, 20, 20)),
                          [F.review(due: try F.local(utc, 10, 19, 9))], log: stray)
        #expect(!plan.reminders.contains { $0.key == F.later(day) }, "\(plan.reminders.map(\.id))")
    }

    /// **Later is refused with its reason**: reminders off, the day withdrawn, or asked already.
    @Test func laterIsRefusedWithItsReason() throws {
        let zone = try F.zone("UTC")
        let day = try F.day(2026, 10, 20)
        let instant = try F.local(zone, 10, 20, 19, 5)
        let studyDay = F.studyDay(zone)
        #expect(ReminderLog().askingLater(on: day, at: instant, settings: .recommended, studyDay: studyDay)
                    == .refused(.remindersOff))
        #expect(ReminderLog().withdrawing(day, .skipped).askingLater(on: day, at: instant, settings: F.on(),
                                                                    studyDay: studyDay) == .refused(.dayWithdrawn))
        let asked = ReminderLog(entries: [:], laterAsked: [day: try F.local(zone, 10, 20, 21)])
        #expect(asked.askingLater(on: day, at: instant, settings: F.on(), studyDay: studyDay) == .refused(.alreadyAsked))
    }

    // MARK: - Withdrawn by the reader

    /// **Skip today, and the reader's sitting, close both of the day's reminders** — terminal, and
    /// never over another terminal state: a delivered reminder stays gone.
    @Test func aWithdrawalClosesBothKindsAndNeverReopensATerminalOne() throws {
        let day = try F.day(2026, 10, 20), other = try F.day(2026, 10, 21)
        let request = ReminderRequest(fireAt: Date(timeIntervalSince1970: 1_792_522_800),
                                      content: .sittingReady(predictedCount: 3))
        let log = ReminderLog(entries: [F.daily(day): .added(request), F.daily(other): .added(request)],
                              laterAsked: [:])
        let skipped = log.withdrawing(day, .skipped)
        #expect(skipped[F.daily(day)] == .withdrawn(.skipped))
        #expect(skipped[F.later(day)] == .withdrawn(.skipped), "a skipped day could still take a Later")
        #expect(skipped[F.daily(other)] == .added(request), "another day was touched")
        #expect(skipped[F.daily(day)]?.isTerminal == true)

        let gone = ReminderLog(entries: [F.daily(day): .gone], laterAsked: [:])
        #expect(gone.withdrawing(day, .satToday)[F.daily(day)] == .gone)
        #expect(gone.withdrawing(day, .satToday)[F.later(day)] == .withdrawn(.satToday))
    }

    // MARK: - The outcome of an add

    /// **intent → added on success, failed on failure**; a failed replacement leaves the request that
    /// is still pending recorded, so the next trigger tries again; and nothing reopens a terminal state.
    @Test func anAddsOutcomeIsRecordedAgainstTheIntent() throws {
        let key = F.daily(try F.day(2026, 10, 20))
        let zone = try F.zone("UTC")
        let fireAt = try F.local(zone, 10, 20, 19)
        let reminder = PlannedReminder(key: key, fireAt: fireAt, zone: zone, content: .sittingReady(predictedCount: 4))
        let failedAt = fireAt.addingTimeInterval(-3_600)
        let intent = ReminderLog(entries: [key: .intent(reminder.request)], laterAsked: [:])

        #expect(intent.recordingAdd(.added, of: reminder)[key] == .added(reminder.request))
        #expect(intent.recordingAdd(.failed(at: failedAt), of: reminder)[key] == .failed(reminder.request, at: failedAt))

        let old = ReminderRequest(fireAt: fireAt, content: .sittingReady(predictedCount: 2))
        let replacing = ReminderLog(entries: [key: .added(old)], laterAsked: [:])
        #expect(replacing.recordingAdd(.added, of: reminder)[key] == .added(reminder.request))
        #expect(replacing.recordingAdd(.failed(at: failedAt), of: reminder)[key] == .added(old),
                "a failed replacement forgot the request still pending")

        for terminal in [ReminderLog.State.gone, .withdrawn(.skipped)] {
            let closed = ReminderLog(entries: [key: terminal], laterAsked: [:])
            #expect(closed.recordingAdd(.added, of: reminder)[key] == terminal)
            #expect(closed.recordingAdd(.failed(at: failedAt), of: reminder)[key] == terminal)
        }
    }

    // MARK: - Off and on again

    /// **Turning reminders off withdraws every open day, with its pending request, in one update; turning
    /// them on reopens exactly those.**
    ///
    /// The plan's table makes `withdrawn(.disabled)` terminal. Read literally, off-then-on would silence
    /// every day the horizon had already planned — up to seven — with no transition able to revive them.
    /// So it lasts while reminders are off, the only time a plan consults it, and the reconciler writes
    /// it in the same update that removes the pending request: the log first, the removal released only
    /// after it, so a day is never marked withdrawn over a request still waiting to fire. A delivered
    /// day is gone and stays gone; a skipped one stays skipped.
    @Test func turningRemindersOffAndOnReopensOnlyWhatOffClosed() throws {
        let zone = try F.zone("UTC")
        let card = F.review(due: try F.local(zone, 10, 19, 9))
        let morning = try F.local(zone, 10, 20, 8)
        let first = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: morning), [card]),
                                                 log: ReminderLog(), pending: [], delivered: [])
        let today = F.daily(try F.day(2026, 10, 20)), tomorrow = F.daily(try F.day(2026, 10, 21))
        let skippedDay = try F.day(2026, 10, 22)
        let on = F.afterAdding(first).withdrawing(skippedDay, .skipped)
        // 19:00 has fired; the other six wait.
        let pending = Set(F.adds(first).map(\.id)).subtracting([today.identifier])

        let evening = try F.local(zone, 10, 20, 20)
        let offSettings = ReminderSettings(isEnabled: false, hour: 19)
        let off = ReminderReconciler.reconcile(F.plan(offSettings, F.sitting(zone, at: evening), [card], log: on),
                                               log: on, pending: pending, delivered: [today.identifier])
        #expect(off.log[today] == .gone)
        #expect(off.log[tomorrow] == .withdrawn(.disabled))
        #expect(off.log[F.daily(skippedDay)] == .withdrawn(.skipped))
        #expect(Set(F.removals(off)) == pending, "turning off left a request to fire")
        #expect(ReminderLog.State.withdrawn(.disabled).isTerminal == false)
        struct Refused: Error {}
        #expect(throws: Refused.self) { _ = try off.actions { _ in throw Refused() } }

        let again = ReminderReconciler.reconcile(F.plan(offSettings, F.sitting(zone, at: evening), [card], log: off.log),
                                                 log: off.log, pending: [], delivered: [])
        #expect(F.released(again).isEmpty && again.log == off.log, "a plan made while off reopened something")

        let onAgain = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: evening), [card], log: off.log),
                                                   log: off.log, pending: [], delivered: [])
        #expect(Set(F.adds(onAgain).map(\.key.day)) == Set((21...26).map { try? F.day(2026, 10, $0) }.compactMap { $0 })
                    .subtracting([skippedDay]))
        #expect(onAgain.log[today] == .gone)
        #expect(onAgain.log[F.daily(skippedDay)] == .withdrawn(.skipped))
    }

    // MARK: - Kept between launches

    /// §5.4. **The log decodes what a later version wrote**: extra fields at every level are ignored,
    /// and anything this version cannot read in full — an unknown state, a reason it does not know, a
    /// request missing its instant — reads as **gone**: terminal, never re-added. Failing closed costs a
    /// reminder; failing open could cost a second banner. A record that names no readable day or kind
    /// cannot be placed, and is passed over.
    @Test func theLogDecodesWithFieldsALaterVersionAdds() throws {
        let zone = try F.zone("UTC")
        let day = try F.day(2026, 10, 20), next = try F.day(2026, 10, 21)
        let fireAt = try F.local(zone, 10, 20, 19)
        let request = ReminderRequest(fireAt: fireAt, content: .sittingReady(predictedCount: 3))
        let quiet = ReminderRequest(fireAt: fireAt, content: .sittingReady(predictedCount: nil))
        let log = ReminderLog(entries: [
            F.daily(day): .added(request), F.later(day): .intent(quiet),
            F.daily(next): .failed(request, at: fireAt.addingTimeInterval(-60)),
            F.later(next): .notPlanned(.nothingAskable),
            F.daily(try F.day(2026, 10, 19)): .gone, F.later(try F.day(2026, 10, 19)): .withdrawn(.satToday),
        ], laterAsked: [day: fireAt.addingTimeInterval(7_200)])
        let encoded = try JSONEncoder().encode(log)
        #expect(try JSONDecoder().decode(ReminderLog.self, from: encoded) == log)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("\"3\""), "a count stored as text")

        let seconds = fireAt.timeIntervalSince1970
        let later = Data("""
            {"version": 9, "entries": [
              {"day": "2026-10-20", "kind": "daily", "state": "added", "fireAt": \(seconds),
               "content": {"case": "sittingReady", "predictedCount": 3, "tone": "gentle"}, "addedBy": "v9"},
              {"day": "2026-10-20", "kind": "later", "state": "snoozed", "fireAt": \(seconds)},
              {"day": "2026-10-21", "kind": "daily", "state": "withdrawn", "reason": "onHoliday"},
              {"day": "2026-10-21", "kind": "later", "state": "intent"},
              {"day": "2026-10-22", "kind": "daily", "state": "added", "fireAt": \(seconds),
               "content": {"case": "streakAtRisk"}},
              {"day": "2026-10-22", "kind": "weekly", "state": "gone"},
              {"day": "22 October", "kind": "daily", "state": "gone"},
              "not a record", null, 7,
              {"day": "2026-10-23", "kind": "daily", "state": "notPlanned", "reason": "nothingAskable"}
            ], "later": [{"day": "2026-10-20", "fireAt": \(seconds + 7_200), "askedFrom": "watch"}, {"day": 5}],
            "aFieldFromLater": true}
            """.utf8)
        let read = try JSONDecoder().decode(ReminderLog.self, from: later)
        #expect(read[F.daily(day)] == .added(request), "extra fields broke a readable record")
        #expect(read[F.later(day)] == .gone, "an unknown state was read as open")
        #expect(read[F.daily(next)] == .gone, "an unknown withdrawal was read as open")
        #expect(read[F.later(next)] == .gone, "an intent with no request was read as open")
        #expect(read[F.daily(try F.day(2026, 10, 22))] == .gone, "an unknown content was read as open")
        #expect(read[F.daily(try F.day(2026, 10, 23))] == .notPlanned(.nothingAskable))
        #expect(read.entries.count == 6, "\(read.entries.keys.sorted())")
        #expect(read.laterAsked == [day: fireAt.addingTimeInterval(7_200)])

        #expect(try JSONDecoder().decode(ReminderLog.self, from: Data("{}".utf8)) == ReminderLog())
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ReminderLog.self, from: Data("[]".utf8)) }
    }

    /// **A list that is there and is not a list is an unreadable log, not an empty one** (audit-fix
    /// round 1). `{"entries": true}` decoded as a log with nothing in it — a valid log that had never
    /// added today — so the store did not treat it as lost, and a later time added a second banner.
    /// Thrown, the store reads it unreadable and plans `lost(today:)`. An absent list is still empty.
    @Test func aListThatIsNotAListIsAnUnreadableLog() throws {
        for damaged in [#"{"entries": true}"#, #"{"entries": null}"#, #"{"entries": {"day": "2026-10-20"}}"#,
                        #"{"entries": [], "later": 5}"#, #"{"entries": [], "later": "2026-10-20"}"#] {
            #expect(throws: (any Error).self, "\(damaged) read as a log") {
                try JSONDecoder().decode(ReminderLog.self, from: Data(damaged.utf8))
            }
        }
        // **The controls**: an empty list, and no list at all, are an empty log.
        for empty in [#"{"entries": []}"#, #"{"entries": [], "later": []}"#, #"{"later": []}"#] {
            #expect(try JSONDecoder().decode(ReminderLog.self, from: Data(empty.utf8)) == ReminderLog())
        }
    }

    /// **Kept for fourteen study days, today included** (§5.2): the reconciler prunes as it writes. A
    /// day thirteen back stays; fourteen back is dropped; the days ahead stay. Later's asks likewise.
    @Test func theLogIsPrunedToFourteenStudyDays() throws {
        let zone = try F.zone("UTC")
        let today = try F.day(2026, 10, 20)
        let kept = try F.day(2026, 10, 7), dropped = try F.day(2026, 10, 6), ahead = try F.day(2026, 10, 26)
        let instant = try F.local(zone, 10, 1, 12)
        let log = ReminderLog(entries: [F.daily(kept): .gone, F.daily(dropped): .gone, F.later(dropped): .gone,
                                        F.daily(ahead): .withdrawn(.skipped)],
                              laterAsked: [kept: instant, dropped: instant])
        let pruned = log.pruned(today: today)
        #expect(Set(pruned.entries.keys) == [F.daily(kept), F.daily(ahead)])
        #expect(Set(pruned.laterAsked.keys) == [kept])

        let plan = F.plan(F.on(), F.sitting(zone, at: try F.local(zone, 10, 20, 8)), [], log: log)
        let written = ReminderReconciler.reconcile(plan, log: log, pending: [], delivered: []).log
        #expect(written[F.daily(dropped)] == nil && written[F.daily(kept)] == .gone)
        #expect(ReminderRecommendation.retainedStudyDays == 14)
    }

    // MARK: - Identifiers

    /// **One spelling each way**: `review.<yyyy-MM-dd>` and `review.<yyyy-MM-dd>.later`, read back
    /// strictly. The system's list is input from outside, so anything else under the prefix — another
    /// spelling of a date, a date the calendar does not have, a suffix this version does not know — is
    /// not a key, and the reconciler removes it as unplanned.
    @Test func identifiersAreSpelledOneWayAndReadBackStrictly() throws {
        let day = try F.day(2026, 3, 8)
        #expect(F.daily(day).identifier == "review.2026-03-08")
        #expect(F.later(day).identifier == "review.2026-03-08.later")
        #expect(ReminderKey(identifier: "review.2026-03-08") == F.daily(day))
        #expect(ReminderKey(identifier: "review.2026-03-08.later") == F.later(day))
        for wrong in ["review.2026-3-8", "review.2026-03-08.daily", "review.2026-02-30", "review.2026-13-01",
                      "review.2026-03-08.later.later", "review.2026-03-08 ", "Review.2026-03-08", "review.",
                      "review", "reviewing.2026-03-08", "review.２０２６-03-08", "review.+026-03-08"] {
            #expect(ReminderKey(identifier: wrong) == nil, "\(wrong)")
        }
        #expect(ReminderDay(year: 2026, month: 2, day: 29) == nil, "2026 is not a leap year")
        #expect(ReminderDay(year: 2028, month: 2, day: 29) != nil)
        // Every day of two years survives the round trip.
        var cursor = try F.day(2026, 1, 1)
        for _ in 0..<730 {
            #expect(ReminderKey(identifier: F.later(cursor).identifier) == F.later(cursor))
            cursor = try #require(cursor.adding(days: 1))
        }
        #expect(cursor == (try F.day(2028, 1, 1)))
    }
}
