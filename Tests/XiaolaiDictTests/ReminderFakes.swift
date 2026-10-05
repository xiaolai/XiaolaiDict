import Foundation
import ReviewKit
import XiaolaiDictUI
@testable import XiaolaiDict

/// **The only notification center a unit test may touch.**
///
/// `UNUserNotificationCenter.current()` aborts a process with no app bundle — SIGABRT,
/// "bundleProxyForCurrentProcess is nil" — and `swift test` is such a process. So every test drives
/// the coordinator through this, which keeps in memory what the system would keep: what is pending,
/// what is delivered, what the reader answered when asked, and what was asked of it.
@MainActor
final class FakeReminderCenter: ReminderScheduling {
    /// What `authorization()` answers. The prompt changes it, as the system's does.
    var grant: NotificationGrant
    /// What the reader would answer the system prompt, were it raised.
    var answer = true
    /// Whether every add fails, as the system's does without a grant.
    var addFails = false
    /// A shared record, so a test can see what happened in what order across this and the log store.
    let events: EventLog

    private(set) var probes = 0
    /// How many times the system prompt was raised.
    private(set) var requests = 0
    private(set) var registrations = 0
    /// How many times the pending or delivered list was read — what a dormant coordinator must never do.
    private(set) var reads = 0
    private(set) var pendingByID: [String: PlannedReminder] = [:]
    var delivered: Set<String> = []
    /// Every add, in order, replacements included.
    private(set) var added: [PlannedReminder] = []
    private(set) var removedPending: [String] = []
    private(set) var removedDelivered: [String] = []
    private(set) var listener: (@MainActor (ReminderResponse) async -> Void)?

    init(grant: NotificationGrant = .granted, events: EventLog = EventLog()) {
        self.grant = grant
        self.events = events
    }

    struct Refused: Error {}

    func authorization() async -> NotificationGrant {
        probes += 1
        return grant
    }

    func requestAuthorization() async throws -> Bool {
        requests += 1
        events.append("request")
        grant = answer ? .granted : .declined
        return answer
    }

    func registerActions() { registrations += 1 }

    func add(_ reminder: PlannedReminder) async throws {
        if addFails { throw Refused() }
        events.append("add \(reminder.id)")
        added.append(reminder)
        pendingByID[reminder.id] = reminder
    }

    func pending() async -> [PendingReminder] {
        reads += 1
        return pendingByID.values.sorted { $0.id < $1.id }
            .map { PendingReminder(identifier: $0.id, fireAt: $0.fireAt) }
    }

    func deliveredIdentifiers() async -> Set<String> {
        reads += 1
        return delivered
    }

    func removePending(_ identifiers: [String]) {
        for id in identifiers {
            events.append("remove \(id)")
            removedPending.append(id)
            pendingByID[id] = nil
        }
    }

    func removeDelivered(_ identifiers: [String]) {
        for id in identifiers {
            events.append("remove delivered \(id)")
            removedDelivered.append(id)
            delivered.remove(id)
        }
    }

    func listen(_ respond: @escaping @MainActor (ReminderResponse) async -> Void) { listener = respond }

    /// The system delivering a pending request at its time: out of the pending list, into
    /// Notification Center.
    func deliver(_ id: String) {
        pendingByID[id] = nil
        delivered.insert(id)
    }
}

/// What happened, in order, across the fake center and a recording log store.
@MainActor
final class EventLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}

/// A value a `@MainActor` closure can change and a test can read — Swift 6 will not let a closure
/// that may run elsewhere capture a mutable local.
@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

extension ReminderLogStore {
    /// A log kept in memory, writing through `save` — which a test can make fail — and recording
    /// each write in `events`.
    @MainActor
    static func memory(_ kept: Box<ReminderLog>, events: EventLog? = nil,
                       failing: Bool = false) -> ReminderLogStore {
        ReminderLogStore(read: { .log(kept.value) }, save: { log in
            struct Unwritable: Error {}
            if failing { throw Unwritable() }
            kept.value = log
            events?.append("save")
        })
    }
}
