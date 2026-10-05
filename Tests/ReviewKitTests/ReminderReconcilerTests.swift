import Foundation
@testable import ReviewKit
import Testing

/// **Bringing the system's pending requests in line with the plan, through the log** (review-module-plan
/// §5.2, §5.4, WI-6).
///
/// The reconciler knows the system only as two lists of identifiers — pending and delivered — and
/// returns a new log and the actions it allows, **released only once that log is written**: no
/// reminder exists that the log does not know about. Once a request has been added it is never added
/// again after leaving the pending list, because the reconciler cannot tell a fire from a removal and a
/// delivered identifier re-added alerts the reader a second time.
struct ReminderReconcilerTests {
    private typealias F = ReminderFixture

    private func setting(_ zone: TimeZone) throws -> (today: ReminderKey, fireAt: Date, card: StudyCard) {
        (F.daily(try F.day(2026, 10, 20)), try F.local(zone, 10, 20, 19), F.review(due: try F.local(zone, 10, 19, 9)))
    }

    // MARK: - The protocol: intent, add, added

    /// **The intent is written before the add, and the add is released only after the write.** A log
    /// write that fails releases nothing; the writer sees the intents before any add exists; and an
    /// update that changes nothing in the log needs no write to release what it holds.
    @Test func aLogWriteThatFailsReleasesNothing() throws {
        let zone = try F.zone("UTC")
        let (today, _, card) = try setting(zone)
        let plan = F.plan(F.on(), F.sitting(zone, at: try F.local(zone, 10, 20, 8)), [card])
        let update = ReminderReconciler.reconcile(plan, log: ReminderLog(), pending: [], delivered: [])

        struct Refused: Error {}
        #expect(throws: Refused.self) { _ = try update.actions { _ in throw Refused() } }

        var written: [ReminderLog] = []
        let actions = update.actions { written.append($0) }
        #expect(written == [update.log], "the log was not written exactly once, first")
        #expect(written.first?[today] == .intent(try #require(plan.reminders.first).request))
        #expect(actions.count == 7 && actions.allSatisfy { if case .add = $0 { true } else { false } })

        // An unlogged pending request is removed without a log change, so nothing needs writing.
        let stray = ReminderReconciler.reconcile(F.plan(.recommended, F.sitting(zone, at: try F.local(zone, 10, 20, 8)), [card]),
                                                 log: ReminderLog(), pending: [today.identifier], delivered: [])
        var calls = 0
        #expect(stray.actions { _ in calls += 1 } == [.removePending(id: today.identifier)])
        #expect(calls == 0)
    }

