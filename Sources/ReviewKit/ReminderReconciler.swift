import Foundation

/// **One thing to ask of the system's notification center.** Only identifiers under
/// `ReminderKey.prefix` ever appear in one.
public enum ReminderAction: Sendable, Hashable {
    /// Add the request — or, under an identifier still pending, replace it.
    case add(PlannedReminder)
    /// Take a pending request out before it fires.
    case removePending(id: String)
    /// Take a delivered banner out of Notification Center — Later's original, and nothing else.
    case removeDelivered(id: String)
}

/// **A new log, and the system actions it allows — released only once the log is written.**
///
/// The two phases are the type: `log` is readable, the actions are not, except through
/// `actions(afterPersisting:)`, which writes the log first and hands back nothing if the write throws.
/// So **a log write that fails schedules nothing** (§5.2), and no reminder exists that the log does not
/// know about. An update that leaves the log as it found it — a replacement, whose identifier the log
/// already records, or the removal of a request the log never knew — needs no write to be released.
public struct ReminderUpdate: Sendable, Equatable {
    /// The log as this update leaves it, to be written before anything it allows.
    public let log: ReminderLog
    let original: ReminderLog
    let withheld: [ReminderAction]

    init(original: ReminderLog, log: ReminderLog, actions: [ReminderAction]) {
        self.original = original
        self.log = log
        self.withheld = actions
    }

    /// **Writes `log` through `persist` — when it changed — and then, only then, returns the actions.**
    /// Removals come before adds, each group in a fixed order, so one update always performs alike.
    public func actions(afterPersisting persist: (ReminderLog) throws -> Void) rethrows -> [ReminderAction] {
        if log != original { try persist(log) }
        return withheld
    }
}

