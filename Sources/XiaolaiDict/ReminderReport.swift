import Foundation
import ReviewKit
import StudyModels
import XiaolaiDictUI

/// `--reminder-report`: **the grant, what is pending and when it fires, what the reader's settings
/// plan, and the log — never what a banner says** (review-module-plan §5.4, WI-7).
///
/// The `reminder` end-to-end stage cannot read the notification center from outside the bundle: the
/// center answers per app, and only this bundle's process is this app. So the stage launches this, in
/// the reader's GUI session, and judges what it prints.
///
/// **Content is never printed** — no title, no sentence, no word. A request is its identifier and its
/// next fire date; a planned reminder is that and the count it predicts. **It writes nothing**: it reads
/// the lists, the settings and the log, and plans from the ledger without adding, removing or asking —
/// opening the ledger only when there is something to plan, and only one that exists at this build's
/// schema (`LedgerStore.openForReading`).
///
/// **Compiled out of a release**, as `--read-point` and `--read-selection` are: a reader has no use for
/// it, and `verify_bundle` checks both directions — a release refuses it, a development bundle runs it.
@MainActor
enum ReminderReport {
    static func run() async -> CommandStatus {
#if !XIAOLAIDICT_CAPTURE_INSTRUMENTS
        LookupCommand.writeError("--reminder-report is a development instrument and is not built into a release")
        return .usage
#else
        // The witness `verify_bundle` looks for in a development bundle: a sentence only this branch has.
        LookupCommand.writeError("reminder-report: reading this app's requests from the notification center")
        // **Opened on demand, and only as it is**: never created, never migrated.
        let store = ledgerOnDemand { try await LedgerStore.openForReading() }
        // **The app's own suite**, as `XiaolaiDictApp.init()` takes it: inside the bundle `.standard` is
        // the reader's domain, where the settings and the log are kept.
        return await run(scheduling: ReminderDelivery(), store: store,
                         primary: { PrimaryDictionaryStore().load() }, defaults: .standard,
                         clock: { .now }, zone: { .current }, write: LookupCommand.writeLine)
#endif
    }

    static func run(scheduling: any ReminderScheduling,
                    store: @escaping @MainActor () -> Task<LedgerStore, any Error>?,
                    primary: @escaping @MainActor () -> PrimaryDictionary,
                    defaults: UserDefaults,
                    clock: @escaping @MainActor () -> Date,
                    zone: @escaping @MainActor () -> TimeZone,
                    write: (String) -> Bool) async -> CommandStatus {
        let settings = ReminderSettingsStore(defaults: defaults).load()
        // **What is kept, printed as kept**, and what the key held said apart: a log, none, or one that
        // does not read — which the coordinator plans as lost, and the plan below does too.
        let stored = ReminderLogStore.suite(defaults).read()
        let log = stored.log ?? ReminderLog()
        let logRead: String = switch stored {
        case .log: "log"
        case .absent: "absent"
        case .unreadable: "unreadable"
        }
        var report: [String: Any] = [
            "logRead": logRead,
            "insideBundle": Bundle.main.bundleIdentifier != nil,
            "enabled": settings.isEnabled,
            "hour": settings.hour,
            "minute": settings.minute,
            "showsCount": settings.showsPredictedCount,
            "horizon": settings.horizon,
            "zone": zone().identifier,
            "grant": name(of: await NotificationAccess(scheduling: scheduling).granted()),
        ]
        report["pending"] = await scheduling.pending().sorted { $0.identifier < $1.identifier }.map { pending in
            var found: [String: Any] = ["id": pending.identifier]
            if let fireAt = pending.fireAt { found["fireAt"] = fireAt.timeIntervalSince1970 }
            return found
        }
        report["delivered"] = await scheduling.deliveredIdentifiers().sorted()
        report["log"] = log.entries.sorted { $0.key < $1.key }.map { key, state in describe(key, state) }
        report["later"] = log.laterAsked.sorted { $0.key < $1.key }.map { day, fireAt in
            ["day": day.description, "fireAt": fireAt.timeIntervalSince1970] as [String: Any]
        }

        // **What these settings plan from this ledger**, through the coordinator's own planning — the
        // grant aside, so a Mac that has never been asked still shows what the reminder would be.
        // **Never started**, so its triggers observe nothing: the instrument plans once and exits.
        let reminders = ReminderCoordinator(scheduling: scheduling, defaults: defaults, store: store,
                                            primary: primary, clock: clock, zone: zone,
                                            triggers: .live(studyDictionary: { primary().chosen }))
        do {
            let plan = try await reminders.plan(for: settings, log: reminders.keptLog(enabled: settings.isEnabled))
            report["planned"] = plan.reminders.map { reminder in
                var found: [String: Any] = [
                    "id": reminder.id, "fireAt": reminder.fireAt.timeIntervalSince1970,
                    "kind": reminder.key.kind.rawValue, "zone": reminder.zone.identifier,
                ]
                if case .sittingReady(let count?) = reminder.content { found["count"] = count }
                return found
            }
            report["nothingAskable"] = plan.nothingAskable.sorted().map(\.identifier)
        } catch {
            report["problem"] = "the ledger could not be read: \(error.localizedDescription)"
            return Instrument.write(report, to: write) ? .failure : .internalError
        }
        return Instrument.write(report, to: write) ? .success : .internalError
    }

    /// **The ledger, opened when the plan first asks for it, and not before** (audit-fix round 1): the
    /// opening began before a setting was read, so with reminders off — nothing to plan — the ledger was
    /// opened anyway. Asked again, the same opening answers.
    static func ledgerOnDemand(_ open: @escaping @MainActor () async throws -> LedgerStore)
        -> @MainActor () -> Task<LedgerStore, any Error>? {
        let held = OnDemand()
        return {
            if let task = held.task { return task }
            let task = Task { try await open() }
            held.task = task
            return task
        }
    }

    @MainActor private final class OnDemand {
        var task: Task<LedgerStore, any Error>?
    }

    /// The grant, spelled for the harness — never localized.
    static func name(of grant: NotificationGrant) -> String {
        switch grant {
        case .granted: "granted"
        case .notAsked: "notAsked"
        case .declined: "declined"
        case .couldNotTell: "couldNotTell"
        }
    }

    /// One log entry: its identifier, its state, and the instant and count it holds — no words.
    static func describe(_ key: ReminderKey, _ state: ReminderLog.State) -> [String: Any] {
        var found: [String: Any] = ["id": key.identifier]
        func request(_ request: ReminderRequest) {
            found["fireAt"] = request.fireAt.timeIntervalSince1970
            if case .sittingReady(let count?) = request.content { found["count"] = count }
        }
        switch state {
        case .notPlanned(let why):
            found["state"] = "notPlanned"
            found["reason"] = why.rawValue
        case .intent(let held):
            found["state"] = "intent"
            request(held)
        case .added(let held):
            found["state"] = "added"
            request(held)
        case .failed(let held, let at):
            found["state"] = "failed"
            request(held)
            found["failedAt"] = at.timeIntervalSince1970
        case .gone:
            found["state"] = "gone"
        case .withdrawn(let why):
            found["state"] = "withdrawn"
            found["reason"] = why.rawValue
        }
        return found
    }
}