    /// §5.4. **An added request missing from pending is gone, and never added again** — not when the
    /// next trigger still plans the day, not while its fire time is hours away. It left the list by
    /// firing, by the reader removing it, or by the system; the reconciler cannot tell which, and only
    /// one of those may be followed by another alert.
    @Test func anAddedRequestMissingFromPendingIsGoneAndNeverReadded() throws {
        let zone = try F.zone("UTC")
        let (today, fireAt, card) = try setting(zone)
        let morning = try F.local(zone, 10, 20, 8)
        let added = F.afterAdding(ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: morning), [card]),
                                                               log: ReminderLog(), pending: [], delivered: []))
        #expect(added[today] == .added(try #require(F.plan(F.on(), F.sitting(zone, at: morning), [card]).reminders.first).request))

        var log = added
        for hour in [9, 12, 18] {
            let now = try F.local(zone, 10, 20, hour)
            let update = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: now), [card], log: log),
                                                      log: log, pending: [], delivered: [])
            #expect(update.log[today] == .gone, "at \(hour):00")
            #expect(!F.adds(update).contains { $0.key == today }, "re-added at \(hour):00, before \(fireAt)")
            log = F.afterAdding(update)
        }
    }

    /// §5.4. **An intent with no add behind it is added again — only while its fire time is ahead.** The
    /// add never happened (or its mark was lost and the request is pending, which reads as added). Past
    /// the fire time it may have fired, so it is gone.
    @Test func anIntentWithoutAddIsReaddedOnlyBeforeItsFireTime() throws {
        let zone = try F.zone("UTC")
        let (today, fireAt, card) = try setting(zone)
        let morning = try F.local(zone, 10, 20, 8)
        let intents = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: morning), [card]),
                                                   log: ReminderLog(), pending: [], delivered: []).log
        let request = try #require(F.plan(F.on(), F.sitting(zone, at: morning), [card]).reminders.first).request
        #expect(intents[today] == .intent(request))

        let before = fireAt.addingTimeInterval(-1)
        let again = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: before), [card], log: intents),
                                                 log: intents, pending: [], delivered: [])
        #expect(F.adds(again).filter { $0.key == today }.map(\.request) == [request])
        #expect(again.log[today] == .intent(request))

        let lostMark = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: before), [card], log: intents),
                                                    log: intents, pending: [today.identifier], delivered: [])
        #expect(lostMark.log[today] == .added(request), "a pending request was not read as added")
        #expect(!F.adds(lostMark).contains { $0.key == today })

        for after in [fireAt, fireAt.addingTimeInterval(3_600)] {
            let late = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: after), [card], log: intents),
                                                    log: intents, pending: [], delivered: [])
            #expect(late.log[today] == .gone, "at \(after)")
            #expect(!F.adds(late).contains { $0.key == today })
        }
    }

    /// §5.4. **A failed add is retried at the next trigger, once.** The failure is recorded against
    /// the intent; the next reconcile writes a fresh intent and releases exactly one add for the day.
    @Test func aFailedAddIsRetriedOnceAtTheNextTrigger() throws {
        let zone = try F.zone("UTC")
        let (today, _, card) = try setting(zone)
        let morning = try F.local(zone, 10, 20, 8)
        let first = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: morning), [card]),
                                                 log: ReminderLog(), pending: [], delivered: [])
        let reminder = try #require(F.adds(first).first { $0.key == today })
        let failed = first.log.recordingAdd(.failed(at: morning), of: reminder)
        #expect(failed[today] == .failed(reminder.request, at: morning))

        let next = try F.local(zone, 10, 20, 9)
        let retry = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: next), [card], log: failed),
                                                 log: failed, pending: [], delivered: [])
        #expect(F.adds(retry).filter { $0.key == today }.count == 1)
        #expect(retry.log[today] == .intent(reminder.request))
        // And it succeeds this time.
        #expect(F.afterAdding(retry)[today] == .added(reminder.request))
    }

    // MARK: - Nothing askable

    /// §5.4. **A day with nothing askable at its fire time is not planned — and is planned as soon as
    /// work appears before it.** "Nothing askable" is written down, and is not a verdict.
    @Test func aZeroDayBecomesPlannedWhenWorkAppearsBeforeItsFireTime() throws {
        let zone = try F.zone("UTC")
        let (today, _, _) = try setting(zone)
        let morning = try F.local(zone, 10, 20, 8)
        let empty = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: morning), []),
                                                 log: ReminderLog(), pending: [], delivered: [])
        #expect(empty.log[today] == .notPlanned(.nothingAskable))
        #expect(F.released(empty).isEmpty)

        let noon = try F.local(zone, 10, 20, 12)
        let arrives = F.review(due: try F.local(zone, 10, 20, 18))
        let update = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: noon), [arrives], log: empty.log),
                                                  log: empty.log, pending: [], delivered: [])
        let added = try #require(F.adds(update).first { $0.key == today })
        #expect(added.content == .sittingReady(predictedCount: 1))
        #expect(update.log[today] == .intent(added.request))
    }

    /// §5.4. **Nothing askable is never terminal.** A pending reminder whose sitting empties — the
    /// reader paused the cards — is removed, and it can never have fired: it was pending with its fire
    /// time ahead. So when work returns before that time, it is added again.
    @Test func nothingAskableIsNeverTerminal() throws {
        #expect(ReminderLog.State.notPlanned(.nothingAskable).isTerminal == false)
        let zone = try F.zone("UTC")
        let (today, _, card) = try setting(zone)
        let morning = try F.local(zone, 10, 20, 8)
        let added = F.afterAdding(ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: morning), [card]),
                                                               log: ReminderLog(), pending: [], delivered: []))
        let pending = Set(added.entries.keys.map(\.identifier))

        let noon = try F.local(zone, 10, 20, 12)
        let emptied = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: noon), [], log: added),
                                                   log: added, pending: pending, delivered: [])
        #expect(F.removals(emptied).contains(today.identifier))
        #expect(emptied.log[today] == .notPlanned(.nothingAskable))

        let afternoon = try F.local(zone, 10, 20, 15)
        let back = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: afternoon), [card], log: emptied.log),
                                                log: emptied.log, pending: [], delivered: [])
        #expect(F.adds(back).contains { $0.key == today }, "a day that was empty for an hour stayed closed")
    }

    // MARK: - Closed days, passed fire times, strays

    /// §5.4. **A skipped day is never planned again**, however much work appears and however many
    /// triggers come; its pending request is removed; the other days are untouched.
    @Test func aSkippedDayIsNeverReplanned() throws {
        let zone = try F.zone("UTC")
        let (today, _, card) = try setting(zone)
        let morning = try F.local(zone, 10, 20, 8)
        let added = F.afterAdding(ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: morning), [card]),
                                                               log: ReminderLog(), pending: [], delivered: []))
        var log = added.withdrawing(today.day, .skipped)
        var pending = Set(added.entries.keys.map(\.identifier))
        let more = (0..<6).map { _ in F.fresh() } + [card]
        for hour in [9, 13, 17, 18] {
            let plan = F.plan(F.on(), F.sitting(zone, at: try F.local(zone, 10, 20, hour)), more, log: log)
            // The plan itself leaves the day out — it is what a surface reads "the next reminder" from —
            // and does not call it empty either.
            #expect(!plan.reminders.contains { $0.key.day == today.day }, "planned at \(hour):00")
            #expect(!plan.nothingAskable.contains { $0.day == today.day })
            let update = ReminderReconciler.reconcile(plan, log: log, pending: pending, delivered: [])
            #expect(!F.adds(update).contains { $0.key.day == today.day }, "at \(hour):00")
            #expect(update.log[today] == .withdrawn(.skipped))
            pending.subtract(F.removals(update))
            log = F.afterAdding(update)
        }
        #expect(!pending.contains(today.identifier), "the skipped day's request stayed pending")
        #expect(pending.count == 6, "the other days were touched: \(pending.sorted())")
    }

    /// **A pending request whose fire time has passed is removed and gone — no catch-up** (§5.1, R3).
    /// Asleep through 19:00, the system may still hold it; delivering it at 23:00 on wake would be a
    /// catch-up nobody approved.
    @Test func aPendingRequestPastItsFireTimeIsRemovedNotCaughtUp() throws {
        let zone = try F.zone("UTC")
        let (today, _, card) = try setting(zone)
        let added = F.afterAdding(ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: try F.local(zone, 10, 20, 8)), [card]),
                                                               log: ReminderLog(), pending: [], delivered: []))
        let wake = try F.local(zone, 10, 20, 23)
        let update = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: wake), [card], log: added),
                                                  log: added, pending: Set(added.entries.keys.map(\.identifier)),
                                                  delivered: [])
        #expect(F.removals(update) == [today.identifier])
        #expect(update.log[today] == .gone)
    }

    /// **A delivered identifier is gone, whatever the log believed** — an intent whose mark was lost,
    /// a failure that was not one — so nothing re-adds a request the reader has already seen.
    @Test func aDeliveredIdentifierIsGoneWhateverTheLogSaid() throws {
        let zone = try F.zone("UTC")
        let (today, fireAt, card) = try setting(zone)
        let request = ReminderRequest(fireAt: fireAt, content: .sittingReady(predictedCount: 1))
        let later = try F.local(zone, 10, 20, 18)
        for state in [ReminderLog.State.intent(request), .failed(request, at: later), .notPlanned(.nothingAskable)] {
            let log = ReminderLog(entries: [today: state], laterAsked: [:])
            let update = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: later), [card], log: log),
                                                      log: log, pending: [], delivered: [today.identifier])
            #expect(update.log[today] == .gone, "\(state)")
            #expect(!F.adds(update).contains { $0.key == today }, "\(state)")
        }
    }

    /// **A pending request the log does not know is removed, never adopted.** The log is written before
    /// every add, so one exists only if that write was lost; it is taken out rather than trusted, and
    /// the next trigger adds the day through the protocol.
    @Test func anUnloggedPendingRequestIsRemovedNotAdopted() throws {
        let zone = try F.zone("UTC")
        let (today, _, card) = try setting(zone)
        let noon = try F.local(zone, 10, 20, 12)
        let update = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: noon), [card]),
                                                  log: ReminderLog(), pending: [today.identifier], delivered: [])
        #expect(F.removals(update) == [today.identifier])
        #expect(!F.adds(update).contains { $0.key == today })
        #expect(update.log[today] == nil)
        let next = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: noon), [card], log: update.log),
                                                log: update.log, pending: [], delivered: [])
        #expect(F.adds(next).contains { $0.key == today })
    }

    /// **A changed count replaces the pending request**, so N stays what a sitting at the fire time
    /// would hold (§5.1: every write re-plans). The log already records a request under the identifier,
    /// so nothing is written first; the success records the new one, and a failure leaves the old one —
    /// still pending — recorded, so the next trigger tries again.
    @Test func aChangedCountReplacesThePendingRequest() throws {
        let zone = try F.zone("UTC")
        let (today, _, card) = try setting(zone)
        let added = F.afterAdding(ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: try F.local(zone, 10, 20, 8)), [card]),
                                                               log: ReminderLog(), pending: [], delivered: []))
        let pending = Set(added.entries.keys.map(\.identifier))
        let noon = try F.local(zone, 10, 20, 12)
        let more = [card, F.review(due: try F.local(zone, 10, 20, 11))]
        let update = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: noon), more, log: added),
                                                  log: added, pending: pending, delivered: [])
        let replacement = try #require(F.adds(update).first { $0.key == today })
        #expect(replacement.content == .sittingReady(predictedCount: 2))
        #expect(update.log == added, "a replacement wrote to the log before its add")
        #expect(update.log.recordingAdd(.added, of: replacement)[today] == .added(replacement.request))
        let failed = update.log.recordingAdd(.failed(at: noon), of: replacement)
        let retry = ReminderReconciler.reconcile(F.plan(F.on(), F.sitting(zone, at: noon), more, log: failed),
                                                 log: failed, pending: pending, delivered: [])
        #expect(F.adds(retry).contains(replacement))
    }

    // MARK: - The prefix

    /// §5.4. **Only `review.` identifiers are touched**, and every one of them is accounted for. Other
    /// requests — another feature's, a near-miss spelling — are neither removed nor recorded; an
    /// identifier under the prefix that names no planned day is removed, malformed or not.
    @Test func theReconcilerTouchesOnlyItsOwnPrefix() throws {
        let zone = try F.zone("UTC")
        let (today, _, card) = try setting(zone)
        let foreign: Set<String> = ["com.xiaolaidict.other", "reviewing.2026-10-20", "Review.2026-10-20",
                                    "review", "xreview.2026-10-20", ""]
        let ours: Set<String> = ["review.garbage", "review.2026-13-40", "review.2026-10-20.weekly"]
        let plan = F.plan(F.on(), F.sitting(zone, at: try F.local(zone, 10, 20, 8)), [card])
        let update = ReminderReconciler.reconcile(plan, log: ReminderLog(), pending: foreign.union(ours),
                                                  delivered: foreign)
        let touched = Set(F.released(update).map { action -> String in
            switch action {
            case .add(let reminder): reminder.id
            case .removePending(let id), .removeDelivered(let id): id
            }
        })
        #expect(touched.isDisjoint(with: foreign), "\(touched.intersection(foreign))")
        #expect(touched.allSatisfy { $0.hasPrefix(ReminderKey.prefix) })
        #expect(Set(F.removals(update)) == ours)
        #expect(F.adds(update).contains { $0.key == today })
        #expect(update.log.entries.keys.allSatisfy { $0.day >= today.day }, "\(update.log.entries.keys.sorted())")
    }

    // MARK: - A fixpoint

    /// **Reconciling what a reconcile left changes nothing.** Once the adds are in and recorded, the
    /// same plan over the same system releases no action and writes no log — so a trigger that fires
    /// twice, or a re-plan with nothing new, is free and harmless.
    @Test func reconcilingWhatAReconcileLeftChangesNothing() throws {
        let zone = try F.zone("America/New_York")
        let now = try F.local(zone, 10, 30, 10)
        let cards = [F.review(due: try F.local(zone, 10, 29, 9)), F.review(due: try F.local(zone, 11, 2, 9)), F.fresh()]
        let plan = F.plan(F.on(hour: 1, minute: 30), F.sitting(zone, at: now), cards)
        let first = ReminderReconciler.reconcile(plan, log: ReminderLog(), pending: ["other"], delivered: [])
        let log = F.afterAdding(first)
        let pending = Set(F.adds(first).map(\.id)).union(["other"])
        let second = ReminderReconciler.reconcile(F.plan(F.on(hour: 1, minute: 30), F.sitting(zone, at: now), cards, log: log),
                                                  log: log, pending: pending, delivered: [])
        #expect(F.released(second).isEmpty, "\(F.released(second))")
        #expect(second.log == log)
        var writes = 0
        _ = second.actions { _ in writes += 1 }
        #expect(writes == 0)
    }

    // MARK: - One banner a day, undisturbed

    /// **Left alone, every study day gets its reminder, once** — the other half of "at most": a
    /// protocol that never delivered anything would pass every test of excess. A fortnight in New York
    /// across the fall-back night, re-planned every hour as a running app would, with work always
    /// waiting: one delivery per study day at the reader's time, including 01:30, before the cutoff.
    @Test(arguments: [(19, 0), (1, 30)])
    func anUndisturbedFortnightDeliversOneReminderEachStudyDay(_ time: (hour: Int, minute: Int)) throws {
        let zone = try F.zone("America/New_York")
        let settings = F.on(hour: time.hour, minute: time.minute)
        let card = F.review(due: try F.local(zone, 10, 1, 9))
        var world = SimulatedCenter()
        var generator = SeededGenerator(state: 1)
        var log = ReminderLog()
        let start = try F.local(zone, 10, 24, 9)
        var clock = start
        for _ in 0..<(14 * 24) {
            clock.addTimeInterval(3_600)
            world.fire(upTo: clock, holdingSome: false, using: &generator)
            let plan = ReminderPlanner.plan(settings: settings, sitting: F.sitting(zone, at: clock),
                                            candidates: F.candidates([card]), log: log)
            let update = ReminderReconciler.reconcile(plan, log: log, pending: world.pendingIDs,
                                                      delivered: world.deliveredIDs)
            log = F.afterAdding(update)
            world.performReliably(update)
        }
        // Study days whose fire instant fell inside the fortnight, after the first hour.
        var expected: [String] = []
        var day = ReminderDay(studyDayContaining: start, in: F.studyDay(zone))
        while let fireAt = ReminderPlanner.fireInstant(of: F.daily(day), settings: settings,
                                                       studyDay: F.studyDay(zone), log: log), fireAt <= clock {
            if fireAt > start.addingTimeInterval(3_600) { expected.append(F.daily(day).identifier) }
            day = try #require(day.adding(days: 1))
        }
        #expect(expected.count >= 13, "\(expected)")
        #expect(world.shown.filter { $0.key.hasPrefix(ReminderKey.prefix) } == Dictionary(uniqueKeysWithValues: expected.map { ($0, 1) }),
                "\(world.shown.sorted { $0.key < $1.key })")
    }

    // MARK: - Two banners at most

    /// §5.4. **At most two banners a study day, one of them unrequested** — over sixty simulated months
    /// of New York autumn, across the fall-back night, against a notification center that fires on
    /// time or late, loses requests, lets the reader dismiss and choose Later, Skip or a sitting, and a
    /// process that crashes before recording an add, fails to add, and fails to write its log. The
    /// reader moves the fire time and turns reminders off and on. Every delivered identifier is
    /// counted; none may be delivered twice, nothing is ever added at or before now, and nothing but
    /// `review.` identifiers is touched.
    @Test func atMostTwoBannersPerStudyDay() throws {
        let zone = try F.zone("America/New_York")
        let studyDay = F.studyDay(zone)
        var generator = SeededGenerator(state: 20_261_101)
        var totals = (daily: 0, later: 0, adds: 0, lostAhead: 0)
        for run in 0..<60 {
            var world = SimulatedCenter()
            var clock = try F.local(zone, 10, 24, 9).addingTimeInterval(TimeInterval(run) * 3_600)
            var settings = F.on(hour: Int.random(in: 0...23, using: &generator))
            var log = ReminderLog()
            var cards: [StudyCard] = []
            for step in 0..<200 {
                clock.addTimeInterval(TimeInterval(Int.random(in: 300...18_000, using: &generator)))
                let asleep = Int.random(in: 0..<5, using: &generator) == 0
                world.fire(upTo: clock, holdingSome: asleep, using: &generator)
                world.dismissSome(using: &generator)
                if Int.random(in: 0..<20, using: &generator) == 0 { world.loseOnePending(at: clock, using: &generator) }

                // The reader: Later, Skip or a sitting, from a delivered daily reminder.
                if let shown = world.deliveredDaily(), let key = ReminderKey(identifier: shown) {
                    switch Int.random(in: 0..<6, using: &generator) {
                    case 0, 1, 2:
                        if case .asked(let update) = log.askingLater(on: key.day, at: clock, settings: settings,
                                                                    studyDay: studyDay) {
                            log = world.perform(update, failingWrites: false, using: &generator) ?? log
                        }
                    case 3: log = log.withdrawing(key.day, .skipped)
                    case 4: log = log.withdrawing(key.day, .satToday)
                    default: break
                    }
                }
                // The ledger moves, and now and then the settings do.
                if Int.random(in: 0..<6, using: &generator) == 0 {
                    cards = (0..<Int.random(in: 1...3, using: &generator)).map { _ in
                        F.review(due: clock.addingTimeInterval(TimeInterval(Int.random(in: -86_400...200_000, using: &generator))))
                    }
                }
                if !settings.isEnabled {
                    // Off for a step or two, then back on: off-and-on is the case, not a long silence.
                    if Bool.random(using: &generator) { settings = F.on(hour: settings.hour, minute: settings.minute) }
                } else {
                    switch Int.random(in: 0..<14, using: &generator) {
                    case 0: settings = F.on(hour: Int.random(in: 0...23, using: &generator),
                                            minute: Int.random(in: 0...59, using: &generator))
                    case 1: settings = ReminderSettings(isEnabled: false, hour: settings.hour, minute: settings.minute)
                    default: break
                    }
                }

                let plan = ReminderPlanner.plan(settings: settings, sitting: F.sitting(zone, at: clock),
                                                candidates: F.candidates(cards), log: log)
                let update = ReminderReconciler.reconcile(plan, log: log, pending: world.pendingIDs,
                                                          delivered: world.deliveredIDs)
                for reminder in F.adds(update) {
                    #expect(reminder.fireAt > clock, "run \(run) step \(step): \(reminder.id) added in the past")
                }
                log = world.perform(update, failingWrites: true, using: &generator) ?? log
            }
            #expect(world.foreignUntouched, "run \(run): a foreign request was touched")
            for (id, count) in world.shown where count > 1 {
                Issue.record("run \(run): \(id) was delivered \(count) times")
            }
            totals.daily += world.shown.keys.count { !$0.hasSuffix(".later") && $0.hasPrefix(ReminderKey.prefix) }
            totals.later += world.shown.keys.count { $0.hasSuffix(".later") }
            totals.adds += world.adds
            totals.lostAhead += world.lostAhead
        }
        // **The simulation exercised what it claims to**, or sixty clean runs prove nothing. The seed is
        // fixed, so the counts are too — 369 daily, 69 Later, 545 lost before their fire time on
        // 2026-10-04 — and each floor sits at two thirds of its count. Most simulated days end without a
        // banner by design: nothing askable at the fire time, a request lost, a time moved past, a held
        // request removed on waking. `anUndisturbedFortnightDeliversOneReminderEachStudyDay` is the
        // other half: left alone, every day gets exactly one.
        #expect(totals.daily > 245, "\(totals)")
        #expect(totals.later > 45, "\(totals)")
        #expect(totals.lostAhead > 360, "\(totals)")
    }
}

