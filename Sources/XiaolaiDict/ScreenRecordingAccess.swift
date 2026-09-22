import Synchronization
import XiaolaiDictUI

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
/// **The question is `Permission.screenRecording`'s, not one of this type's own.** It used to ask
/// `CGPreflightScreenCaptureAccess()` while the Settings pane asked `SCShareableContent` — two APIs
/// answering one question, which is how a surface comes to draw a tick while this gate still
/// refuses. Delegating means they cannot diverge, rather than being expected not to.
///
/// The two calls are closures so the decision can be tested without the system's answer; nothing
/// else about this is testable, and the decision is the part that was wrong.
struct ScreenRecordingAccess: Sendable {
    var isGranted: @Sendable () async -> Bool
    var request: @Sendable () -> Bool

    static let system = ScreenRecordingAccess(
        isGranted: { await granted.value { await Permission.screenRecording.isGranted } },
        request: { Permission.screenRecording.request() })

    /// True when XiaolaiDict may capture, asking once if it has not been asked before.
    ///
    /// macOS shows the prompt only from a GUI session and only while the status is undetermined.
    /// After a refusal there is no second prompt, which is why a false answer has to be reported to
    /// the reader with somewhere to go rather than retried.
    func ensure() async -> Bool { await isGranted() || request() }

    private static let granted = GrantMemo()
}

/// Remembers a grant, never a refusal.
///
/// Asking `Permission.screenRecording` costs the recogniser's own 60–85 ms, and it is a *second*
/// `SCShareableContent` fetch — it does not fill the cache the capture path reads a moment later,
/// so a per-read probe would double that step for every hover that falls back to OCR. A grant is
/// the safe thing to remember: macOS does not quietly withdraw this one mid-process, it stops the
/// process. A refusal is remembered by nothing, because the reader granting it is exactly the
/// event this has to notice.
///
/// `Mutex` rather than `NSLock` because this runs in an async context, where Swift 6 makes
/// `NSLock.lock()` unavailable outright — the compiler enforcing the rule `ShareableContentCache`
/// records in a comment. Nothing is held across the `await`: the memo is read, released, and only
/// written after the probe has answered.
private final class GrantMemo: Sendable {
    private let granted = Mutex(false)

    func value(asking probe: @Sendable () async -> Bool) async -> Bool {
        if granted.withLock({ $0 }) { return true }

        let answer = await probe()
        if answer { granted.withLock { $0 = true } }
        return answer
    }
}
