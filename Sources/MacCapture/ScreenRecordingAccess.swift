import Synchronization

/// Whether XiaolaiDict may record the screen — **asked, never requested.**
///
/// A capture refused for consent fails with "the user declined TCCs" rather than asking. So the
/// recogniser has to know the grant before it captures, and the reader has to be told where to give
/// it. Telling is not asking: this type used to have an `ensure()` that raised the system prompt
/// on a declined probe, and the recogniser called it — so a hover, a gesture the reader made
/// mid-sentence in another app, could put a permission dialog on their screen. A cancellation check
/// stopped it only once the 5 s capture deadline had passed. **Hover never requests the permission
/// now**: there is nothing here to request with. Asking is the setup board's button, a window the
/// reader opened to do exactly that.
///
/// **Not the same as "never a dialog".** The probe is `SCShareableContent`, the capture's own API
/// (ADR-0017), and on a Mac whose TCC has never recorded this app macOS may show its first-run consent
/// dialog for it. A probe that cannot raise one, `CGPreflightScreenCaptureAccess()`, goes on answering
/// `false` after a live grant for the rest of the process; a design that used it with a persisted
/// "already answered" flag was refuted. **Decided, not open**: the live answer is kept — ADR-0017.
///
/// **The question is `Permission.screenRecording`'s, not one of this type's own.** It used to ask
/// `CGPreflightScreenCaptureAccess()` while the Settings pane asked `SCShareableContent` — two APIs
/// answering one question, which is how a surface comes to draw a tick while this gate still
/// refuses. Delegating means they cannot diverge, rather than being expected not to.
///
/// **Three-valued**: a probe that could not tell is not a refusal. A cold `SCShareableContent` call
/// fails that way, and reporting it as a refusal sent a reader whose grant had stood for days to a
/// list where the switch was already on.
struct ScreenRecordingAccess: Sendable {
    var probe: @Sendable () async -> PermissionProbe

    static let system = ScreenRecordingAccess(
        probe: { await granted.value { await Permission.screenRecording.probe } })

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

    func value(asking probe: @Sendable () async -> PermissionProbe) async -> PermissionProbe {
        if granted.withLock({ $0 }) { return .granted }

        let answer = await probe()
        if answer == .granted { granted.withLock { $0 = true } }
        return answer
    }
}
