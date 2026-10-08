import Capture
import Foundation
@testable import MacCapture
import Synchronization
import Testing
import XiaolaiDictTestSupport

@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// **Hover never asks for Screen Recording; it only finds out.**
///
/// This type had an `ensure()` that raised the system prompt on a declined probe, and the
/// recogniser called it — so a hover, a gesture made mid-sentence in another app, could put a
/// permission dialog on the reader's screen, stopped only by a cancellation check that fired once
/// the 5 s capture deadline had passed. There is nothing here to prompt with now: the type is a
/// probe, and these check that the recogniser answers each of the three values without a prompt.
struct ScreenRecordingAccessTests {
    /// Counts probes. Checked `Sendable`, with a lock: read from the test, written from an
    /// `@Sendable` closure.
    final class Counter: Sendable {
        private let count = Mutex(0)
        var probes: Int { count.withLock { $0 } }
        func bump() { count.withLock { $0 += 1 } }
    }

    private func recogniser(_ found: PermissionProbe) -> (ScreenTextRecogniser, Counter) {
        let counter = Counter()
        return (ScreenTextRecogniser(access: ScreenRecordingAccess(probe: { counter.bump(); return found })), counter)
    }

    private static let window = ListedWindow(pid: 1, bounds: CGRect(x: 0, y: 0, width: 10, height: 10), windowID: 1)

    /// A declined grant is reported as declined — the refusal that names where to go — and asked
    /// once. **The type has no request to make**, so no path through it can raise a dialog.
    @Test func aDeclinedGrantIsReportedNotRequested() async {
        let (recogniser, counter) = recogniser(.declined)
        await #expect(throws: RecognitionError.screenRecordingDenied) {
            try await recogniser.read(at: .zero, window: Self.window, policy: .shipped)
        }
        #expect(counter.probes == 1)
    }

    /// A probe that could not tell is not a refusal, and must not be reported as one: it sends a
    /// reader whose grant has stood for days to a list where the switch is already on.
    @Test func anUnreadableGrantIsNeitherARefusalNorAGrant() async {
        let (recogniser, _) = recogniser(.couldNotTell)
        await #expect(throws: RecognitionError.screenRecordingUnreadable) {
            try await recogniser.read(at: .zero, window: Self.window, policy: .shipped)
        }
    }

    /// **The hover path turns a refusal into the notice, not into a prompt.** The reader reads
    /// `.needsScreenRecording`, which the watcher hands to the app to say once.
    @MainActor
    @Test func aRefusedCaptureAsksTheReaderNotTheSystem() async {
        let screen = ScriptedScreenWords()
        screen.windows = [Self.window]
        screen.recognition = .failure(RecognitionError.screenRecordingDenied)
        let reader = HoverReader(policy: { .shipped }, captureDeadline: HoverFixtures.patient, source: screen)
        let outcome = await reader.read(
            at: CGPoint(x: 5, y: 5), modifiersHeld: [.option], tappedTwice: false,
            pointerStillFor: .seconds(1), begin: { 1 })
        guard case .needsScreenRecording(request: 1) = outcome else {
            Issue.record("a refused capture answered \(outcome)")
            return
        }
    }

    /// An app whose panel opens, with no real hot key behind it.
    @MainActor
    private func app() -> XiaolaiDictApp {
        let suite = TemporaryDefaults.suite()
        return XiaolaiDictApp(defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()),
                              models: .temporary(defaults: suite), panelWindows: .alwaysOpen)
    }

    /// **Told once per launch.** The second hover that needs the pixels is a log line.
    @MainActor
    @Test func theNoticeIsShownOncePerLaunch() {
        let app = app()
        #expect(app.screenRecordingNeeded(at: UpPoint(x: 1, y: 1), request: app.beginRequest()))
        #expect(!app.screenRecordingNeeded(at: UpPoint(x: 1, y: 1), request: app.beginRequest()),
                "the notice was shown twice")
    }

    /// **A notice under a superseded number shows nothing, and is not spent.** The hover asked
    /// before the reader pressed the shortcut; its notice must not replace that lookup's panel.
    /// Red if the notice takes a fresh number instead of claiming its own.
    @MainActor
    @Test func aNoticeForASupersededHoverReplacesNothing() {
        let app = app()
        let hover = app.beginRequest()
        app.lookUpWord("tide")
        #expect(!app.screenRecordingNeeded(at: UpPoint(x: 1, y: 1), request: hover))
        #expect(app.screenRecordingNeeded(at: UpPoint(x: 1, y: 1), request: app.beginRequest()),
                "a refused claim spent the launch's one notice")
    }

    /// **A notice the compositor never drew is not spent.** `show` answers for the request; only
    /// the compositor is evidence the reader saw it. Red if the notice is spent on `show` alone.
    @MainActor
    @Test func aNoticeNeverDrawnIsNotSpent() async {
        let suite = TemporaryDefaults.suite()
        let app = XiaolaiDictApp(defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()),
                                 models: .temporary(defaults: suite),
                                 panelWindows: LookupPanelController.Windows(open: { _ in true }, dismiss: { _ in true }, drawn: { _ in false }))
        #expect(app.screenRecordingNeeded(at: UpPoint(x: 1, y: 1), request: app.beginRequest()))
        await HoverFixtures.settle { app.hover.screenRecordingNotice == .unsaid }
        #expect(app.hover.screenRecordingNotice == .unsaid, "a notice nobody saw was spent")
    }

    /// **A lookup that drew nothing still ends its timeline** (audit round 3, #39) — as not shown,
    /// never as recorded or superseded. Red if the runner's nil skips `finish`.
    @MainActor
    @Test func aLookupNeverDrawnEndsItsTimingsAsNotShown() async throws {
        let suite = TemporaryDefaults.suite()
        let app = XiaolaiDictApp(defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()),
                                 models: .temporary(defaults: suite),
                                 panelWindows: LookupPanelController.Windows(open: { _ in true }, dismiss: { _ in true }, drawn: { _ in false }))
        app.lookUpWord("tide")
        let lookup = try #require(app.lookup)
        await lookup.value
        let line = try #require(app.timings.lastLine)
        #expect(line.hasSuffix(" ms") && line.contains("not shown"), "the line was \(line)")
    }

    /// **A notice the panel could not show is not spent.** Red if the flag is set before showing.
    @MainActor
    @Test func aNoticeThatCouldNotBeShownIsNotSpent() {
        let suite = TemporaryDefaults.suite()
        let opens = Mutex(0)
        let app = XiaolaiDictApp(defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()),
                                 models: .temporary(defaults: suite),
                                 panelWindows: LookupPanelController.Windows(
                                    open: { _ in opens.withLock { $0 += 1; return $0 > 1 } }, dismiss: { _ in true }))
        #expect(!app.screenRecordingNeeded(at: UpPoint(x: 1, y: 1), request: app.beginRequest()), "the panel did not open")
        #expect(app.screenRecordingNeeded(at: UpPoint(x: 1, y: 1), request: app.beginRequest()),
                "a notice that was never shown spent the launch's one")
    }
}

