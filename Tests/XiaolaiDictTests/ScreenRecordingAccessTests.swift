import Foundation
import Testing

@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// Asking for Screen Recording, which XiaolaiDict never did.
///
/// Accessibility is asked for with a prompt; Screen Recording was assumed. ScreenCaptureKit does
/// not prompt on its own — it fails with "the user declined TCCs" — so a reader who has not granted
/// it gets nothing from the recogniser and is never told why. Measured on the E2E machine, where
/// every Accessibility stage passed and the one capture path could not run.
struct ScreenRecordingAccessTests {
    private func access(granted: Bool, grantedByAsking: Bool = false) -> (ScreenRecordingAccess, Counter) {
        let counter = Counter()
        return (ScreenRecordingAccess(
            isGranted: { granted },
            request: { counter.bump(); return grantedByAsking }), counter)
    }

    final class Counter: @unchecked Sendable {
        private(set) var asks = 0
        func bump() { asks += 1 }
    }

    @Test func alreadyGrantedIsAllowedWithoutAsking() async {
        let (permission, counter) = access(granted: true)
        #expect(await permission.ensure())
        #expect(counter.asks == 0, "a granted permission must not raise a prompt")
    }

    @Test func notGrantedAsksAndIsAllowedWhenTheReaderAgrees() async {
        let (permission, counter) = access(granted: false, grantedByAsking: true)
        #expect(await permission.ensure())
        #expect(counter.asks == 1)
    }

    /// A refusal that stays refused. The prompt appears once; afterwards macOS shows nothing and
    /// the reader has to be sent to Settings, which is why the refusal carries a location.
    @Test func aRefusalIsReportedRatherThanRetriedForever() async {
        let (permission, counter) = access(granted: false, grantedByAsking: false)
        #expect(await !permission.ensure())
        #expect(counter.asks == 1)
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
        #expect(message.contains("Screen"))
        #expect(message.contains("System Settings"))
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
        let root = sources
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { throw ProbeScanFailure.unreadable(root.path) }

        var scanned = 0
        var offenders: [String] = []
        for case let file as URL in walk where file.pathExtension == "swift" {
            scanned += 1
            // Thrown rather than defaulted to "": a scanner that silently reads nothing passes
            // forever and guards nothing.
            let text = try String(contentsOf: file, encoding: .utf8)
            // Comment lines are dropped first. `Permissions.swift` names this API in prose,
            // explaining why it is *not* the one that decides — and a scanner that cannot tell a
            // call from an explanation would report the explanation as the offence.
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("CGPreflightScreenCaptureAccess") {
                offenders.append(file.lastPathComponent)
            }
        }

        // The positive control. If the walk ever stops finding files, this test would pass while
        // scanning nothing at all.
        #expect(scanned > 20, "scanned only \(scanned) files — the source walk is broken")
        let named = offenders.joined(separator: ", ")
        #expect(
            offenders.isEmpty,
            "CGPreflightScreenCaptureAccess does not match the API the capture uses, so it must not decide the grant: \(named)")
    }
}

enum ProbeScanFailure: Error { case unreadable(String) }
