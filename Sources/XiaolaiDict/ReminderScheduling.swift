import Foundation
import ReviewKit
import XiaolaiDictUI

/// **The notification center, as the reminder needs it** — and nothing that names it.
///
/// `UNUserNotificationCenter.current()` aborts a process with no app bundle (SIGABRT,
/// "bundleProxyForCurrentProcess is nil"), and `swift test` is one. So the system is reached through
/// this, `ReminderDelivery` is the one implementation that names the center, and every test drives a
/// fake. The center is known here as identifiers and instants, never as a request's words.
@MainActor
protocol ReminderScheduling: AnyObject {
    /// What macOS says about this app's notifications. **Never prompts.**
    func authorization() async -> NotificationGrant
    /// **Raises the system prompt** where the reader has never answered. Called from
    /// `NotificationAccess.ensure()` alone, which only the Settings switch reaches.
    func requestAuthorization() async throws -> Bool
    /// The actions a delivered reminder offers — Review, Later, Skip Today. Before any add.
    func registerActions()
    /// Adds the request, or replaces a pending one under the same identifier.
    func add(_ reminder: PlannedReminder) async throws
    /// This app's pending requests, and when each will fire.
    func pending() async -> [PendingReminder]
    /// Identifiers still in Notification Center.
    func deliveredIdentifiers() async -> Set<String>
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
    /// Where a reader's answer to a delivered reminder goes. **Set before launch finishes**, so a
    /// click that launched the app is not lost. **Awaited**: the system's delegate call is done when
    /// `respond` is, so the answer is written before the system may let a launched app go (audit-fix
    /// round 1 — a queued `Task` let the call finish first).
    func listen(_ respond: @escaping @MainActor (ReminderResponse) async -> Void)
}

/// A pending request, as the system lists it: its identifier and its next fire date.
struct PendingReminder: Sendable, Equatable {
    let identifier: String
    /// Nil for a trigger that will not fire again.
    let fireAt: Date?
}

/// **What a reader did with a delivered reminder.** Read from the action they chose and the request it
/// was on; anything else — a dismissal, a request this app did not make — is no answer.
enum ReminderResponse: Sendable, Equatable {
    /// The banner, or its Review button: the Library on Review.
    case open
    /// Once more, later this study day.
    case later(ReminderDay)
    /// Nothing more this study day.
    case skip(ReminderDay)
}

/// **The center an app is given where none was named: it holds nothing and delivers nothing.**
///
/// The default of `XiaolaiDictApp.init(…reminders:)`, for the reason `shell: .inert` is that
/// initialiser's: a test that forgets it must not reach the real center, which would abort it. The
/// one production caller, `init()`, names `ReminderDelivery()` outright, and
/// `ReminderWiringTests.theRunningAppSetsTheDelegateBeforeLaunchFinishes` reads that line.
@MainActor
final class NoNotificationCenter: ReminderScheduling {
    struct NotDelivered: Error {}

    func authorization() async -> NotificationGrant { .couldNotTell }
    func requestAuthorization() async throws -> Bool { throw NotDelivered() }
    func registerActions() {}
    func add(_ reminder: PlannedReminder) async throws { throw NotDelivered() }
    func pending() async -> [PendingReminder] { [] }
    func deliveredIdentifiers() async -> Set<String> { [] }
    func removePending(_ identifiers: [String]) {}
    func removeDelivered(_ identifiers: [String]) {}
    func listen(_ respond: @escaping @MainActor (ReminderResponse) async -> Void) {}
}
