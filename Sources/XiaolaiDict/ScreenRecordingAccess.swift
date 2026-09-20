import CoreGraphics

/// Whether XiaolaiDict may record the screen, and asking for it if not.
///
/// XiaolaiDict asks for Accessibility with a prompt and simply assumed Screen Recording. ScreenCaptureKit
/// does not prompt on its own — it fails with "the user declined TCCs for application, window,
/// display capture" — so a reader who has never granted it gets nothing from the recogniser and is
/// never told why. The refusal that exposed this came from TCC denying a process launched over
/// SSH rather than from a missing grant, but the gap it revealed is real: nothing in XiaolaiDict ever
/// asked for this permission, and the error the reader saw named neither the permission nor where
/// to grant it.
///
/// The two calls are closures so the decision can be tested without the system's answer; nothing
/// else about this is testable, and the decision is the part that was wrong.
struct ScreenRecordingAccess: Sendable {
    var isGranted: @Sendable () -> Bool
    var request: @Sendable () -> Bool

    static let system = ScreenRecordingAccess(
        isGranted: { CGPreflightScreenCaptureAccess() },
        request: { CGRequestScreenCaptureAccess() })

    /// True when XiaolaiDict may capture, asking once if it has not been asked before.
    ///
    /// macOS shows the prompt only from a GUI session and only while the status is undetermined.
    /// After a refusal there is no second prompt, which is why a false answer has to be reported to
    /// the reader with somewhere to go rather than retried.
    func ensure() -> Bool { isGranted() || request() }
}
