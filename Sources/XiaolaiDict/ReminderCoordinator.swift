import AppKit
import Foundation
import Observation
import ReviewKit
import StudyModels
import XiaolaiDictBase
import XiaolaiDictUI
import os

/// Why a re-plan ran. Logged, and what a test waits on.
enum ReplanReason: String, Sendable {
    case launch, ledger, settings, wake, timeZone, clock, studyDay
    /// The study dictionary the plan counts was changed; the grant was found changed.
    case studyDictionary, grant
    /// A scheduled answer was written; Later; Skip Today.
    case sat, later, skip
}

/// **What a re-plan came to.** Every failure names itself, and none of them changes the system: a
/// re-plan that could not be sure of something leaves what is pending as it was.
enum ReplanOutcome: Sendable, Equatable {
    /// Reminders were never turned on and the log is empty: the notification center was not touched.
    case dormant
    /// The grant could not be read, so nothing was added or withdrawn on a guess.
    case grantUnknown
    /// The ledger could not be read, so no count could be predicted.
    case ledgerUnreadable
    /// **The log could not be written, so nothing was scheduled** (§5.2): no reminder exists the log
    /// does not know about.
    case logNotWritten
    /// The plan reached the system: requests added, adds that failed, requests removed.
    case applied(added: Int, failed: Int, removed: Int)
    /// Later was asked for and refused — off, already asked, or past the study day.
    case laterRefused(LaterRefusal)
}

/// **Where a re-plan is told to happen**, other than the app's own calls: the system's zone and clock
/// changes, waking, and the ledger. Injected, so a test posts to centers of its own.
@MainActor
struct ReminderTriggers {
    /// `NSSystemTimeZoneDidChange` and `NSSystemClockDidChange`.
    let system: NotificationCenter
    /// `NSWorkspace.didWakeNotification`.
    let workspace: NotificationCenter
    let ledger: LedgerChanges
    /// **The study dictionary the plan counts**, read through something `@Observable` so that choosing
    /// another one is seen: it writes no ledger row, and the reminders went on counting the old
    /// dictionary's cards until some other trigger ran (audit-fix round 1).
    let studyDictionary: @MainActor () -> String?

    static func live(studyDictionary: @escaping @MainActor () -> String?) -> ReminderTriggers {
        ReminderTriggers(system: .default, workspace: NSWorkspace.shared.notificationCenter, ledger: .shared,
                         studyDictionary: studyDictionary)
    }
}

/// **The review reminder, delivered** (review-module-plan §5, WI-7): the reader's settings, the log of
/// what was asked of the system, the re-plans that keep the two in line, and the reader's answers to a
/// delivered banner. A collaborator of its own, so `XiaolaiDictApp` composes it and holds none of its
/// state (ADR-0011).
///
/// **One pass, every time** — at launch, a ledger change, a settings change, waking, a zone or clock
/// change and the next study day's start:
///
/// 1. **Off, with an empty log, it touches nothing.** R3 has not been decided, and reminders ship off:
///    a reader who never turns them on is not a client of the notification center at all.
/// 2. **On, the grant is probed — never requested.** Without it the plan is the off plan, which
///    withdraws and removes, because nothing can be delivered; a probe that could not tell changes
///    nothing.
/// 3. **One candidate fetch** — the sitting's own read, with today's one-day increase — through
///    `ReminderPlanner`, then `ReminderReconciler` against what the system lists.
/// 4. **The log is written, and only then is anything added or removed.** A write that fails releases
///    nothing (`actions(afterPersisting:)`), logged as an error.
///
/// **Everything that changes the log runs one at a time**, in the order asked: a Later answered while a
/// re-plan was between its read and its write would otherwise be written over.
///
/// **A failure here never reaches a lookup**: nothing on the lookup path waits for this, and a ledger
/// change only schedules a pass, after `ledgerSettle` of quiet.
@MainActor
@Observable
final class ReminderCoordinator {
    /// What the reader chose, as last read — what the Settings section draws.
    private(set) var settings: ReminderSettings
    /// The grant as last asked; nil until something asked.
    private(set) var access: NotificationGrant?

    /// How many passes have finished, and the latest — what the log line says and a test waits for.
    @ObservationIgnored private(set) var passCount = 0
    @ObservationIgnored private(set) var lastPass: (reason: ReplanReason, outcome: ReplanOutcome)?
    /// How many ends of a sitting have been weighed.
    @ObservationIgnored private(set) var answerCount = 0