struct ScreenRecordingLocationTests {
    /// macOS 27 renamed this list too, exactly as it renamed Accessibility's.
    @Test func macOS27NamesItScreenAndSystemAudioRecording() {
        #expect(PrivacySettings.screenRecordingLocation(majorVersion: 27)
                == "System Settings → Privacy & Security → Screen & System Audio Recording")
    }

    @Test func earlierMacOSNamesItScreenRecording() {
        #expect(PrivacySettings.screenRecordingLocation(majorVersion: 26)
                == "System Settings → Privacy & Security → Screen Recording")
    }

    /// The refusal has to say where to go, because after the first prompt there is no second one. Said by the
    /// instrument that prints it since the recogniser left the app (2026-10-08, P5): the list's name is the view layer's.
    @Test func theRefusalNamesTheList() {
        let message = LookupCommand.screenRecordingDenied
        // The whole location, not two words that happen to appear in it. "Screen: open System
        // Settings" satisfied the old pair while naming neither the permission nor the path.
        #expect(message.contains(PrivacySettings.screenRecordingLocation))
    }

    /// The unreadable case must *not* name it. Sending a reader to a list where the switch is
    /// already on is how a transient failure turns into a support question.
    @Test func theUnreadableCaseSendsTheReaderNowhere() {
        let message = RecognitionError.screenRecordingUnreadable.errorDescription ?? ""
        #expect(!message.contains("System Settings"))
        #expect(!message.isEmpty, "a failure still has to say something")
    }
}

/// One question, asked in one place.
///
/// `Permission.isGranted` probes Screen Recording with `SCShareableContent` — the API the
/// recogniser actually captures through — while `ScreenRecordingAccess` asked
/// `CGPreflightScreenCaptureAccess()`. Two APIs answering one question is how a setup checklist
/// comes to draw a tick while hover still refuses.
///
/// **The assertion is mechanical because a behavioural one cannot fail here.** On any machine
/// where the permission is granted both APIs answer true, so a test comparing them passes
/// vacuously — against the divergence as much as against the fix. What can fail is the presence of
/// the second API: `CGPreflightScreenCaptureAccess` is the one that does not match the capture, so
/// it must appear in `Sources` nowhere at all. Every caller goes through
/// `Permission.screenRecording` instead.
struct ScreenRecordingProbeTests {
    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
    }

    @Test func theGrantCheckNeverAsksCoreGraphics() throws {
        let (offenders, scanned, read) = try SourceScan.offenders(
            of: "CGPreflightScreenCaptureAccess", under: sources)

        // The positive control, and a floor this tree justifies rather than a round number: the
        // package ships well over a hundred Swift files across its four modules, so anything near
        // 100 means a subtree went unread. `SourceScan` throws on a traversal error, which is the
        // other half — this used to skip an unreadable directory in silence.
        #expect(scanned > 100, "scanned only \(scanned) files — the source walk is broken")
        // Named, not counted: the probe's owner, its access wrapper and the capture it must agree with — all three in
        // `MacCapture` since 2026-10-08 (P5), where the probe is `Permission.swift`.
        let unread = SourceScan.unread(
            ["Permission.swift", "ScreenRecordingAccess.swift", "ScreenTextRecogniser.swift"], in: read)
        #expect(unread.isEmpty, "the scan no longer reads \(unread)")
        #expect(
            offenders.isEmpty,
            "CGPreflightScreenCaptureAccess does not match the API the capture uses, so it must not decide the grant: \(offenders.joined(separator: ", "))")
    }
}
