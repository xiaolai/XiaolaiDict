import Foundation
import XiaolaiDictBase
import os

/// **A click on a review reminder, to the Library on Review — once there is a window to open.**
///
/// A click can launch the app, and its answer arrives before `MenuBarLabel`'s `.task` has handed over
/// the window actions: `WindowActions.shared.open` is nil then, and opening through it would open
/// nothing, silently. So the route **waits for them, within the five seconds** the setup board and the
/// triggers already allow; past that it logs a fault and answers `false` — never a silent no-op that
/// reads as a window that opened (ADR-0018).
@MainActor
final class ReviewRoute {
    /// The bound `openSetupOnFirstLaunch` and `armTriggersWhenThereIsAWindowToDrawInto` wait for.
    static let actionsDeadline: Duration = .seconds(5)

    private let areWired: @MainActor () -> Bool
    private let opening: @MainActor () -> Bool
    private let fault: @MainActor (String) -> Void
    private let limit: Duration

    init(areWired: @escaping @MainActor () -> Bool, open: @escaping @MainActor () -> Bool,
         fault: @escaping @MainActor (String) -> Void = { message in
             Logger(subsystem: XiaolaiDictIdentity.app, category: "reminders").fault("\(message, privacy: .public)")
         },
         limit: Duration = ReviewRoute.actionsDeadline) {
        self.areWired = areWired
        self.opening = open
        self.fault = fault
        self.limit = limit
    }

    /// Opens the Library on Review and brings it forward, once the window actions exist. Says whether
    /// it could.
    func open() async -> Bool {
        guard await Instrument.settle(until: limit, areWired) else {
            fault("reminders: no window actions after \(limit); Review was not opened")
            return false
        }
        return opening()
    }
}