/// **A notification center as the reconciler sees it**: pending requests by identifier, a delivered
/// list the reader can clear, and a count of every delivery — plus one foreign request of another
/// feature's, pending and delivered, that nothing may touch.
private struct SimulatedCenter {
    private static let foreign = "com.xiaolaidict.another-feature"
    private var pending: [String: Date] = [foreign: .distantFuture]
    private var delivered: Set<String> = [foreign]
    private(set) var shown: [String: Int] = [:]
    private(set) var adds = 0
    /// Pending requests the system lost before their fire time — where adding them again is the
    /// tempting mistake, since nothing can tell this from a fire.
    private(set) var lostAhead = 0

    var pendingIDs: Set<String> { Set(pending.keys) }
    var deliveredIDs: Set<String> { delivered }
    var foreignUntouched: Bool { pending[Self.foreign] == .distantFuture && delivered.contains(Self.foreign) }

    /// Fires what is due; asleep, some of it is held until later.
    mutating func fire(upTo now: Date, holdingSome asleep: Bool, using generator: inout SeededGenerator) {
        for (id, fireAt) in pending.sorted(by: { $0.key < $1.key }) where fireAt <= now {
            if asleep, Bool.random(using: &generator) { continue }
            pending[id] = nil
            delivered.insert(id)
            shown[id, default: 0] += 1
        }
    }

