import Foundation
import Synchronization
import Testing
import XiaolaiDictTestSupport

@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// Asking for Screen Recording, which XiaolaiDict never did.
///
/// Accessibility is asked for with a prompt; Screen Recording was assumed. ScreenCaptureKit does
/// not prompt on its own — it fails with "the user declined TCCs" — so a reader who has not granted
/// it gets nothing from the recogniser and is never told why. Measured on the E2E machine, where
/// every Accessibility stage passed and the one capture path could not run.
struct ScreenRecordingAccessTests {
    private func access(
        _ found: PermissionProbe, grantedByAsking: Bool = false
    ) -> (ScreenRecordingAccess, Counter) {
        let counter = Counter()
        return (ScreenRecordingAccess(
            probe: { found },
            request: { counter.bump(); return grantedByAsking }), counter)
    }

    /// Checked `Sendable`, with a lock. It is read from the test and written from an `@Sendable`
    /// closure, and `@unchecked` asserted a safety nothing provided — harmless while every test
    /// awaits one call, and an unsafe contract for the next one that does not.
    final class Counter: Sendable {
        private let count = Mutex(0)
        var asks: Int { count.withLock { $0 } }
        func bump() { count.withLock { $0 += 1 } }
    }

    @Test func alreadyGrantedIsAllowedWithoutAsking() async {
        let (permission, counter) = access(.granted)
        #expect(await permission.ensure() == .granted)
        #expect(counter.asks == 0, "a granted permission must not raise a prompt")
    }

    @Test func aDeclinedPermissionAsksAndIsAllowedWhenTheReaderAgrees() async {
        let (permission, counter) = access(.declined, grantedByAsking: true)
        #expect(await permission.ensure() == .granted)
        #expect(counter.asks == 1)
    }

    /// A refusal that stays refused. The prompt appears once; afterwards macOS shows nothing and
    /// the reader has to be sent to Settings, which is why the refusal carries a location.
    @Test func aRefusalIsReportedRatherThanRetriedForever() async {
        let (permission, counter) = access(.declined, grantedByAsking: false)
        #expect(await permission.ensure() == .declined)
        #expect(counter.asks == 1)
    }

    /// **The regression.** A probe that could not tell is not a refusal, and asking the system about
    /// it raises a dialog that grants nothing — measured 2026-09-25 against a Mac whose grant had
    /// stood for three days and whose TCC rows the dialog left untouched.
    ///
    /// The assertion is the *count*, not the answer: returning `couldNotTell` while still prompting
    /// would satisfy a test that only read the result, and the prompt is the thing the reader saw.
    @Test func anUnreadableGrantNeverRaisesAPrompt() async {
        let (permission, counter) = access(.couldNotTell, grantedByAsking: true)
        #expect(await permission.ensure() == .couldNotTell)
        #expect(counter.asks == 0, "a probe that could not tell must not raise a system dialog")
    }

    /// **A hover the reader walked away from must not raise a dialog.** The prompt is a system
    /// window that appears attached to nothing they asked for, and — measured on 2026-09-25 — it
    /// can grant nothing, because the permission was already granted.
    ///
    /// The count is the assertion. Returning `.declined` while still prompting satisfies any test
    /// that reads only the result, and the prompt is the whole of what the reader sees.
    @Test func acancelledLookupNeverRaisesAPrompt() async {
        let (permission, counter) = access(.declined, grantedByAsking: true)
        let task = Task { await permission.ensure() }
        task.cancel()
        _ = await task.value
        #expect(counter.asks == 0, "an abandoned hover put a permission dialog on the screen")
    }

    /// And it must not be laundered into a grant either — the capture would then fail with a
    /// message about capture rather than about consent, which is the older defect this file opens
    /// by describing.
    @Test func anUnreadableGrantIsNotTreatedAsPermission() async {
        let (permission, _) = access(.couldNotTell)
        #expect(await permission.ensure() != .granted)
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

    /// The refusal has to say where to go, because after the first prompt there is no second one.
    @Test func theRefusalNamesTheList() {
        let message = RecognitionError.screenRecordingDenied.errorDescription ?? ""
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
        let (offenders, scanned) = try SourceScan.offenders(
            of: "CGPreflightScreenCaptureAccess", under: sources)

        // The positive control, and a floor this tree justifies rather than a round number: the
        // package ships well over a hundred Swift files across its four modules, so anything near
        // 100 means a subtree went unread. `SourceScan` throws on a traversal error, which is the
        // other half — this used to skip an unreadable directory in silence.
        #expect(scanned > 100, "scanned only \(scanned) files — the source walk is broken")
        #expect(
            offenders.isEmpty,
            "CGPreflightScreenCaptureAccess does not match the API the capture uses, so it must not decide the grant: \(offenders.joined(separator: ", "))")
    }
}
