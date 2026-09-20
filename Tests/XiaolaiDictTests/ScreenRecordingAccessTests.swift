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

    @Test func alreadyGrantedIsAllowedWithoutAsking() {
        let (permission, counter) = access(granted: true)
        #expect(permission.ensure())
        #expect(counter.asks == 0, "a granted permission must not raise a prompt")
    }

    @Test func notGrantedAsksAndIsAllowedWhenTheReaderAgrees() {
        let (permission, counter) = access(granted: false, grantedByAsking: true)
        #expect(permission.ensure())
        #expect(counter.asks == 1)
    }

    /// A refusal that stays refused. The prompt appears once; afterwards macOS shows nothing and
    /// the reader has to be sent to Settings, which is why the refusal carries a location.
    @Test func aRefusalIsReportedRatherThanRetriedForever() {
        let (permission, counter) = access(granted: false, grantedByAsking: false)
        #expect(!permission.ensure())
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
