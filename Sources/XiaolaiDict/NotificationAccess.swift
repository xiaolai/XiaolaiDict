import Foundation
import XiaolaiDictBase
import XiaolaiDictUI
import os

/// **Whether XiaolaiDict may post a reminder, and asking for it — one owner** (ADR-0017's rule, for the
/// third permission).
///
/// The same arrangement as `AccessibilityAccess`: one place probes, one place asks, and nothing else
/// does either. `ReminderDeliveryTests` fails if `requestAuthorization` is called from any other file.
///
/// **`granted()` never prompts; `ensure()` prompts only where the reader has never answered**, and
/// only the Settings switch calls it: a reminder is something the reader turns on, so nothing they did
/// not ask for — a launch, a grade, a re-plan — may put a system dialog in front of them.
@MainActor
struct NotificationAccess {
    let scheduling: any ReminderScheduling
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "reminders")

    init(scheduling: any ReminderScheduling) {
        self.scheduling = scheduling
    }

    /// The grant as macOS reports it — four-valued, and asked without a prompt.
    func granted() async -> NotificationGrant {
        await scheduling.authorization()
    }

    /// **The Settings switch's, and nobody else's.** Asks where the reader has never answered; a
    /// refusal is never asked again — macOS would not show the prompt, so it would be a click that does
    /// nothing — and a probe that could not tell is not asked over either: it says nothing about consent.
    func ensure() async -> NotificationGrant {
        switch await granted() {
        case .granted: return .granted
        case .declined: return .declined
        case .couldNotTell: return .couldNotTell
        case .notAsked:
            do {
                return try await scheduling.requestAuthorization() ? .granted : .declined
            } catch {
                // The domain and code are the diagnosis; the message is not logged.
                let failure = error as NSError
                log.error("reminders: the request failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
                return .couldNotTell
            }
        }
    }
}
