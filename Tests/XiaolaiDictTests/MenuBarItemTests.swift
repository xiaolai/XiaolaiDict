import AppKit
import Foundation
import Testing

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
