import MacCapture
import Testing
import XiaolaiDictUI

/// **What the reader is told when a selection cannot be looked up.** The selection reader decides which refusal it is,
/// typed, and `MacCaptureTests` holds it to that; the words are the view layer's (`SelectionRefusals.swift`), and these
/// hold them to the case. Moved out of `SelectionTests` with the words, which left the reader on 2026-10-08 (P5).
struct SelectionRefusalTests {
    /// macOS 27 renamed the list the permission is granted in; the message must name the one the
    /// reader will find. Found when a reader looked for "Accessibility" on macOS 27 and it was not there.
    @Test func thePermissionMessageNamesTheListOnThisMacOS() {
        #expect(PrivacySettings.accessibilityLocation(majorVersion: 26) == "System Settings → Privacy & Security → Accessibility")
        #expect(PrivacySettings.accessibilityLocation(majorVersion: 27)
            == "System Settings → Privacy & Security → Device Control and Data Access")
        #expect(SelectionReader.Refusal.failed(.accessibilityDisabled, app: "Safari").message
                .contains(PrivacySettings.accessibilityLocation))
    }

    /// Through the refusal the reader returns, which is the view layer's whole public surface for these words: the
    /// sentence for each failure is an internal helper of `SelectionRefusals.swift` (it was public with no caller
    /// outside the view layer until 2026-10-08).
    @Test(arguments: [CaptureError.notResponding, .deadlineExceeded, .accessibilityDisabled, .appUnavailable, .accessibilityRefused, .cancelled])
    func eachFailureHasItsOwnMessage(error: CaptureError) {
        let others = [CaptureError.notResponding, .deadlineExceeded, .accessibilityDisabled, .appUnavailable, .accessibilityRefused, .cancelled]
            .filter { $0 != error }.map { SelectionReader.Refusal.failed($0, app: "Safari").message }
        #expect(!others.contains(SelectionReader.Refusal.failed(error, app: "Safari").message))
    }

    /// **Each refusal says what it is, with what it carries.** The reader's own tests read these words inline — "too
    /// large to search", "too long", a locked screen — until the words left the reader; they now assert the case, and
    /// this asserts the words. Red if a case is worded as another, or drops the app, the count or the budget.
    @Test func eachRefusalSaysWhatItIs() {
        #expect(SelectionReader.Refusal.nothingSelected(app: "TextEdit").message
                .hasPrefix("Nothing is selected in TextEdit, or it does not expose"))
        let searched = SelectionReader.Refusal.searchLimitReached(app: "Safari", limit: 400).message
        #expect(searched.contains("Safari's focused element") && searched.contains("too large to search"))
        #expect(searched.contains("within 400 elements"))
        #expect(SelectionReader.Refusal.noWord(app: "TextEdit").message == "The selection in TextEdit has no word in it.")
        #expect(SelectionReader.Refusal.tooLong(app: "TextEdit", characters: 99).message
                == "The selection in TextEdit is 99 characters — too long to look up.")
        #expect(SelectionReader.Refusal.failed(.accessibilityRefused, app: "Safari").message.contains("locked"))
        // A failure is worded as the reader's own failures are, the budget it ran under included.
        #expect(SelectionReader.Refusal.failed(.deadlineExceeded, app: "Safari").message
                == "Reading the selection from Safari took longer than "
                + "\(SelectionReader.budget.components.seconds) seconds, so it was stopped.")
    }
}
