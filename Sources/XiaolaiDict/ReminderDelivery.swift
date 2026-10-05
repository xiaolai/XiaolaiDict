import Foundation
import ReviewKit
import UserNotifications
import XiaolaiDictBase
import XiaolaiDictUI
import os

/// **The one file that names the notification center** (review-module-plan §5.3, WI-7).
///
/// `UNUserNotificationCenter.current()` aborts a process that has no app bundle — so a unit test, or
/// an XPC service, must never reach it. Everything else reaches the system through
/// `ReminderScheduling`, and `ReminderDeliveryTests` fails if a second file names the center or
/// imports the framework; `ModuleBoundaryTests` and `verify_service_boundaries` keep it out of both
/// services. The center is asked for lazily, so building this object touches nothing.
///
/// It is also the center's delegate, **set before launch finishes** (`applicationWillFinishLaunching`)
/// so a click that launches the app reaches it.
@MainActor
final class ReminderDelivery: NSObject, ReminderScheduling, UNUserNotificationCenterDelegate {
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "reminders")
    private var respond: (@MainActor (ReminderResponse) async -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    /// The category every reminder is delivered under, which carries its actions.
    static let categoryIdentifier = "review.reminder"

    /// A delivered reminder's actions, in the order they are offered.
    enum Action: String, CaseIterable {
        case open = "reminder.open"
        case later = "reminder.later"
        case skip = "reminder.skip"
    }

    // MARK: - What is sent

    /// **The request for one planned reminder**: its identifier, a calendar trigger pinned to the
    /// planning zone, and the words — a title and a count. No badge, no sound, `.active`, never
    /// `.timeSensitive`: a reminder to study is not urgent (§5.3). Built without the center, so a test
    /// can read it.
    static func request(for reminder: PlannedReminder) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = ReminderWords.title
        content.body = ReminderWords.body(reminder.content)
        content.categoryIdentifier = categoryIdentifier
        content.interruptionLevel = .active
        // **Pinned**: `triggerComponents` carries the planning zone, so the request fires at the instant
        // its count was predicted for, whatever zone the Mac is in by then [measured, WI-6].
        let trigger = UNCalendarNotificationTrigger(dateMatching: reminder.triggerComponents, repeats: false)
        return UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
    }

    /// **Review, Later, Skip Today**, and a hidden preview that keeps the title and drops the count.
    /// Review comes forward — it opens a window the reader is about to use. Later and Skip Today are
    /// answered where the reader is.
    static func category() -> UNNotificationCategory {
        let actions = Action.allCases.map { action in
            switch action {
            case .open:
                UNNotificationAction(identifier: action.rawValue,
                                     title: String(localized: ActionSymbol.reviewPane.title), options: [.foreground])
            case .later:
                UNNotificationAction(identifier: action.rawValue,
                                     title: String(localized: ActionSymbol.remindLater.title), options: [])
            case .skip:
                UNNotificationAction(identifier: action.rawValue,
                                     title: String(localized: ActionSymbol.skipToday.title), options: [])
            }
        }
        return UNNotificationCategory(identifier: categoryIdentifier, actions: actions, intentIdentifiers: [],
                                      hiddenPreviewsBodyPlaceholder: ReminderWords.hiddenBody,
                                      options: [.hiddenPreviewsShowTitle])
    }

    /// **What a reader's answer means**: the banner itself or Review opens Review; Later and Skip Today
    /// are about the study day the request names. A dismissal, an unknown action and a request this
    /// app did not make are no answer.
    static func response(action: String, request: String) -> ReminderResponse? {
        guard let key = ReminderKey(identifier: request) else { return nil }
        if action == UNNotificationDefaultActionIdentifier { return .open }
        switch Action(rawValue: action) {
        case .open?: return .open
        case .later?: return .later(key.day)
        case .skip?: return .skip(key.day)
        case nil: return nil
        }
    }

    // MARK: - ReminderScheduling

    func authorization() async -> NotificationGrant {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        case .denied: return .declined
        case .provisional:
            // Never requested here: it delivers unasked, which R3 forbids. Seen, it is not the reader's
            // answer — so not a grant, and not a refusal either.
            log.error("reminders: a provisional authorization this app never asked for")
            return .couldNotTell
        @unknown default:
            log.error("reminders: an authorization status this build does not know")
            return .couldNotTell
        }
    }

    func requestAuthorization() async throws -> Bool {
        // An alert, and nothing else: no badge, no sound, and never `.provisional`.
        try await center.requestAuthorization(options: [.alert])
    }

    func registerActions() {
        center.setNotificationCategories([Self.category()])
    }

    func add(_ reminder: PlannedReminder) async throws {
        try await center.add(Self.request(for: reminder))
    }

    func pending() async -> [PendingReminder] {
        await center.pendingNotificationRequests().map { request in
            PendingReminder(identifier: request.identifier,
                            fireAt: (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate())
        }
    }

    func deliveredIdentifiers() async -> Set<String> {
        Set(await center.deliveredNotifications().map(\.request.identifier))
    }

    func removePending(_ identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(_ identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func listen(_ respond: @escaping @MainActor (ReminderResponse) async -> Void) {
        self.respond = respond
        center.delegate = self
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let request = response.notification.request.identifier
        await deliver(action: action, request: request)
    }

    /// **Shown while the app is in front too** — the Library open on another pane, say. A banner and
    /// the list, never a sound or a badge.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// **Done only once the answer is**, so the delegate call above is too.
    private func deliver(action: String, request: String) async {
        guard let answer = Self.response(action: action, request: request) else {
            log.notice("reminders: no answer in \(action, privacy: .public) on \(request, privacy: .public)")
            return
        }
        guard let respond else {
            log.fault("reminders: an answer arrived with nothing listening")
            return
        }
        await respond(answer)
    }
}
