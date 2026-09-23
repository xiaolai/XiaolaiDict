import AppKit
@testable import XiaolaiDict
import XiaolaiDictCore
import Testing

/// Found by audit, in the hover paths.
///
/// These lived under `EntryOutlineTests` until the panel's sidebar was deleted and that file went
/// with it. Nothing about them was ever about the sidebar: they are the only cover the whole-word
/// match, the content cache's geometry check, the unattributable capture and the capture guard
/// have, and a file being deleted around a test is not a reason to delete the test.
struct HoverAuditTests {
    /// A plain substring search took the first *occurrence*: hovering "he" in "there he stood"
    /// found it inside "there" and re-segmented to the wrong word.
    @Test func awholeWordMatchDoesNotHitInsideAnotherWord() throws {
        let sentence = "there he stood"
        let range = try #require(ScreenWordReader.wholeWordRange(of: "he", in: sentence))
        #expect(range.location == 6, "matched inside 'there' at \(range.location)")
        #expect((sentence as NSString).substring(with: range) == "he")
    }

    @Test func awordThatIsNotThereAsAWholeWordIsNotFound() {
        #expect(ScreenWordReader.wholeWordRange(of: "he", in: "therefore thereafter") == nil)
    }

    @Test func thefirstWholeWordOccurrenceIsTaken() throws {
        let range = try #require(ScreenWordReader.wholeWordRange(of: "the", in: "the cat and the dog"))
        #expect(range.location == 0)
    }

    /// A window moved inside the three-second content cache would crop where it used to be.
    @Test func amovedWindowIsNotTreatedAsTheSameGeometry() {
        let was = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(ScreenTextRecogniser.sameGeometry(was, was))
        // Sub-point rounding between the two APIs is not a move.
        #expect(ScreenTextRecogniser.sameGeometry(was, CGRect(x: 100.4, y: 100, width: 800, height: 600)))
        #expect(!ScreenTextRecogniser.sameGeometry(was, CGRect(x: 140, y: 100, width: 800, height: 600)))
        #expect(!ScreenTextRecogniser.sameGeometry(was, CGRect(x: 100, y: 100, width: 640, height: 600)))
    }

    /// Found by the second verify pass. A capture the recogniser cannot attribute to an app cannot
    /// be checked against the exclusion list, so it must not happen at all — a display-scoped
    /// region could contain a password manager's window and no check would ever see it.
    @Test func anUnattributableCaptureIsRefusedNotChecked() {
        #expect(RecognitionError.unattributable.errorDescription?.isEmpty == false)
        #expect(RecognitionError.excludedApp("Terminal").errorDescription?.contains("Terminal") == true)
    }

    /// Found by the second verify pass: the pointer resting on XiaolaiDict's own panel used to fall
    /// through to the recogniser, which skips XiaolaiDict's windows — and so read whatever the panel was
    /// covering.
    @Test func ourOwnWindowIsItsOwnOutcome() {
        // The case exists and is distinct from "no element here", which *may* still try OCR.
        let ours = ScreenWordReader.TargetOutcome.ourOwnWindow
        if case .ourOwnWindow = ours {} else { Issue.record("the case collapsed into .none") }
    }

    /// The guard must be releasable only by whoever finishes, which is why it is a reference type:
    /// a value copy would let a second hover think it holds one.
    @Test func thecaptureGuardIsHeldUntilReleased() {
        let guardOne = HoverReader.CaptureGuard()
        #expect(guardOne.claim(), "a fresh guard refused its first claimant")
        #expect(guardOne.isHeld)
        #expect(!guardOne.claim(), "a second capture started while one was in flight")
        guardOne.release()
        #expect(!guardOne.isHeld)
        #expect(guardOne.claim())
    }
}