/// **Brings the system's pending requests in line with the plan, through the log** (review-module-plan
/// §5.2, WI-6).
///
/// It knows the system as two sets of identifiers — pending and delivered — and never as anything
/// else; WI-7 reads them from the notification center and performs what this releases. **Only
/// identifiers under `review.` are touched or recorded.** At every trigger:
///
/// 1. **Observe.** What the log believed, checked against the lists: an identifier delivered is
///    `gone`; `added` and no longer pending is `gone`, and never added again — it fired, or was
///    removed, and only the first may be followed by another alert; `intent` and pending was added
///    (its mark was lost), and not pending is re-added only while its fire time is ahead; `failed` and
///    pending was added after all.
/// 2. **Decide**, per study day and kind, against the plan: add what is planned and not there (an
///    `intent` written first), replace a pending request whose count or time changed (no write needed:
///    the identifier is already recorded), retry a failure once, remove what is pending and not
///    planned, and record a day with nothing askable as such. **A pending request the log does not know
///    is removed, never adopted**: it can exist only if the intent's write was lost.
/// 3. **Off**, every open day is withdrawn as `.disabled` and every pending request removed — in one
///    update, so neither happens without the other. A request whose fire time has passed is `gone`
///    instead: it may have fired.
/// 4. **Prune** to fourteen study days.
///
/// A pending request removed with its fire time still ahead cannot have fired, so its day stays open:
/// `nothingAskable` or absent. One removed with its fire time passed is `gone`: no catch-up.
public enum ReminderReconciler {
    public static func reconcile(_ plan: ReminderPlan, log: ReminderLog,
                                 pending: Set<String>, delivered: Set<String>) -> ReminderUpdate {
        let now = plan.now
        let pending = pending.filter { $0.hasPrefix(ReminderKey.prefix) }
        let delivered = delivered.filter { $0.hasPrefix(ReminderKey.prefix) }
        let planned = Dictionary(plan.reminders.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        // Under the prefix and not a key: nothing can plan it, so it is removed and never recorded.
        var removals = pending.filter { ReminderKey(identifier: $0) == nil }
        var adds: [PlannedReminder] = []
        var entries = log.entries
        let keys = Set(log.entries.keys).union(planned.keys).union(plan.nothingAskable)
            .union(pending.compactMap(ReminderKey.init(identifier:)))
            .union(delivered.compactMap(ReminderKey.init(identifier:)))
        for key in keys.sorted() {
            let isPending = pending.contains(key.identifier)
            let seen = observed(log[key], isPending: isPending, isDelivered: delivered.contains(key.identifier),
                                now: now, enabled: plan.isEnabled)
            let decision = plan.isEnabled
                ? decided(seen, planned: planned[key], isPending: isPending,
                          nothingAskable: plan.nothingAskable.contains(key), now: now)
                : withdrawn(seen, isPending: isPending, now: now)
            entries[key] = decision.state
            if decision.removes { removals.insert(key.identifier) }
            if let add = decision.adds { adds.append(add) }
        }
        let written = ReminderLog(entries: entries, laterAsked: log.laterAsked).pruned(today: plan.today)
        let actions = removals.sorted().map { ReminderAction.removePending(id: $0) }
            + adds.sorted { $0.fireAt != $1.fireAt ? $0.fireAt < $1.fireAt : $0.key < $1.key }.map { .add($0) }
        return ReminderUpdate(original: log, log: written, actions: actions)
    }

    private struct Decision {
        var state: ReminderLog.State?
        var removes = false
        var adds: PlannedReminder?
    }

    /// **What the log's state means, given what the system lists.** Pending and delivered are facts;
    /// the log is a belief, and the facts win — in the direction that can only cost a reminder.
    static func observed(_ state: ReminderLog.State?, isPending: Bool, isDelivered: Bool, now: Date,
                         enabled: Bool) -> ReminderLog.State? {
        if let state, state.isTerminal { return state }
        if isDelivered { return .gone }
        switch state {
        case .added(let request)?:
            return isPending ? .added(request) : .gone
        case .intent(let request)?:
            if isPending { return .added(request) }
            return request.fireAt > now ? .intent(request) : .gone
        case .failed(let request, let at)?:
            return isPending ? .added(request) : .failed(request, at: at)
        case .withdrawn(.disabled)?:
            // Reminders are on again: the day is open, as if it had never been planned. Nothing of it
            // is in the system — it was withdrawn in the update that removed its request.
            return enabled ? nil : state
        case .notPlanned?, nil, .gone?, .withdrawn?:
            return state
        }
    }

    /// Reminders on: the day against the plan.
    private static func decided(_ state: ReminderLog.State?, planned: PlannedReminder?, isPending: Bool,
                                nothingAskable: Bool, now: Date) -> Decision {
        let empty: ReminderLog.State? = nothingAskable ? .notPlanned(.nothingAskable) : nil
        switch state {
        case let state? where state.isTerminal:
            return Decision(state: state, removes: isPending)
        case .added(let request)?:
            if let planned {
                return Decision(state: state, adds: planned.request == request ? nil : planned)
            }
            // Pending and not wanted. Ahead of its fire time it cannot have fired, so the day stays
            // open; past it, it may be firing now, and nothing catches up.
            return Decision(state: request.fireAt > now ? empty : .gone, removes: true)
        case .intent?:
            // Not pending, fire time ahead: the add never happened.
            guard let planned else { return Decision(state: empty) }
            return Decision(state: .intent(planned.request), adds: planned)
        case .failed?:
            guard let planned else { return Decision(state: empty ?? state) }
            return Decision(state: .intent(planned.request), adds: planned)
        case .notPlanned?, nil, .gone?, .withdrawn?:
            // Pending with nothing logged: the intent's write was lost. Removed, not trusted; the next
            // trigger adds the day through the protocol.
            if isPending { return Decision(state: state, removes: true) }
            guard let planned else { return Decision(state: empty ?? state) }
            return Decision(state: .intent(planned.request), adds: planned)
        }
    }

    /// Reminders off: every open day withdrawn, every pending request removed — together.
    private static func withdrawn(_ state: ReminderLog.State?, isPending: Bool, now: Date) -> Decision {
        if let state, state.isTerminal { return Decision(state: state, removes: isPending) }
        // A day never planned has nothing to withdraw: no entry is invented for it.
        guard let state else { return Decision(state: nil, removes: isPending) }
        if let request = state.request, request.fireAt <= now {
            return Decision(state: .gone, removes: isPending)
        }
        return Decision(state: .withdrawn(.disabled), removes: isPending)
    }
}
