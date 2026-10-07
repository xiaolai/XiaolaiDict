import AppKit
import Capture
import Foundation
import Testing
import XiaolaiDictCore
import XiaolaiDictTestSupport
import XiaolaiDictUI

@testable import XiaolaiDict

/// **The menu-bar icon's tooltip, which is the witness that the lookup hot key is registered.**
///
/// `Look Up Selection    ⌃⌥D` was the menu's first item and did two jobs: it offered a click, and
/// it named the combination the system had accepted. The click was cut — a reader presses the
/// shortcut rather than choosing a menu item for it — and the naming moved to the tooltip, where
/// `menu-click --describe` reads it through `AXHelp`.
///
/// The naming is load-bearing twice over, which is why it is tested rather than left to the one
/// end-to-end stage that parses it:
///
/// - **For the reader**, it is now the only place outside Settings that says what to press.
/// - **For the harness**, the `shortcut` stage reads the combination out of it with a `sed`, and
///   `EndToEndTextTests` cannot see a `sed` — it inventories `grep`, `case` globs and Python's
///   `in`. So the binding between the sentence and the pattern that reads it is checked here.
@MainActor
struct MenuBarItemTests {
    private static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // XiaolaiDictTests
            .deletingLastPathComponent()                             // Tests
            .deletingLastPathComponent()                             // the repository
    }

    private func code(_ path: String) throws -> String {
        try String(contentsOf: Self.repository.appending(path: path), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - What a click does

    @Test func ordinaryTrayClicksOpenHistoryAndDoNotToggleIt() throws {
        let source = try code("Sources/XiaolaiDict/MenuBarItem.swift")
        let start = try #require(source.range(of: "@objc private func clicked()"))
        let end = try #require(source.range(of: "func menuNeedsUpdate", range:
            start.upperBound..<source.endIndex))
        let action = source[start.lowerBound..<end.lowerBound]
        #expect(action.contains("app.showHistory()"),
                "ordinary tray clicks do not route to the idempotent open action")
        #expect(!action.contains("app.toggleHistory()"),
                "ordinary tray clicks still toggle the open drawer closed")
    }

    private func mouse(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], number: Int = 7) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: number, clickCount: 1, pressure: 1))
    }

    /// **Control-click is a right click**, the system's rule: a trackpad with secondary click off
    /// has no other way to the menu.
    @Test func controlClickAndRightClickAreBothSecondary() throws {
        #expect(StatusItemClick.isSecondary(try mouse(.rightMouseUp)))
        #expect(StatusItemClick.isSecondary(try mouse(.rightMouseDown)))
        #expect(StatusItemClick.isSecondary(try mouse(.leftMouseUp, flags: .control)))
        #expect(!StatusItemClick.isSecondary(try mouse(.leftMouseUp)))
        #expect(!StatusItemClick.isSecondary(try mouse(.leftMouseUp, flags: .option)))
        // A VoiceOver press arrives with no event at all, and is not a request for the menu.
        #expect(!StatusItemClick.isSecondary(nil))
    }

    /// **The macOS 27 expanded-interface session must not come back untested.** It was adopted on
    /// 2026-10-02 and removed the same day: on a real Mac a right click began a session, and the
    /// menu opened after cancelling it had items whose actions never arrived — Library did nothing.
    /// No unit test or locked-screen probe can show that, because a programmatic press begins no
    /// session; so this fails until someone has clicked the menu on a real Mac and says so here.
    @Test func theItemDoesNotAdoptTheExpandedInterfaceSession() throws {
        let source = try code("Sources/XiaolaiDict/MenuBarItem.swift")
        #expect(!source.contains("expandedInterfaceDelegate ="), """
            MenuBarItem sets expandedInterfaceDelegate. Measured on macOS 27.0 with real mouse \
            events: with it set, the right-click menu's items do nothing. Re-adopt only with a \
            real-Mac test of choosing Library from that menu.
            """)
        #expect(!source.contains("NSStatusItemExpandedInterfaceDelegate {")
                && !source.contains("func statusItemDidEndExpandedInterfaceSession"),
                "the session delegate's conformance or callbacks are back")
    }

    /// The wire: a secondary click shows the menu the way ab9cb7e did, the icon shows whether its
    /// drawer is open, and VoiceOver has both surfaces by name.
    @Test func theItemRoutesClicksHighlightsAndNamesBothSurfaces() throws {
        let source = try code("Sources/XiaolaiDict/MenuBarItem.swift")
        let start = try #require(source.range(of: "@objc private func clicked()"))
        let end = try #require(source.range(of: "private func showMenu()", range: start.upperBound..<source.endIndex))
        let action = source[start.lowerBound..<end.lowerBound]
        #expect(action.contains("StatusItemClick.isSecondary(") && action.contains("showMenu()"))
        #expect(action.contains("app.showHistory()"), "a plain click does not show the drawer")
        let menu = source[end.lowerBound...].prefix(300)
        #expect(menu.contains("statusItem.menu = menu") && menu.contains("performClick(nil)")
                && menu.contains("statusItem.menu = nil"), "the menu is not attached for one click only")
        let closed = try #require(source.range(of: "func historyBecame(visible: Bool)"))
        #expect(source[closed.lowerBound...].prefix(200).contains("highlight(visible)"),
                "the icon does not show that its drawer is open")
        #expect(source.contains("setAccessibilityCustomActions("), "VoiceOver has no named route to the menu")
        #expect(source.contains("\"Show Menu\"") && source.contains("\"Show Reading History\""))
    }

    /// The drawer tells the icon when it opens and closes, by whatever route — Escape and a click
    /// elsewhere close it without the icon being touched.
    @Test func theDrawerReportsEveryChangeOfVisibilityOnce() {
        let drawer = HistoryDrawerController(
            hotkeys: HotkeyCenter(backend: FakeBackend()),
            screens: { [ScreenMetrics(frame: UpRect(x: 0, y: 0, width: 1440, height: 900),
                                      visibleFrame: UpRect(x: 0, y: 0, width: 1440, height: 875))] },
            pointer: { UpPoint(x: 100, y: 100) }, load: { .entries([]) })
        var heard: [Bool] = []
        drawer.onVisibilityChange = { heard.append($0) }
        drawer.show()
        drawer.show()
        #expect(heard == [true], "showing an open drawer was reported as a change")
        drawer.clickedOutside(at: CGPoint(x: 5, y: 5))
        drawer.hide()
        #expect(heard == [true, false])
    }

    // MARK: - Whether it is shown

    /// The Show in Menu Bar setting: absent means shown, and it is read from the suite the app was
    /// given — the key is the one Settings writes.
    @Test func theIconIsShownUnlessTheReaderSaidOtherwise() {
        let defaults = TemporaryDefaults.suite()
        #expect(MenuBarItem.visibilityKey == "ShowsMenuBarIcon")
        #expect(MenuBarItem.showsIcon(in: defaults), "a reader who never chose has no icon")
        defaults.set(false, forKey: MenuBarItem.visibilityKey)
        #expect(!MenuBarItem.showsIcon(in: defaults))
        defaults.set(true, forKey: MenuBarItem.visibilityKey)
        #expect(MenuBarItem.showsIcon(in: defaults))
    }

    @Test func theItemKeepsItsPlaceAndFollowsTheSettingBothWays() throws {
        let source = try code("Sources/XiaolaiDict/MenuBarItem.swift")
        #expect(source.contains("item.autosaveName = Self.autosaveName"), "the item has no autosave name")
        #expect(source.contains("UserDefaults.didChangeNotification, object: defaults"),
                "the setting is read once and never followed")
        #expect(source.contains("item.observe(\\.isVisible"),
                "the reader removing the icon does not reach the setting")
    }

    @Test func appRoutesShowingAndInstrumentTogglingSeparately() throws {
        let source = try code("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        let showing = try NSRegularExpression(pattern:
            #"func\s+showHistory\s*\(\s*\)\s*\{\s*drawer\.show\(\)\s*\}"#)
        let toggling = try NSRegularExpression(pattern:
            #"func\s+toggleHistory\s*\(\s*\)\s*\{\s*drawer\.toggle\(\)\s*\}"#)
        let range = NSRange(source.startIndex..., in: source)
        #expect(showing.firstMatch(in: source, range: range) != nil,
                "the app has no forwarding route to drawer.show()")
        #expect(toggling.firstMatch(in: source, range: range) != nil,
                "the existing instrument route no longer toggles the drawer")
    }

    @Test func dismissalReadsTheOwnedButtonInsteadOfGuessingAStatusBarWindow() throws {
        let source = try code("Sources/XiaolaiDict/XiaolaiDictApp.swift")
        #expect(!source.contains("contains(\"StatusBar\")"),
                "drawer dismissal still guesses ownership from a StatusBar window class")
        let assignment = try #require(source.range(of: "drawer.statusItemFrame ="))
        let rest = source[assignment.lowerBound...]
        #expect(rest.contains("[weak menuBar]"), "the live exclusion does not weakly capture its owner")
        #expect(rest.contains("menuBar?.screenFrame"),
                "drawer dismissal is not wired to the owned button's live screen rectangle")
    }

    private func attachedButton(origin: CGPoint) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: CGRect(origin: origin, size: CGSize(width: 300, height: 200)),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let container = NSView(frame: CGRect(x: 20, y: 30, width: 100, height: 80))
        let button = NSView(frame: CGRect(x: 7, y: 11, width: 24, height: 18))
        content.addSubview(container)
        container.addSubview(button)
        window.contentView = content
        window.setFrameOrigin(origin)
        return (window, button)
    }

    @Test func ownedButtonBoundsAreConvertedThroughItsAttachedWindow() throws {
        let (window, button) = attachedButton(origin: CGPoint(x: 320, y: 410))
        defer { window.close() }
        let actual = try #require(MenuBarItem.screenFrame(of: button))
        // Independent fixture arithmetic: window + container + button, all in AppKit points.
        #expect(actual == CGRect(x: window.frame.minX + 27, y: window.frame.minY + 41,
                                 width: 24, height: 18), "the result is not in AppKit screen points")
    }

    @Test func movingTheOwnedWindowRecalculatesItsButtonRectangle() throws {
        let (window, button) = attachedButton(origin: CGPoint(x: 320, y: 410))
        defer { window.close() }
        let initial = try #require(MenuBarItem.screenFrame(of: button))
        window.setFrameOrigin(CGPoint(x: 920, y: 110))
        let moved = try #require(MenuBarItem.screenFrame(of: button))
        #expect(moved != initial, "the button rectangle was cached before its window moved")
        #expect(moved == CGRect(x: window.frame.minX + 27, y: window.frame.minY + 41,
                                width: 24, height: 18))
    }

    @Test func buttonConversionPreservesNegativeScreenCoordinates() throws {
        let (window, button) = attachedButton(origin: CGPoint(x: -1200, y: -500))
        defer { window.close() }
        let actual = try #require(MenuBarItem.screenFrame(of: button))
        #expect(window.frame.minX < 0 && window.frame.minY < 0, "the negative-coordinate fixture moved")
        #expect(actual == CGRect(x: window.frame.minX + 27, y: window.frame.minY + 41,
                                 width: 24, height: 18))
        #expect(actual.minX < 0 && actual.minY < 0)
    }

    @Test func unrelatedWindowsDoNotChangeTheOwnedButtonRectangle() throws {
        let (window, button) = attachedButton(origin: CGPoint(x: 320, y: 410))
        defer { window.close() }
        let initial = try #require(MenuBarItem.screenFrame(of: button))
        let (unrelated, _) = attachedButton(origin: CGPoint(x: -700, y: 900))
        defer { unrelated.close() }
        unrelated.setFrameOrigin(CGPoint(x: 800, y: -900))
        #expect(MenuBarItem.screenFrame(of: button) == initial,
                "an unrelated window changed the owned button's rectangle")
    }

    @Test func missingButtonOrWindowHasNoExclusionRectangle() {
        #expect(MenuBarItem.screenFrame(of: nil) == nil)
        let detached = NSView(frame: CGRect(x: 20, y: 30, width: 24, height: 18))
        #expect(MenuBarItem.screenFrame(of: detached) == nil)
        let (window, button) = attachedButton(origin: CGPoint(x: 320, y: 410))
        defer { window.close() }
        button.removeFromSuperview()
        #expect(MenuBarItem.screenFrame(of: button) == nil,
                "a formerly attached button still offered a stale exclusion rectangle")
    }

    // MARK: - What it says

    /// **Both clicks are named** (audit M3): Settings and Quit sit behind a right click that nothing
    /// on screen announced.
    @Test func theTooltipNamesBothClicksWhateverTheShortcut() {
        for said in [MenuBarItem.description(ofShortcut: "⌃⌥D"), MenuBarItem.description(ofShortcut: nil)] {
            #expect(said.contains("click for Reading History"), "the left click is not named: \(said)")
            #expect(said.contains("right-click for the menu"), "the right click is not named: \(said)")
        }
    }

    @Test func theTooltipNamesTheRegisteredCombination() {
        let said = MenuBarItem.description(ofShortcut: "⌃⌥D")
        #expect(said.contains("⌃⌥D"), "the tooltip does not name the combination: \(said)")
    }

    /// **Nothing registered is said, not left out.** An icon that answers with the same sentence
    /// either way is not a witness: the `shortcut` stage would read a combination back after the
    /// settings field had taken the hot key away and never put it back.
    @Test func theTooltipSaysWhenNothingIsRegistered() {
        let said = MenuBarItem.description(ofShortcut: nil)
        #expect(!said.isEmpty)
        #expect(said != MenuBarItem.description(ofShortcut: "⌃⌥D"),
                "the tooltip reads the same whether or not a shortcut is registered")
    }

    // MARK: - That the harness can still read it

    /// The `sed` the `shortcut` stage reads the combination with, translated from a basic regular
    /// expression: `\(` and `\)` are a capture there and a literal here, and the other way round.
    private func stagesPattern() throws -> NSRegularExpression {
        let script = try String(
            contentsOf: Self.repository.appending(path: "Tools/e2e.sh"), encoding: .utf8)
        let sed = #"s/.*press \(.*\) to look up.*/\1/p"#
        // **Both reads, not one.** The stage asks before the settings field is used and again
        // after, and a change that updated only the first would compare a combination against an
        // empty string and fail the app for it.
        let reads = script.components(separatedBy: sed).count - 1
        #expect(reads == 2, """
            the shortcut stage reads the icon's tooltip \(reads) time(s) with the pattern this \
            test knows; it was two, and a third spelling is one this test cannot see
            """)
        return try NSRegularExpression(
            pattern: sed
                .replacingOccurrences(of: "s/", with: "")
                .replacingOccurrences(of: #"/\1/p"#, with: "")
                .replacingOccurrences(of: #"\("#, with: "(")
                .replacingOccurrences(of: #"\)"#, with: ")"))
    }

    @Test func theStageReadsTheCombinationBackOutOfTheTooltip() throws {
        let pattern = try stagesPattern()
        let said = MenuBarItem.description(ofShortcut: "⌃⌥D")
        let match = try #require(
            pattern.firstMatch(in: said, range: NSRange(said.startIndex..., in: said)),
            "the shortcut stage cannot read the tooltip it parses: \(said)")
        let captured = try #require(Range(match.range(at: 1), in: said))
        #expect(String(said[captured]) == "⌃⌥D",
                "the stage reads '\(said[captured])' where the combination is ⌃⌥D")
    }

    /// And reads **nothing** when nothing is registered, which is the half that makes the stage's
    /// final claim fail loudly rather than compare two empty strings and pass.
    @Test func theStageReadsNoCombinationWhenNoneIsRegistered() throws {
        let pattern = try stagesPattern()
        let said = MenuBarItem.description(ofShortcut: nil)
        #expect(pattern.firstMatch(in: said, range: NSRange(said.startIndex..., in: said)) == nil,
                "the stage reads a combination out of a tooltip that names none: \(said)")
    }

    // MARK: - One door to the one window

    /// **Review is a pane of the Library, so the menu offers the window once.** "Review…" and
    /// "Library…" were two items for one window — and the window reopens on the pane the reader
    /// last used, so a second item bought nothing but a line to read past.
    @Test func theMenuOffersTheLibraryOnce() throws {
        let item = try String(
            contentsOf: Self.repository.appending(path: "Sources/XiaolaiDict/MenuBarItem.swift"),
            encoding: .utf8)
        #expect(!item.contains("\"Review…\""), "the menu still has a second door into the Library")
        #expect(item.components(separatedBy: "localized: \"Library\"").count - 1 == 1)
        // **No ellipsis**: the item opens a window and asks for nothing more (audit M7).
        #expect(!item.contains("\"Library…\""), "Library carries an ellipsis it has not earned")
    }

    // MARK: - That it is kept current

    /// **Written on every change, not once at launch.** Standing the hot key down for the settings
    /// field and putting it back is the thing the witness exists to catch, so a tooltip assigned in
    /// `install()` alone would go on naming a shortcut that had stopped working. Source-scanned
    /// because AppKit offers no way to ask a button who last wrote its tooltip.
    @Test func theTooltipIsObservedRatherThanWrittenOnce() throws {
        let item = try String(
            contentsOf: Self.repository.appending(path: "Sources/XiaolaiDict/MenuBarItem.swift"),
            encoding: .utf8)
        let code = item.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("withObservationTracking"),
                "the tooltip is written without observing what it names")
        #expect(code.contains("describeTheIcon()"), "nothing writes the tooltip")
    }
}