    mutating func dismissSome(using generator: inout SeededGenerator) {
        for id in delivered.sorted() where id != Self.foreign && Int.random(in: 0..<3, using: &generator) == 0 {
            delivered.remove(id)
        }
    }

    mutating func loseOnePending(at now: Date, using generator: inout SeededGenerator) {
        guard let id = pending.keys.filter({ $0 != Self.foreign }).sorted().randomElement(using: &generator) else { return }
        if let fireAt = pending[id], fireAt > now { lostAhead += 1 }
        pending[id] = nil
    }

    func deliveredDaily() -> String? {
        delivered.sorted().first { $0.hasPrefix(ReminderKey.prefix) && !$0.hasSuffix(".later") }
    }

    /// Performs what an update releases, every write and every add succeeding.
    mutating func performReliably(_ update: ReminderUpdate) {
        for action in update.actions(afterPersisting: { _ in }) {
            switch action {
            case .removePending(let id): pending[id] = nil
            case .removeDelivered(let id): delivered.remove(id)
            case .add(let reminder):
                pending[reminder.id] = reminder.fireAt
                adds += 1
            }
        }
    }

    /// Writes the update's log — which may fail — and performs what it releases; each add may fail, or
    /// succeed with its outcome lost to a crash. Returns the log as it now stands, or nil if the write
    /// failed and nothing changed.
    mutating func perform(_ update: ReminderUpdate, failingWrites: Bool,
                          using generator: inout SeededGenerator) -> ReminderLog? {
        struct WriteFailed: Error {}
        let fails = failingWrites && Int.random(in: 0..<10, using: &generator) == 0
        guard let actions = try? update.actions(afterPersisting: { _ in if fails { throw WriteFailed() } }) else {
            return nil
        }
        var log = update.log
        for action in actions {
            switch action {
            case .removePending(let id): pending[id] = nil
            case .removeDelivered(let id): delivered.remove(id)
            case .add(let reminder):
                switch Int.random(in: 0..<10, using: &generator) {
                case 0:
                    log = log.recordingAdd(.failed(at: reminder.fireAt.addingTimeInterval(-1)), of: reminder)
                case 1:
                    pending[reminder.id] = reminder.fireAt  // added; the crash lost the record
                    adds += 1
                default:
                    pending[reminder.id] = reminder.fireAt
                    adds += 1
                    log = log.recordingAdd(.added, of: reminder)
                }
            }
        }
        return log
    }
}
