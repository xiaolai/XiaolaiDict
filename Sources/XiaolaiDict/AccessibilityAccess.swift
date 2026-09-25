import ApplicationServices
import XiaolaiDictUI

/// Whether XiaolaiDict may read another app's selection, and asking for it if not.
///
/// **The question is `Permission.accessibility`'s, not one of this type's own** — the same
/// arrangement, for the same reason, as `ScreenRecordingAccess`. That type's own comment says why it
/// exists: "It used to ask `CGPreflightScreenCaptureAccess()` while the Settings pane asked
/// `SCShareableContent` — two APIs answering one question, which is how a surface comes to draw a
/// tick while this gate still refuses."
///
/// **Accessibility never got that fix and had three implementations.** `lookUpSelection` called
/// `AXIsProcessTrustedWithOptions` with a prompt and a second copy of the option key literal;
/// `ScreenWordReader.target` called `AXIsProcessTrusted()`; `Permission.accessibility.probe` called
/// it a third time for the Settings pane and the setup board. Nothing had gone wrong yet, which is
/// the only reason it survived the change that fixed the sibling permission — a second instance of
/// a defect is a class, and this was the second instance.
///
/// **Synchronous, unlike its sibling, and that is the API rather than a shortcut taken here.**
/// `AXIsProcessTrusted()` answers in-process and cannot fail, where `SCShareableContent` is a call
/// into another process that needs a deadline. So `lookUpSelection` still answers the reader before
/// its first await, which is what puts "Accessibility is off" on screen instead of an empty panel.
struct AccessibilityAccess: Sendable {
    var probe: @Sendable () -> PermissionProbe
    var request: @Sendable () -> Bool

    static let system = AccessibilityAccess(
        probe: { Permission.accessibilityTrust },
        request: { Permission.accessibility.request() })

    /// Whether a selection may be read. **Never prompts**, for the reason `ScreenRecordingAccess`
    /// does not prompt on a hover the reader walked away from: a dialog attached to nothing they
    /// asked for. Hover reads this.
    func granted() -> Bool { probe() == .granted }

    /// The same question for a reader who has just pressed the shortcut, **and it asks where they
    /// have never been asked.** macOS prompts once per permission ever, so on every press after the
    /// first this is a check; the press it is not a check on is the one that matters.
    func ensure() -> PermissionProbe {
        switch probe() {
        case .granted: .granted
        case .declined: request() ? .granted : .declined
        // `AXIsProcessTrusted()` returns a `Bool` and cannot say why, so this does not arise today.
        // Carried rather than collapsed: the one thing `PermissionProbe` exists to prevent is a
        // third state being read as one of its neighbours, and a gate written as `!= .granted`
        // would prompt on it.
        case .couldNotTell: .couldNotTell
        }
    }
}
