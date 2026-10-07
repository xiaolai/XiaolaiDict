import AppKit
import Foundation
import ReviewKit
import StudyKit
@testable import StudyModels
import StudyPresentation
import Testing
import UserNotifications
import XiaolaiDictUI
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **The reminder, from the ledger to the system's notification center** (review-module-plan §5.3,
/// §5.4, WI-7).
///
/// `ReminderPlannerTests`, `ReminderLogTests` and `ReminderReconcilerTests` prove the rules on values.
/// These prove the wire, against `FakeReminderCenter` — never the real center, which aborts a process
/// with no bundle: what asks the reader for permission and what never does, what a re-plan reads and
/// when it runs, that the log is written before anything reaches the system, and that a click on a
/// banner reaches the Library on Review.
@MainActor
struct ReminderWiringTests {
    private static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private static let newYork = TimeZone(identifier: "America/New_York")!

    /// 10:00 on Monday 5 October 2026 in Shanghai — before that study day's 19:00 reminder.
    private let now = instant(2026, 10, 5, 10, 0, in: shanghai)

    private static func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                                in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                         in zone: TimeZone = shanghai) -> Date {
        Self.instant(year, month, day, hour, minute, in: zone)
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> ReminderDay {
        ReminderDay(year: year, month: month, day: day)!
    }

    private static let today = day(2026, 10, 5)
    private static let todayID = "review.2026-10-05"

    // MARK: - Fixture

    /// One meaning saved ten days ago and never reviewed: a new card, askable today within the allowance.
    @discardableResult
    private func saved(_ ledger: Ledger, _ word: String = "laconic") throws -> StudyNote {
        try Wiring.save(ledger, word, at: now.addingTimeInterval(-10 * 86_400))
    }

    private struct Rig {
        let coordinator: ReminderCoordinator
        let center: FakeReminderCenter
        let defaults: UserDefaults
        let log: Box<ReminderLog>
        let clock: Box<Date>
        let zone: Box<TimeZone>
        let system: NotificationCenter
        let workspace: NotificationCenter
        let changes: LedgerChanges
        let opened: Box<Int>
    }

    /// A coordinator over a scratch ledger and the fake center, with every trigger its own: a private
    /// notification center for the zone and the clock, another for wake, and a ledger-change counter
    /// nothing else commits to.
    private func rig(_ path: String, grant: NotificationGrant = .granted, enabled: Bool = true,
                     failingLog: Bool = false, events: EventLog = EventLog(),
                     settings: ReminderSettings? = nil) -> Rig {
        let defaults = TemporaryDefaults.suite()
        if enabled || settings != nil {
            ReminderSettingsStore(defaults: defaults).save(settings ?? ReminderSettings(isEnabled: true))
        }
        let center = FakeReminderCenter(grant: grant, events: events)
        let log = Box(ReminderLog())
        let clock = Box(now), zone = Box(Self.shanghai), opened = Box(0)
        let system = NotificationCenter(), workspace = NotificationCenter(), changes = LedgerChanges()
        let coordinator = ReminderCoordinator(
            scheduling: center, defaults: defaults,
            logStore: .memory(log, events: events, failing: failingLog),
            store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
            clock: { clock.value }, zone: { zone.value },
            openReview: { opened.value += 1; return true },
            triggers: ReminderTriggers(system: system, workspace: workspace, ledger: changes,
                                       studyDictionary: { "noad" }),
            ledgerSettle: .zero)
        return Rig(coordinator: coordinator, center: center, defaults: defaults, log: log, clock: clock,
                   zone: zone, system: system, workspace: workspace, changes: changes, opened: opened)
    }

    // MARK: - Who asks

    /// **No trigger asks the reader anything; the toggle does.** Settings that say "on" without a grant
    /// — written by the end-to-end stage, or left by a reader who later revoked it — are planned as off:
    /// nothing is added and the system prompt is never raised, whatever re-plans. Then the Settings
    /// toggle asks, once, and only it.
    @Test func theToggleIsTheOnlyThingThatAsks() async throws {
        let (path, clean) = Wiring.scratch("reminder-asks")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path, grant: .notAsked)
        let reminders = rig.coordinator
        reminders.start()
        defer { reminders.stop() }

        await reminders.replan(.launch)
        let before = reminders.passCount
        rig.system.post(name: .NSSystemTimeZoneDidChange, object: nil)
        rig.system.post(name: .NSSystemClockDidChange, object: nil)
        rig.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        rig.changes.committed()
        try await Wiring.settle("the triggers never re-planned") { reminders.passCount >= before + 4 }
        await reminders.sittingAnswered()
        await reminders.respond(.later(Self.today))
        await reminders.respond(.skip(Self.today))
        await reminders.refreshAccess()

        #expect(rig.center.requests == 0, "something other than the toggle raised the system prompt")
        #expect(rig.center.added.isEmpty, "a reminder was added without a grant")
        #expect(rig.center.probes > 0, "nothing ever asked what the grant was")
        #expect(reminders.access == .notAsked)

        await reminders.setEnabled(true)
        #expect(rig.center.requests == 1, "the toggle did not ask")
        #expect(reminders.access == .granted)
        #expect(reminders.settings.isEnabled)
        #expect(!rig.center.added.isEmpty, "granted, the toggle's re-plan added nothing")
        #expect(rig.center.pendingByID[Self.todayID] == nil, "the day skipped above was planned again")
    }

    /// **A declined grant is never asked again.** macOS will not show the prompt a second time, so a
    /// request would be a click that does nothing; the switch stays off and the reason is the access.
    @Test func aDeclinedGrantNeverReasks() async throws {
        let (path, clean) = Wiring.scratch("reminder-declined")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path, grant: .declined, enabled: false)
        let reminders = rig.coordinator

        await reminders.setEnabled(true)
        await reminders.setEnabled(true)
        await reminders.replan(.launch)

        #expect(rig.center.requests == 0, "a declined grant was asked again")
        #expect(!reminders.settings.isEnabled, "the switch went on over a declined grant")
        #expect(!ReminderSettingsStore(defaults: rig.defaults).load().isEnabled)
        #expect(reminders.access == .declined)
        #expect(rig.center.added.isEmpty)

        // The control: never asked, the same toggle asks once — so the zero above is about the grant.
        let fresh = self.rig(path, grant: .notAsked, enabled: false)
        await fresh.coordinator.setEnabled(true)
        #expect(fresh.center.requests == 1)
    }

    /// **A reader who has never turned reminders on is not a client of the notification center at
    /// all.** Off by default (R3), and with nothing in the log, no trigger reads a list, probes the
    /// grant, registers actions or sets the delegate.
    @Test func remindersThatWereNeverOnTouchNothing() async throws {
        let (path, clean) = Wiring.scratch("reminder-dormant")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path, enabled: false)
        rig.coordinator.listen()
        rig.coordinator.start()
        defer { rig.coordinator.stop() }
        #expect(await rig.coordinator.replan(.launch) == .dormant)
        rig.changes.committed()
        try await Wiring.settle { rig.coordinator.passCount >= 2 }

        #expect(rig.center.probes == 0)
        #expect(rig.center.reads == 0)
        #expect(rig.center.registrations == 0)
        #expect(rig.center.listener == nil, "the delegate was set for reminders nobody turned on")
        #expect(rig.log.value == ReminderLog())
        #expect(!ReminderSettings.recommended.isEnabled, "R3: off until the reader turns them on")
    }

    // MARK: - What a sitting does to today

    /// **The last card askable at today's fire time, graded, withdraws today's reminder, and the request
    /// with it.** Graded through the Review window's own model, whose commit hook is the one the app
    /// wires. Remembered sends the only card two days on, so nothing is askable at 19:00: the plan
    /// records the day `notPlanned(.nothingAskable)` — open, not closed (WI-8).
    @Test func gradingTheLastAskableCardWithdrawsTodaysReminder() async throws {
        let (path, clean) = Wiring.scratch("reminder-sat")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path)
        let reminders = rig.coordinator
        await reminders.replan(.launch)
        #expect(rig.center.pendingByID[Self.todayID]?.fireAt == instant(2026, 10, 5, 19, 0))

        let review = ReviewModel(store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
                                 clock: { self.now }, defaults: rig.defaults,
                                 graded: { reminders.answered() }, finish: {}, openInDictionary: { _ in false })
        await review.start()
        review.act(.grade(.good))
        let key = ReminderKey(day: Self.today, kind: .daily)
        try await Wiring.settle("today's reminder was never withdrawn") {
            rig.log.value[key] == .notPlanned(.nothingAskable) && rig.center.pendingByID[Self.todayID] == nil
        }
        #expect(rig.center.removedPending.contains(Self.todayID))
        #expect(rig.coordinator.lastPass?.reason == .sat, "the grade did not re-plan at once")
    }

    /// **"Nothing askable now" is not "nothing askable at 19:00"** (WI-8). Forgot on the only new card
    /// at 10:00 sends it to learning, due at 10:10 — so nothing is askable the moment the grade lands,
    /// and the card is back long before the reminder fires. Today's 19:00 must stand, counting it; a
    /// terminal withdrawal written from the instant of the grade closed it for the rest of the day.
    @Test func aForgottenNewCardKeepsTodaysReminder() async throws {
        let (path, clean) = Wiring.scratch("reminder-forgot")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path)
        let reminders = rig.coordinator
        await reminders.replan(.launch)
        #expect(rig.center.pendingByID[Self.todayID]?.fireAt == instant(2026, 10, 5, 19, 0))

        let review = ReviewModel(store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
                                 clock: { self.now }, defaults: rig.defaults,
                                 graded: { reminders.answered() }, finish: {}, openInDictionary: { _ in false })
        await review.start()
        review.act(.grade(.again))
        try await Wiring.settle("the grade never reached the coordinator") { reminders.answerCount > 0 }
        await reminders.replan(.ledger)

        // The pinned kernel: Forgot on a new card is learning, ten minutes on.
        let ledger = try Ledger(path: path)
        let card = try #require(try ledger.notes().compactMap { try ledger.existingCard(of: $0.id) }.first)
        #expect(card.scheduled.phase == .learning)
        #expect(card.scheduled.due == now.addingTimeInterval(600))
        let key = ReminderKey(day: Self.today, kind: .daily)
        #expect(rig.log.value[key]?.isTerminal != true, "today was closed: \(String(describing: rig.log.value[key]))")
        let standing = try #require(rig.center.pendingByID[Self.todayID], "today's 19:00 was removed")
        #expect(standing.fireAt == instant(2026, 10, 5, 19, 0))
        #expect(standing.content == .sittingReady(predictedCount: 1), "the card back at 10:10 is not counted")
    }

    /// The control: a grade that leaves work keeps today's reminder, so the withdrawal above is the
    /// last card's and not every grade's.
    @Test func aGradeThatLeavesWorkKeepsTodaysReminder() async throws {
        let (path, clean) = Wiring.scratch("reminder-not-sat")
        defer { clean() }
        let ledger = try Ledger(path: path)
        try saved(ledger, "laconic")
        try saved(ledger, "ephemeral")
        let rig = rig(path)
        let reminders = rig.coordinator
        await reminders.replan(.launch)

        let review = ReviewModel(store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
                                 clock: { self.now }, defaults: rig.defaults,
                                 graded: { reminders.answered() }, finish: {}, openInDictionary: { _ in false })
        await review.start()
        let passes = reminders.passCount
        review.act(.grade(.good))
        try await Wiring.settle("the grade never reached the coordinator") { reminders.answerCount > 0 }
        await reminders.replan(.ledger)
        #expect(reminders.passCount > passes)
        #expect(rig.log.value[ReminderKey(day: Self.today, kind: .daily)] != .withdrawn(.satToday))
        #expect(rig.center.pendingByID[Self.todayID] != nil, "a sitting with work left withdrew today's reminder")
    }

    // MARK: - The log first

    /// **A log that cannot be written schedules nothing** (§5.2): no reminder exists the log does not
    /// know about. Fail closed, and said.
    @Test func aLogWriteFailureSchedulesNothing() async throws {
        let (path, clean) = Wiring.scratch("reminder-unwritten")
        defer { clean() }
        try saved(try Ledger(path: path))
        let broken = rig(path, failingLog: true)
        #expect(await broken.coordinator.replan(.launch) == .logNotWritten)
        #expect(broken.center.added.isEmpty, "a reminder was added with no log entry behind it")
        #expect(broken.center.removedPending.isEmpty)

        // The control: the same ledger and settings with a log that can be written.
        let working = rig(path)
        #expect(await working.coordinator.replan(.launch) == .applied(added: 7, failed: 0, removed: 0))
        #expect(!working.center.added.isEmpty)
    }

    /// **A lost log never adds a second unrequested banner to today** (WI-8). Today's 19:00 is delivered
    /// and dismissed, so Notification Center lists it nowhere and only the log knows the day had one.
    /// Then the log is lost — deleted, or replaced by something that does not read — and the reader
    /// moves the time to 21:00. A log read as empty planned today again: a second banner.
    @Test func aLostLogDoesNotAddASecondBannerToday() async throws {
        let (path, clean) = Wiring.scratch("reminder-lost-log")
        defer { clean() }
        try saved(try Ledger(path: path))
        let losses: [(String, (UserDefaults) -> Void)] = [
            ("deleted", { $0.removeObject(forKey: ReminderLogStore.key) }),
            ("unreadable", { $0.set(Data("not a reminder log".utf8), forKey: ReminderLogStore.key) }),
        ]
        for (how, lose) in losses {
            let defaults = TemporaryDefaults.suite()
            let center = FakeReminderCenter(grant: .granted)
            let clock = Box(now)
            let reminders = ReminderCoordinator(
                scheduling: center, defaults: defaults, store: Wiring.store(path),
                primary: { PrimaryDictionary(chosen: "noad") }, clock: { clock.value }, zone: { Self.shanghai },
                triggers: ReminderTriggers(system: NotificationCenter(), workspace: NotificationCenter(),
                                           ledger: LedgerChanges(), studyDictionary: { "noad" }),
                ledgerSettle: .zero)
            // **The positive control**: turned on at 10:00 over no log at all — a first use — today's
            // 19:00 is planned.
            await reminders.setEnabled(true)
            #expect(center.pendingByID[Self.todayID]?.fireAt == instant(2026, 10, 5, 19, 0), "\(how)")

            // 19:00: delivered. 19:30: dismissed, and the pass that follows records the day gone.
            center.deliver(Self.todayID)
            clock.value = instant(2026, 10, 5, 19, 30)
            center.delivered.remove(Self.todayID)
            await reminders.replan(.wake)
            #expect(ReminderLogStore.suite(defaults).read().log?[ReminderKey(day: Self.today, kind: .daily)] == .gone)

            lose(defaults)
            reminders.setTime(hour: 21, minute: 0)
            await reminders.replan(.settings)
            await reminders.replan(.settings)
            let todays = center.added.filter { $0.id == Self.todayID }
            #expect(todays.count == 1, "\(how): today was added \(todays.count) times — a second banner")
            #expect(center.pendingByID[Self.todayID] == nil, "\(how): a second request for today is pending")
            // **What a lost log costs is today, and no more**: tomorrow is planned at the new time.
            #expect(center.pendingByID["review.2026-10-06"]?.fireAt == instant(2026, 10, 6, 21, 0), "\(how)")
        }
    }

    /// **Disabling writes the withdrawal and removes the pending requests together — the log first.**
    @Test func disablingRemovesEveryPendingRequestAndWritesTheLogFirst() async throws {
        let (path, clean) = Wiring.scratch("reminder-disable")
        defer { clean() }
        try saved(try Ledger(path: path))
        let events = EventLog()
        let rig = rig(path, events: events)
        let reminders = rig.coordinator
        await reminders.replan(.launch)
        let planned = Set(rig.center.pendingByID.keys)
        #expect(planned.count == ReminderRecommendation.horizon)

        await reminders.setEnabled(false)
        #expect(rig.center.pendingByID.isEmpty, "turned off, requests were left pending")
        #expect(Set(rig.center.removedPending) == planned)
        for id in planned {
            let key = try #require(ReminderKey(identifier: id))
            #expect(rig.log.value[key] == .withdrawn(.disabled), "\(id)")
        }
        let firstRemoval = try #require(events.entries.firstIndex { $0.hasPrefix("remove") })
        #expect(events.entries[..<firstRemoval].last == "save", "a request was removed before the log said so")

        // And off plans nothing, whatever re-plans.
        let adds = rig.center.added.count
        await reminders.replan(.launch)
        #expect(rig.center.added.count == adds)
    }

    // MARK: - Re-plan triggers

    /// **A change of zone re-plans, and the requests follow it.** The study day's 19:00 is now New
    /// York's, so the pending request for 5 October is replaced by one pinned there.
    @Test func aTimeZoneChangeReplans() async throws {
        let (path, clean) = Wiring.scratch("reminder-zone")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path)
        let reminders = rig.coordinator
        reminders.start()
        defer { reminders.stop() }
        try await Wiring.settle("the launch never re-planned") { reminders.passCount >= 1 }
        #expect(rig.center.pendingByID[Self.todayID]?.zone == Self.shanghai)

        // The control: the zone moving is not by itself a re-plan.
        rig.zone.value = Self.newYork
        let before = reminders.passCount
        #expect(rig.center.pendingByID[Self.todayID]?.zone == Self.shanghai)

        rig.system.post(name: .NSSystemTimeZoneDidChange, object: nil)
        try await Wiring.settle("a zone change did not re-plan") { reminders.passCount > before }
        let moved = try #require(rig.center.pendingByID[Self.todayID])
        #expect(moved.zone == Self.newYork)
        #expect(moved.fireAt == instant(2026, 10, 5, 19, 0, in: Self.newYork))
        #expect(rig.center.pendingByID.values.allSatisfy { $0.zone == Self.newYork })
    }

    /// **A change of clock re-plans.** Moved past two fire times, those requests are gone — nothing
    /// catches up — and the horizon's new day is added.
    @Test func aClockChangeReplans() async throws {
        let (path, clean) = Wiring.scratch("reminder-clock")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path)
        let reminders = rig.coordinator
        reminders.start()
        defer { reminders.stop() }
        try await Wiring.settle("the launch never re-planned") { reminders.passCount >= 1 }
        #expect(rig.center.pendingByID["review.2026-10-12"] == nil)

        rig.clock.value = instant(2026, 10, 6, 20, 0)
        let before = reminders.passCount
        rig.system.post(name: .NSSystemClockDidChange, object: nil)
        try await Wiring.settle("a clock change did not re-plan") { reminders.passCount > before }
        #expect(rig.center.pendingByID[Self.todayID] == nil)
        #expect(rig.center.pendingByID["review.2026-10-06"] == nil)
        #expect(rig.log.value[ReminderKey(day: Self.today, kind: .daily)] == .gone)
        #expect(rig.center.pendingByID["review.2026-10-12"] != nil, "the horizon's new day was not added")
    }

    /// Waking and a ledger change re-plan too — the other two system triggers.
    @Test func wakingAndALedgerChangeReplan() async throws {
        let (path, clean) = Wiring.scratch("reminder-wake")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path)
        rig.coordinator.start()
        defer { rig.coordinator.stop() }
        try await Wiring.settle { rig.coordinator.passCount >= 1 }
        rig.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Wiring.settle("waking did not re-plan") { rig.coordinator.lastPass?.reason == .wake }
        rig.changes.committed()
        try await Wiring.settle("a ledger change did not re-plan") { rig.coordinator.lastPass?.reason == .ledger }
    }

    // MARK: - The trigger

    /// **The trigger is pinned to the planning zone, not the process's** (§5.1). The coordinator hands
    /// the center reminders planned in Shanghai while this process runs in another zone, and the
    /// request the delivery builds from one is a calendar trigger with that zone set and that instant
    /// as its next date.
    @Test func theTriggerCarriesThePlanningZone() async throws {
        let (path, clean) = Wiring.scratch("reminder-trigger")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path)
        await rig.coordinator.replan(.launch)
        let reminder = try #require(rig.center.pendingByID[Self.todayID])
        #expect(rig.center.added.allSatisfy { $0.zone == Self.shanghai })

        let request = ReminderDelivery.request(for: reminder)
        #expect(request.identifier == Self.todayID)
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.dateComponents.timeZone == Self.shanghai)
        #expect(!trigger.repeats)
        // **The components, not `nextTriggerDate()`.** That is computed against the real clock, so the
        // test passed only until 19:00 on the planned day and failed on every day after. The instant the
        // request carries is the planned one, in the planning zone.
        let components = trigger.dateComponents
        #expect([components.year, components.month, components.day, components.hour, components.minute]
            == [2026, 10, 5, 19, 0])
    }

    // MARK: - Later and Skip Today

    /// **Later, from the delivered banner**: the original is taken out of Notification Center, and a
    /// request of its own is added two hours on.
    @Test func laterAddsItsOwnRequestAndRemovesTheOriginal() async throws {
        let (path, clean) = Wiring.scratch("reminder-later")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path)
        await rig.coordinator.replan(.launch)
        rig.center.deliver(Self.todayID)
        rig.clock.value = instant(2026, 10, 5, 19, 5)

        await rig.coordinator.respond(.later(Self.today))
        #expect(rig.center.removedDelivered == [Self.todayID])
        let later = try #require(rig.center.pendingByID["review.2026-10-05.later"])
        #expect(later.fireAt == instant(2026, 10, 5, 21, 5))
        #expect(rig.log.value[ReminderKey(day: Self.today, kind: .daily)] == .gone)
    }

    /// **How long Later waits is chosen in Settings, and Later waits that long** (R3, 2026-10-05).
    /// Through the choice the section draws: kept in the app's suite, re-planned at once, and the
    /// request Later adds is an hour on — not the two hours recommended.
    @Test func laterWaitsTheDelayChosenInSettings() async throws {
        let (path, clean) = Wiring.scratch("reminder-later-delay")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path)
        await rig.coordinator.replan(.launch)
        #expect(rig.coordinator.choice.settings.laterDelay == ReminderRecommendation.laterDelay, "the default")

        let passes = rig.coordinator.passCount
        rig.coordinator.choice.setLaterDelay(3_600)
        try await Wiring.settle("choosing how long Later waits did not re-plan") {
            rig.coordinator.passCount > passes && rig.coordinator.lastPass?.reason == .settings
        }
        #expect(ReminderSettingsStore(defaults: rig.defaults).load().laterDelay == 3_600, "not kept in the suite")
        #expect(rig.coordinator.choice.settings.laterDelay == 3_600, "Settings still shows the old choice")

        rig.center.deliver(Self.todayID)
        rig.clock.value = instant(2026, 10, 5, 19, 5)
        await rig.coordinator.respond(.later(Self.today))
        let later = try #require(rig.center.pendingByID["review.2026-10-05.later"])
        #expect(later.fireAt == instant(2026, 10, 5, 20, 5), "Later waited \(later.fireAt), not the hour chosen")
    }

    /// **Only a delay Settings can offer is kept.** Anything else is a caller's mistake: refused, logged,
    /// and the reader's choice left as it was — never a delay the picker cannot show.
    @Test func aLaterDelaySettingsDoesNotOfferIsRefused() async throws {
        let (path, clean) = Wiring.scratch("reminder-later-stray")
        defer { clean() }
        // Off, so the re-plan the valid choice starts is the dormant one and reads no ledger.
        let rig = rig(path, enabled: false)
        rig.coordinator.choice.setLaterDelay(3_600)
        rig.coordinator.choice.setLaterDelay(5)
        #expect(ReminderSettingsStore(defaults: rig.defaults).load().laterDelay == 3_600)
    }

    /// **The delegate is done only once the answer is written** (audit-fix round 1). The listener the
    /// coordinator handed over queued the answer in a `Task` and returned, so the system's delegate call
    /// finished — and a quit app launched for Later could be let go — before Later was in the log.
    @Test func aBannersAnswerIsWrittenBeforeTheDelegateIsDone() async throws {
        let (path, clean) = Wiring.scratch("reminder-answer")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path)
        await rig.coordinator.replan(.launch)
        rig.coordinator.listen()
        let listener = try #require(rig.center.listener, "the coordinator set no delegate")
        rig.center.deliver(Self.todayID)
        rig.clock.value = instant(2026, 10, 5, 19, 5)
        await listener(.later(Self.today))
        #expect(rig.log.value.laterAsked[Self.today] != nil, "the delegate was done before Later was written")
        #expect(rig.center.pendingByID["review.2026-10-05.later"] != nil)
    }

    /// **A grant given back re-plans** (audit-fix round 1). Declined, the plan is the off plan and today's
    /// request is removed; the reader allows notifications again in System Settings and comes back, the
    /// section asks the grant again — and the switch said on while nothing was pending until some other
    /// trigger happened to run, which on a quiet evening is the next study day.
    @Test func aGrantGivenBackReplans() async throws {
        let (path, clean) = Wiring.scratch("reminder-regrant")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path)
        await rig.coordinator.replan(.launch)
        #expect(rig.center.pendingByID[Self.todayID] != nil, "a control: granted, today is pending")
        rig.center.grant = .declined
        await rig.coordinator.replan(.wake)
        #expect(rig.center.pendingByID[Self.todayID] == nil, "a control: declined, today is withdrawn")

        rig.center.grant = .granted
        await rig.coordinator.refreshAccess()
        #expect(rig.coordinator.access == .granted)
        try await Wiring.settle("a grant given back did not re-plan") { rig.center.pendingByID[Self.todayID] != nil }
        // **And one that did not change re-plans nothing.**
        let passes = rig.coordinator.passCount
        await rig.coordinator.refreshAccess()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.coordinator.passCount == passes, "asking an unchanged grant re-planned")
    }

    /// **Skip Today closes the day**: withdrawn, and nothing pending for it.
    @Test func skipTodayClosesTheDay() async throws {
        let (path, clean) = Wiring.scratch("reminder-skip")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path)
        await rig.coordinator.replan(.launch)
        await rig.coordinator.respond(.skip(Self.today))
        #expect(rig.log.value[ReminderKey(day: Self.today, kind: .daily)] == .withdrawn(.skipped))
        #expect(rig.center.pendingByID[Self.todayID] == nil)
        await rig.coordinator.replan(.launch)
        #expect(rig.center.pendingByID[Self.todayID] == nil, "a skipped day was planned again")
    }

    // MARK: - The banner, clicked

    /// **A click on the banner reaches the Library on Review**, through the delegate the coordinator
    /// sets once there is anything to click.
    @Test func aClickedBannerOpensReview() async throws {
        let (path, clean) = Wiring.scratch("reminder-click")
        defer { clean() }
        try saved(try Ledger(path: path))
        let rig = rig(path)
        await rig.coordinator.replan(.launch)
        rig.coordinator.listen()
        let respond = try #require(rig.center.listener, "the delegate was never set")
        await respond(.open)
        #expect(rig.opened.value == 1, "the click's delegate call ended before Review was opened")
    }

    /// **The route waits for the window actions**: a click that launches the app arrives before the
    /// menu-bar label has handed them over, and must open Review once they come rather than nothing.
    @Test func aRouteArrivingBeforeWindowActionsWaitsForThem() async throws {
        let wired = Box(false), opened = Box(0), faults = Box<[String]>([])
        // **The limit is generous because this is the success path**: the route returns the moment the actions are
        // wired, so the limit only decides how long a starved main actor may take to notice. At the shipped five seconds
        // this failed in a full run on a busy machine, the whole suite having slowed to twice its usual time, with the
        // wait itself taking 11 s; the bound is for the sibling test below, which is about *not* getting them.
        let route = ReviewRoute(areWired: { wired.value }, open: { opened.value += 1; return true },
                                fault: { faults.value.append($0) }, limit: .seconds(120))
        let routing = Task { await route.open() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(opened.value == 0, "Review was opened before there was a window action to open it with")
        wired.value = true
        #expect(await routing.value)
        #expect(opened.value == 1)
        #expect(faults.value.isEmpty)
    }

    /// **A route that never gets them says so, and opens nothing.** `.fault`, and `false` — never a
    /// silent no-op that reads as a window that opened.
    @Test func aRouteThatNeverGetsWindowActionsLogsAFault() async {
        let opened = Box(0), faults = Box<[String]>([])
        let route = ReviewRoute(areWired: { false }, open: { opened.value += 1; return true },
                                fault: { faults.value.append($0) }, limit: .milliseconds(200))
        #expect(await route.open() == false)
        #expect(opened.value == 0)
        #expect(faults.value.count == 1)
    }

    // MARK: - The app's wire

    /// **The app builds the coordinator over the reader's ledger and the center it was given, and the
    /// Review window's grades reach it.** Real clock and zone: what is asserted holds at any hour.
    @Test func theAppWiresTheCoordinatorAndTheReviewWindowToIt() async throws {
        let (path, clean) = Wiring.scratch("reminder-app")
        defer { clean() }
        try Wiring.save(try Ledger(path: path), "laconic", at: Date.now.addingTimeInterval(-10 * 86_400))
        let suite = TemporaryDefaults.suite()
        ReminderSettingsStore(defaults: suite).save(ReminderSettings(isEnabled: true))
        let center = FakeReminderCenter(grant: .granted)
        let app = XiaolaiDictApp(defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()),
                                 models: .temporary(defaults: suite), reminders: center)
        app.lookupRecorder.start { try LedgerStore(path: path) }

        let outcome = await app.reminders.replan(.launch)
        guard case .applied(let added, _, _) = outcome, added > 0 else {
            Issue.record("the app's coordinator did not plan from its ledger: \(outcome)")
            return
        }
        await app.reviewModel.start()
        let answered = app.reminders.answerCount
        app.reviewModel.act(.grade(.good))
        try await Wiring.settle("the Review window's grade never reached the coordinator") {
            app.reminders.answerCount > answered && app.reminders.lastPass?.reason == .sat
        }
    }

    /// **Choosing another study dictionary re-plans** (audit-fix round 1). The plan counts the primary's
    /// cards, and changing it wrote no ledger row, so the reminders went on counting the old dictionary's
    /// until some other trigger ran. Here the old one has nothing and the new one a card due today; the
    /// triggers are the test's own, so no other test's ledger change can re-plan in its place.
    @Test func choosingAnotherStudyDictionaryReplans() async throws {
        let (path, clean) = Wiring.scratch("reminder-primary")
        defer { clean() }
        try saved(try Ledger(path: path))
        let defaults = TemporaryDefaults.suite()
        ReminderSettingsStore(defaults: defaults).save(ReminderSettings(isEnabled: true))
        let chosen = ChosenDictionary(key: "another")
        let center = FakeReminderCenter(grant: .granted)
        let reminders = ReminderCoordinator(
            scheduling: center, defaults: defaults, logStore: .memory(Box(ReminderLog())),
            store: Wiring.store(path), primary: { PrimaryDictionary(chosen: chosen.key) },
            clock: { self.now }, zone: { Self.shanghai },
            triggers: ReminderTriggers(system: NotificationCenter(), workspace: NotificationCenter(),
                                       ledger: LedgerChanges(), studyDictionary: { chosen.key }),
            ledgerSettle: .zero)
        reminders.start()
        defer { reminders.stop() }
        try await Wiring.settle("the first pass never ran") { reminders.passCount >= 1 }
        #expect(center.pendingByID[Self.todayID] == nil, "a control: the other dictionary has nothing to ask")

        chosen.key = "noad"
        try await Wiring.settle("choosing another study dictionary never re-planned") {
            reminders.lastPass?.reason == .studyDictionary
        }
        #expect(center.pendingByID[Self.todayID]?.content == .sittingReady(predictedCount: 1))
    }

    /// The study dictionary, as the app's `StudyDictionary.chosen` holds it: observable.
    @Observable @MainActor final class ChosenDictionary {
        var key: String?
        init(key: String?) { self.key = key }
    }

    /// The lines no test can call: launching sets the delegate before launch finishes, starts the
    /// triggers after, and production hands over the real center.
    @Test func theRunningAppSetsTheDelegateBeforeLaunchFinishes() throws {
        let app = try source("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        let start = try #require(app.range(of: "override convenience init()"))
        #expect(app[start.lowerBound...].prefix(400).contains("reminders: ReminderDelivery()"),
                "init() does not hand over the real notification center")
        let willFinish = try #require(app.range(of: "func applicationWillFinishLaunching("))
        let didFinish = try #require(app.range(of: "func applicationDidFinishLaunching("))
        #expect(app[willFinish.lowerBound..<didFinish.lowerBound].contains("reminders.listen()"),
                "the delegate is not set before launch finishes, so a click that launches the app is lost")
        #expect(app[didFinish.lowerBound...].prefix(4_000).contains("reminders.start()"),
                "nothing starts the re-plan triggers")
        #expect(app.contains("graded: { [weak self] in self?.reminders.answered() }"),
                "the Review window's grades do not reach the reminders")
        #expect(app.contains("triggers: .live(studyDictionary: { [weak self] in self?.dictionary.chosen })"),
                "choosing another study dictionary does not reach the reminders")
    }

    private func source(_ path: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repository.appending(path: path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