    @ObservationIgnored private let scheduling: any ReminderScheduling
    @ObservationIgnored private let notifications: NotificationAccess
    @ObservationIgnored private let settingsStore: ReminderSettingsStore
    @ObservationIgnored private let logStore: ReminderLogStore
    @ObservationIgnored private let increases: OneDayIncreaseStore
    @ObservationIgnored private let store: @MainActor () -> Task<LedgerStore, any Error>?
    @ObservationIgnored private let primary: @MainActor () -> PrimaryDictionary
    @ObservationIgnored private let clock: @MainActor () -> Date
    /// **The planning zone**: the study day's, which every trigger is pinned to.
    @ObservationIgnored private let zone: @MainActor () -> TimeZone
    @ObservationIgnored private let openReview: @MainActor () async -> Bool
    @ObservationIgnored private let triggers: ReminderTriggers
    @ObservationIgnored private let ledgerSettle: Duration
    @ObservationIgnored private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "reminders")

    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var registered = false
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored private var nextDay: Task<Void, Never>?

    /// How long a ledger change waits for quiet before it re-plans: one lookup commits several times,
    /// and one pass afterwards is all of them.
    static let ledgerSettle: Duration = .seconds(2)

    /// `defaults` is the suite the app was given — the settings, the log and today's one-day increase
    /// are all kept there. `logStore` defaults to that suite; a test passes one whose write can fail.
    init(scheduling: any ReminderScheduling, defaults: UserDefaults, logStore: ReminderLogStore? = nil,
         store: @escaping @MainActor () -> Task<LedgerStore, any Error>?,
         primary: @escaping @MainActor () -> PrimaryDictionary,
         clock: @escaping @MainActor () -> Date = { .now },
         zone: @escaping @MainActor () -> TimeZone = { .current },
         openReview: @escaping @MainActor () async -> Bool = { false },
         triggers: ReminderTriggers, ledgerSettle: Duration = ReminderCoordinator.ledgerSettle) {
        self.scheduling = scheduling
        notifications = NotificationAccess(scheduling: scheduling)
        settingsStore = ReminderSettingsStore(defaults: defaults)
        self.logStore = logStore ?? .suite(defaults)
        increases = OneDayIncreaseStore(defaults: defaults)
        self.store = store
        self.primary = primary
        self.clock = clock
        self.zone = zone
        self.openReview = openReview
        self.triggers = triggers
        self.ledgerSettle = ledgerSettle
        settings = settingsStore.load()
    }

    /// Whether there is nothing to do at all: off, and nothing ever asked of the system.
    private var isDormant: Bool {
        !settingsStore.load().isEnabled && keptLog(enabled: false) == ReminderLog()
    }

    /// **The log a step works from — and, where the one kept was lost, what stands in for it** (WI-8).
    ///
    /// Unreadable is lost. Absent is lost while reminders are on, because `setEnabled` writes a log
    /// before it turns them on — so "on, and no log" can only be a log that went missing — and is
    /// nothing at all while they are off. A lost log is `ReminderLog.lost(today:)`: today's reminders
    /// spent, so a time moved later today cannot plan a second banner over one delivered and dismissed;
    /// the days ahead planned again. Written back by the next pass that changes anything.
    func keptLog(enabled: Bool) -> ReminderLog {
        switch logStore.read() {
        case .log(let kept):
            return kept
        case .absent where !enabled:
            return ReminderLog()
        case .absent, .unreadable:
            log.error("reminders: the log was lost; today's reminders are spent, and the days ahead planned again")
            return .lost(today: ReminderDay(studyDayContaining: clock(), in: StudyDay(timeZone: zone())))
        }
    }

    // MARK: - Launch

    /// **The delegate, set before launch finishes** — and only where a reminder could exist to be
    /// clicked: on, or something in the log. Turning reminders on sets it then.
    func listen() {
        guard !listening, !isDormant else { return }
        listening = true
        // **Awaited, not queued**: the system's delegate call ends when this does (audit-fix round 1).
        scheduling.listen { [weak self] response in
            await self?.respond(response)
        }
    }

    /// **The re-plan triggers, and the first pass.** Idempotent.
    func start() {
        guard !started else { return }
        started = true
        observe(triggers.system, .NSSystemTimeZoneDidChange) { [weak self] in
            // The cached zone is the old one until it is dropped.
            NSTimeZone.resetSystemTimeZone()
            self?.trigger(.timeZone)
        }
        observe(triggers.system, .NSSystemClockDidChange) { [weak self] in self?.trigger(.clock) }
        observe(triggers.workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.trigger(.wake) }
        observeLedger()
        observeStudyDictionary()
        trigger(.launch)
    }

    func stop() {
        started = false
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        settling?.cancel()
        nextDay?.cancel()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ act: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { act() }
        }
        observers.append((center, token))
    }

    private func trigger(_ reason: ReplanReason) {
        Task { await replan(reason) }
    }

    /// **A ledger change re-plans once the ledger is quiet**: a lookup's commits are one pass.
    private func observeLedger() {
        guard started else { return }
        withObservationTracking { _ = triggers.ledger.revision } onChange: { [weak self] in
            Task { @MainActor in self?.ledgerChanged() }
        }
    }

    private func ledgerChanged() {
        guard started else { return }
        observeLedger()
        settling?.cancel()
        let quiet = ledgerSettle
        settling = Task { [weak self] in
            if quiet > .zero {
                try? await Task.sleep(for: quiet)
                guard !Task.isCancelled else { return }
            }
            await self?.replan(.ledger)
        }
    }

    /// **Choosing another study dictionary re-plans at once**: the plan counts its cards.
    private func observeStudyDictionary() {
        guard started else { return }
        withObservationTracking { _ = triggers.studyDictionary() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.observeStudyDictionary()
                self.trigger(.studyDictionary)
            }
        }
    }

    /// **The next study day's start re-plans**: the horizon gains a day and today's allowance turns
    /// over. Re-armed after every pass, so a zone or clock change moves it too.
    private func armNextDay() {
        guard started else { return }
        nextDay?.cancel()
        let now = clock()
        let wait = max(0, StudyDay(timeZone: zone()).startOfNextDay(containing: now).timeIntervalSince(now))
        nextDay = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await self?.replan(.studyDay)
        }
    }

    // MARK: - One pass

    /// **Re-plans, after whatever was asked before.** Never throws: what went wrong is the outcome.
    @discardableResult
    func replan(_ reason: ReplanReason) async -> ReplanOutcome {
        await serial { await self.pass(reason) }
    }

    /// Runs `work` once everything queued before it has finished.
    private func serial(_ work: @escaping @MainActor () async -> ReplanOutcome) async -> ReplanOutcome {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func pass(_ reason: ReplanReason) async -> ReplanOutcome {
        let outcome = await reconcile()
        passCount += 1
        lastPass = (reason, outcome)
        report(reason, outcome)
        armNextDay()
        return outcome
    }

    private func reconcile() async -> ReplanOutcome {
        let chosen = settingsStore.load()
        if chosen != settings { settings = chosen }
        let kept = keptLog(enabled: chosen.isEnabled)
        guard chosen.isEnabled || kept != ReminderLog() else { return .dormant }
        var effective = chosen
        if chosen.isEnabled {
            let grant = await notifications.granted()
            if access != grant { access = grant }
            switch grant {
            case .granted: break
            // Nothing can be delivered: planned as off, which withdraws and removes.
            case .notAsked, .declined: effective = chosen.turned(on: false)
            case .couldNotTell: return .grantUnknown
            }
        }
        let plan: ReminderPlan
        do {
            plan = try await self.plan(for: effective, log: kept)
        } catch {
            log.error("reminders: the ledger could not be read: \(String(describing: type(of: error)), privacy: .public)")
            return .ledgerUnreadable
        }
        if plan.isEnabled, !registered {
            scheduling.registerActions()
            registered = true
        }
        let pending = Set(await scheduling.pending().map(\.identifier))
        let delivered = await scheduling.deliveredIdentifiers()
        let update = ReminderReconciler.reconcile(plan, log: kept, pending: pending, delivered: delivered)
        let actions: [ReminderAction]
        do {
            actions = try update.actions(afterPersisting: logStore.save)
        } catch {
            return .logNotWritten
        }
        return await perform(actions, on: update.log)
    }

    /// **The plan these settings make from the ledger now** — one candidate fetch, the sitting's own
    /// read, with today's one-day increase. Off reads nothing. `--reminder-report` prints it too.
    func plan(for settings: ReminderSettings, log kept: ReminderLog) async throws -> ReminderPlan {
        let now = clock()
        let studyDay = StudyDay(timeZone: zone())
        let planner = planner(studyDay, now)
        let candidates: SittingCandidates
        if settings.isEnabled {
            guard let opening = store() else { throw LedgerUnavailable() }
            candidates = try await opening.value.sittingCandidates(dictionary: primary().chosen,
                                                                   introducedSince: planner.today)
        } else {
            candidates = SittingCandidates(cards: [], introducedToday: 0)
        }
        // A week of counts over every candidate is pure work, and the main actor draws the app.
        return await Task.detached(priority: .utility) {
            ReminderPlanner.plan(settings: settings, sitting: planner, candidates: candidates, log: kept)
        }.value
    }

    struct LedgerUnavailable: Error {}

    /// **The Review window's planner**: its batch, its allowance and today's one-day increase, so a
    /// reminder counts what the sitting it announces would hold.
    private func planner(_ studyDay: StudyDay, _ now: Date) -> SittingPlanner {
        SittingPlanner(studyDay: studyDay, now: now, batchSize: ReviewModel.batchSize,
                       newCardsPerDay: ReviewModel.newCardsPerDay,
                       increaseToday: increases.extra(in: studyDay, at: now))
    }

    /// Performs what a written log released, recording each add against its intent.
    private func perform(_ actions: [ReminderAction], on written: ReminderLog) async -> ReplanOutcome {
        var kept = written
        var added = 0, failed = 0, removed = 0
        for action in actions {
            switch action {
            case .removePending(let id):
                scheduling.removePending([id])
                removed += 1
            case .removeDelivered(let id):
                scheduling.removeDelivered([id])
                removed += 1
            case .add(let reminder):
                do {
                    try await scheduling.add(reminder)
                    kept = kept.recordingAdd(.added, of: reminder)
                    added += 1
                } catch {
                    let failure = error as NSError
                    log.error("reminders: adding \(reminder.id, privacy: .public) failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
                    kept = kept.recordingAdd(.failed(at: clock()), of: reminder)
                    failed += 1
                }
            }
        }
        if added + failed > 0 {
            do {
                try logStore.save(kept)
            } catch {
                // The requests stand. Their marks read back as intents, which the next pass finds
                // pending and records as added.
                log.error("reminders: what the adds came to could not be written; the next pass reads them back")
            }
        }
        return .applied(added: added, failed: failed, removed: removed)
    }

    /// An outcome that ended a step before any pass, logged as a pass's would be.
    private func said(_ reason: ReplanReason, _ outcome: ReplanOutcome) -> ReplanOutcome {
        report(reason, outcome)
        return outcome
    }

    private func report(_ reason: ReplanReason, _ outcome: ReplanOutcome) {
        switch outcome {
        case .dormant:
            return
        case .applied(let added, let failed, let removed):
            guard added + failed + removed > 0 else { return }
            log.notice("reminders: \(reason.rawValue, privacy: .public): \(added) added, \(failed) failed, \(removed) removed")
        case .grantUnknown:
            log.error("reminders: \(reason.rawValue, privacy: .public): whether notifications are allowed could not be read; nothing changed")
        case .ledgerUnreadable:
            log.error("reminders: \(reason.rawValue, privacy: .public): no count could be predicted; nothing changed")
        case .logNotWritten:
            log.error("reminders: \(reason.rawValue, privacy: .public): the log could not be written, so nothing was scheduled")
        case .laterRefused(let why):
            log.notice("reminders: Later refused: \(String(describing: why), privacy: .public)")
        }
    }

    // MARK: - What the reader does

    /// **The Settings switch — the only thing in the app that asks for the permission.** Turning on
    /// asks where the reader has never answered and stays off unless granted; turning off withdraws
    /// every open day and removes its request together, the log first.
    func setEnabled(_ wanted: Bool) async {
        if wanted {
            let grant = await notifications.ensure()
            access = grant
            guard grant == .granted else {
                log.notice("reminders: not turned on — the grant is \(ReminderReport.name(of: grant), privacy: .public)")
                return
            }
            // **A first use writes a log before reminders go on**, so that on and no log can only be a
            // log that was lost (`keptLog`). This is the one time today may be planned from nothing. A
            // write that fails leaves on and no log, which is read as lost: today spent, and safe.
            if !settingsStore.load().isEnabled, logStore.read() == .absent {
                do {
                    try logStore.save(ReminderLog())
                } catch {
                    log.error("reminders: the first log could not be written; today is planned as spent")
                }
            }
        }
        save(settingsStore.load().turned(on: wanted))
        if wanted { listen() }
        await replan(.settings)
    }

    func setTime(hour: Int, minute: Int) {
        save(settingsStore.load().at(hour: hour, minute: minute))
        trigger(.settings)
    }

    func setShowsCount(_ shows: Bool) {
        save(settingsStore.load().showing(count: shows))
        trigger(.settings)
    }

    /// **How long Later waits** — one of the delays Settings offers (`offeredLaterDelays`: the choices,
    /// and the one kept). Anything else is our own caller's mistake: refused and logged, never fatal,
    /// and the reader's choice left as it was. Re-plans like every settings change, though nothing
    /// planned depends on it until the next Later is asked: `ReminderLog.askingLater` reads it then.
    func setLaterDelay(_ delay: TimeInterval) {
        let chosen = settingsStore.load()
        guard chosen.offeredLaterDelays.contains(delay) else {
            log.error("reminders: a Later delay of \(delay, privacy: .public) s is not one Settings offers; kept \(chosen.laterDelay, privacy: .public) s")
            return
        }
        save(chosen.waiting(later: delay))
        trigger(.settings)
    }

    private func save(_ chosen: ReminderSettings) {
        settingsStore.save(chosen)
        settings = chosen
    }

    /// Asks the grant again, never prompting — the Settings section, as it appears and when the reader
    /// comes back from System Settings.
    ///
    /// **A grant that changed re-plans**, with reminders on: declined, the plan was the off plan and
    /// removed what was pending; allowed again, nothing put it back until some other trigger ran
    /// (audit-fix round 1). An unchanged answer re-plans nothing.
    func refreshAccess() async {
        let grant = await notifications.granted()
        let changed = access != grant
        access = grant
        guard changed, settingsStore.load().isEnabled else { return }
        await replan(.grant)
    }

    /// **A scheduled answer was written**: the Review window's hook. Weighed after it, in order.
    func answered() {
        Task { await sittingAnswered() }
    }

    /// **A scheduled answer re-plans at once** (§5.4), rather than after the ledger's quiet — and the
    /// plan's own count at each fire instant decides. Grading the last card that would be askable at
    /// today's fire time withdraws today's reminder: the planner finds nothing there, and the
    /// reconciler removes the request and records the day `notPlanned(.nothingAskable)`.
    ///
    /// **Never from "nothing is askable now".** That was the rule, written as the terminal
    /// `withdrawn(.satToday)`, and it is a different question (WI-8): Forgot on a new card at 10:00
    /// leaves nothing askable that instant and the card back at 10:10, so the 19:00 reminder the plan
    /// still wanted was closed for the rest of the day. Not terminal, either: work that becomes askable
    /// later today — a meaning saved this afternoon — is planned by the next pass like any other.
    func sittingAnswered() async {
        _ = await serial { [self] in
            defer { answerCount += 1 }
            guard settingsStore.load().isEnabled else { return .dormant }
            return await pass(.sat)
        }
    }

    /// **A reader's answer to a delivered reminder.**
    func respond(_ response: ReminderResponse) async {
        switch response {
        case .open:
            _ = await openReview()
        case .later(let day):
            _ = await serial { [self] in
                let chosen = settingsStore.load()
                let asked = keptLog(enabled: chosen.isEnabled).askingLater(on: day, at: clock(), settings: chosen,
                                                                           studyDay: StudyDay(timeZone: zone()))
                switch asked {
                case .refused(let why):
                    return said(.later, .laterRefused(why))
                case .asked(let update):
                    // The original leaves Notification Center once the log says Later was asked.
                    let actions: [ReminderAction]
                    do {
                        actions = try update.actions(afterPersisting: logStore.save)
                    } catch {
                        return said(.later, .logNotWritten)
                    }
                    _ = await perform(actions, on: update.log)
                    return await pass(.later)
                }
            }
        case .skip(let day):
            _ = await serial { [self] in
                do {
                    try logStore.save(keptLog(enabled: settingsStore.load().isEnabled).withdrawing(day, .skipped))
                } catch {
                    return said(.skip, .logNotWritten)
                }
                return await pass(.skip)
            }
        }
    }

    // MARK: - What Settings draws

    var choice: ReminderChoice {
        ReminderChoice(
            settings: settings, access: access,
            setEnabled: { [weak self] wanted in await self?.setEnabled(wanted) },
            setTime: { [weak self] hour, minute in self?.setTime(hour: hour, minute: minute) },
            setShowsCount: { [weak self] shows in self?.setShowsCount(shows) },
            setLaterDelay: { [weak self] delay in self?.setLaterDelay(delay) },
            refresh: { [weak self] in await self?.refreshAccess() },
            openNotificationSettings: { Self.openNotificationSettings() })
    }

    /// **System Settings › Notifications, at this app** — where a declined grant is given back.
    static func openNotificationSettings() {
        let address = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(XiaolaiDictIdentity.app)"
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}
