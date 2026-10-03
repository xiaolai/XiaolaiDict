import AppKit
@testable import XiaolaiDict
import DictionaryModel
import Synchronization
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

    /// **Our own window is recognised from the compositor's list, before Accessibility is asked.**
    ///
    /// The `pid` check on what `AXUIElementCopyElementAtPosition` returns cannot do this job: the crash
    /// is *inside* that call. A hit test at a point one of XiaolaiDict's own windows covers is serviced
    /// in this process, on the calling thread — the detached task's — so `NSHostingView` answers it and
    /// the panel's SwiftUI body is evaluated off the main actor, where its first `@MainActor` call
    /// traps. Crash report 2026-09-25: `EXC_BREAKPOINT` in `dispatch_assert_queue`, under
    /// `-[NSApplication accessibilityHitTest:]` → `LookupPanelContent.content`.
    ///
    /// The point is off every screen, so Accessibility has nothing to find there and the only thing
    /// that can produce `.ourOwnWindow` is the compositor's answer being consulted first.
    @Test func thepointerOverOurOwnWindowIsRefusedWithoutAskingAccessibility() {
        let outcome = ScreenWordReader.target(
            at: CGPoint(x: -9_000, y: -9_000),
            access: AccessibilityAccess(probe: { .granted }, request: { true }),
            windows: { [ListedWindow(pid: getpid(), bounds: CGRect(x: -9_200, y: -9_200, width: 400, height: 400))] })
        if case .ourOwnWindow = outcome {} else {
            Issue.record("a hover over XiaolaiDict's own window reached Accessibility: \(outcome)")
        }
    }

    /// The negative control: another app's window at the same point is not refused as ours. Without it
    /// the check above would pass on a rule that refused every hover.
    @Test func thepointerOverAnotherAppsWindowIsNotOurOwn() {
        let outcome = ScreenWordReader.target(
            at: CGPoint(x: -9_000, y: -9_000),
            access: AccessibilityAccess(probe: { .granted }, request: { true }),
            windows: { [ListedWindow(pid: getpid() + 1, bounds: CGRect(x: -9_200, y: -9_200, width: 400, height: 400))] })
        if case .ourOwnWindow = outcome { Issue.record("another app's window read as XiaolaiDict's own") }
    }

    /// **The grant is still the first refusal, and it is still the cheapest.** Hover pays for the
    /// window list only once the gate has let it through — the invariant that a reader who is simply
    /// reading pays for nothing, which putting a compositor query first would have undone.
    @Test func arefusedGrantAnswersBeforeTheWindowListIsBuilt() {
        let built = Mutex(false)
        let outcome = ScreenWordReader.target(
            at: .zero, access: AccessibilityAccess(probe: { .declined }, request: { false }),
            windows: { built.withLock { $0 = true }; return [] })
        if case .none = outcome {} else { Issue.record("a missing grant did not refuse: \(outcome)") }
        #expect(!built.withLock { $0 }, "the window list was built for a hover the grant had refused")
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

    // Whether the hover path asks the script filter is driven by behaviour in
    // `HoverReaderSourceTests.aWordInAScriptNotStudiedIsRefused`, not read from the source.

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
    ///
    /// **Asserted on the rows, not the source.** This grepped `LookupRunner.swift` for one spelling of
    /// the call, and a refactor that kept the behaviour exactly but respelled it turned the check red —
    /// while a respelling that dropped the script and kept the string would have stayed green. And it is
    /// the *surface* that is classified: a Chinese word in an English sentence is filed under Han.
    @MainActor
    @Test func everyRecordedLookupCarriesTheScriptItWasWrittenIn() async throws {
        let panel = RecordingPanel()
        var early: [LookupRecording] = []
        let runner = LookupRunner(
            client: DictionaryClient(deadline: .milliseconds(50), connect: { _ in NeverReplies() }, fallback: { _ in "plain" }),
            panel: panel, initialRecording: { row, _ in early.append(row) })
        let selection = Selection(
            text: "书", sentence: "He wrote 书 on the board.", rangeInSentence: NSRange(location: 9, length: 1),
            quality: .accessibility(.accessibilityTextRange, context: .complete), place: ReadingPlace())
        let final = try #require(await runner.run(selection, near: .zero, requestedAt: .now, ticket: panel.newRequest()))
        #expect(!early.isEmpty)
        #expect(early.allSatisfy { $0.record.script == .han }, "a row was written without the word's script")
        #expect(final.record.script == .han, "the sentence was classified instead of the word")
    }

    /// And the drawer asks for the reader's set rather than defaulting to everything.
    @Test func theDrawerFiltersByTheScriptsTheReaderStudies() throws {
        let app = try source("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        #expect(app.contains("studying: studying"), "the drawer does not pass the reader's scripts")
        #expect(app.contains("hover.policy.scripts"),
                "the drawer's filter is not the setting the hover gate reads")
    }

    /// **Two apps showing the same word at the same place are two hovers.** The suppression key was
    /// the word and an 8-point cell and nothing else, so resting on `run` in a terminal and then on
    /// `run` at the same screen position in a browser looked like the same lookup, and the second
    /// was silently dropped.
    @Test func theSuppressionKeyTellsTwoAppsApart() {
        let point = CGPoint(x: 100, y: 200)
        let terminal = Self.selection("run", in: "com.apple.Terminal")
        let browser = Self.selection("run", in: "com.apple.Safari")
        #expect(HoverReader.key(terminal, at: point) != HoverReader.key(browser, at: point))
        #expect(HoverReader.key(terminal, at: point) == HoverReader.key(terminal, at: point))
    }

    /// **Letting go of the modifier ends the hover, so the next one may repeat the word.**
    /// Suppression was only ever cleared by a *different* successful lookup, so a reader who looked
    /// a word up, released the key, and reached for the same word again got nothing — and the way
    /// out was to look up something else first, which nobody would guess.
    ///
    /// Safe to drive directly: with no modifier held the gate refuses before any Accessibility or
    /// capture work, which is the ordering the gate exists for.
    @MainActor
    @Test func releasingTheModifierClearsTheSuppressedWord() async {
        let reader = HoverReader(policy: { .shipped }, pause: { HoverPause() })
        reader.lastLookedUp = "run@12x25"
        let outcome = await reader.read(
            at: CGPoint(x: 100, y: 200), modifiersHeld: [], tappedTwice: false, pointerStillFor: .seconds(1),
            begin: { 0 })
        guard case .quiet(.modifierNotHeld) = outcome else {
            Issue.record("expected the modifier gate to refuse, got \(outcome)")
            return
        }
        #expect(reader.lastLookedUp == nil, "the word stayed suppressed after the hover ended")
    }

    private static func selection(_ text: String, in bundleID: String) -> Selection {
        Selection(
            text: text, sentence: text, rangeInSentence: NSRange(location: 0, length: text.utf16.count),
            quality: .accessibility(.accessibilityTextMarkers, context: .complete),
            place: ReadingPlace(bundleID: bundleID, name: bundleID))
    }

    /// **`XiaolaiDictApp` reads the suite it was given and no other.**
    ///
    /// `init(defaults:)` exists so a test never touches the reader's own preferences, and every
    /// store in the initialiser was handed it — while `hoverEnabled` went on reading and *writing*
    /// `UserDefaults.standard`. So a test that toggled hover switched it off for the person using
    /// the Mac, which is the unit-test form of the objection this project makes to driving the GUI
    /// on the building machine.
    ///
    /// Mechanical rather than a test of that one property, because the next setting added is the
    /// one that would slip. Comments are stripped first: the fix's own explanation names the thing
    /// it bans, and a scanner that cannot tell an explanation from a call is satisfied by prose.
    @Test func theAppReadsOnlyTheDefaultsSuiteItWasGiven() throws {
        let source = try source("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        #expect(!source.contains("UserDefaults.standard"),
                "a setting is reaching past the injected suite to the reader's own preferences")
    }
}
