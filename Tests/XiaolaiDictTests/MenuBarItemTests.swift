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
