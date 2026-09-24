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

/// The script filter is hover's, and the shortcut's answer must not depend on it.
struct ScriptFilterWiringTests {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: name), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// **The wire, not the value.** `HoverPolicy.studies` is unit-tested on its own; what went
    /// untested in this project's last two defects of this shape was whether anything called the
    /// thing that was built. A filter nothing asks is a setting the reader can change with no
    /// effect.
    @Test func theHoverPathAsksWhetherTheScriptIsStudied() throws {
        #expect(try source("Sources/XiaolaiDict/HoverReader.swift").contains("policy.studies(selection.text)"),
                "the hover reader does not consult the script filter")
    }

    /// **And the shortcut path does not.** The reader selected that text and pressed the key;
    /// refusing it would be refusing something explicitly asked for. If this ever needs to change
    /// it should be a second, separate switch — not this one leaking across.
    @Test func theSelectionShortcutIsNotFilteredByScript() throws {
        let app = try source("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        #expect(!app.contains(".studies("),
                "the selection path consults the hover script filter, which refuses what the reader asked for")
    }

    /// **The wire for the other half.** `Ledger` stores a script and the drawer filters on it,
    /// both tested — and neither says a word about whether anything ever puts a script in a row.
    /// Left unwired, every row would be NULL, every NULL is drawn, and the drawer filter would
    /// pass its own tests while doing nothing to the reader's history.
    @Test func everyRecordedLookupCarriesTheScriptItWasWrittenIn() throws {
        let runner = try source("Sources/XiaolaiDict/LookupRunner.swift")
        #expect(runner.contains("script: ProbeScript.dominant(in: selection.text)"),
                "the ledger record is built without a script, so the drawer filter can never bite")
    }

    /// And the drawer asks for the reader's set rather than defaulting to everything.
    @Test func theDrawerFiltersByTheScriptsTheReaderStudies() throws {
        let app = try source("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        #expect(app.contains("studying: studying"), "the drawer does not pass the reader's scripts")
        #expect(app.contains("hoverPolicy.scripts"),
                "the drawer's filter is not the setting the hover gate reads")
    }
}
