import Foundation
import SwiftUI
import Testing
@testable import XiaolaiDictUI

/// Every button in the Library is its icon, and says what it does when pointed at.
///
/// Read from the source: a tooltip and a label style are not things `ImageRenderer` draws, and the
/// claim is about every button, which only a count can hold.
struct IconButtonTests {
    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Sources/XiaolaiDictUI/\(name)"),
            encoding: .utf8)
    }

    /// **The name is never dropped, only moved**: the tooltip, and the label Accessibility reads.
    @Test func anIconButtonKeepsItsNameAsTooltipAndLabel() throws {
        let button = try source("IconButton.swift")
        #expect(button.contains(".help(tooltip)"))
        #expect(button.contains("Label { name } icon: { Image(systemName: symbol) }"),
                "without a label the icon has no name for VoiceOver")
        #expect(button.contains(".labelStyle(.iconOnly)"))
        // A hint is said after the name, never instead of it.
        #expect(button.contains("Text(\"\\(namedWithShortcut) — \\(hint)\")"))
    }

    /// **The key is in the tooltip, after the name, and it is the key the button answers to** —
    /// one value both binds and names it.
    @Test func theShortcutIsNamedInTheTooltipAndBoundFromTheSameValue() throws {
        let button = try source("IconButton.swift")
        #expect(button.contains("Text(\"\\(name) (\\(Text(verbatim: ShortcutLabel.text(for: shortcut))))\")"))
        #expect(button.components(separatedBy: ".keyboardShortcut(shortcut)").count - 1 == 2,
                "bound as an icon and as a menu row")
    }

    @MainActor private final class Pressed { var values: [Int] = [] }

    /// **A shortcut runs the action of the button's latest render**, as an icon and as a menu row (WI-8
    /// follow-up, ADR-0048). SwiftUI keeps a shortcut's action from when it registered the shortcut, and
    /// registers it again only when the button changes — its label, its enabled state — never for a new
    /// closure: measured on macOS 27, a button whose closure alone changed ran its *first* closure for
    /// every key after. A review card drawn over the last one is exactly that button, and the Library's
    /// Review Selected over a new selection of the same size another. Pressed through the window, because
    /// calling the closure from here would ask the question this answers wrongly.
    @MainActor @Test(arguments: [false, true])
    func aShortcutRunsTheActionOfTheLatestRender(asMenuRow: Bool) throws {
        let pressed = Pressed()
        func button(_ value: Int) -> AnyView {
            AnyView(IconButton(.remembered, shortcut: KeyboardShortcut("2", modifiers: [])) { pressed.values.append(value) }
                .environment(\.iconButtonShowsTitle, asMenuRow))
        }
        let keys = KeyboardHarness { _ in button(1) }
        defer { keys.close() }
        try keys.press(.two)
        // **The positive control**: the key reaches the button at all.
        #expect(pressed.values == [1], "the key pressed nothing: \(pressed.values)")
        for value in 2...3 {
            keys.show { _ in button(value) }
            try keys.press(.two)
        }
        #expect(pressed.values == [1, 2, 3], "a re-rendered button ran an action from an earlier render: \(pressed.values)")
    }

    /// **VoiceOver hears the name once.** `.help` is also the element's `AXHelp`, read after the
    /// name — measured from a second process: `.help("Say it aloud")` on a button labelled *Say it
    /// aloud* gave `AXHelp = "Say it aloud"`, and `.accessibilityHint(Text(""))` after it gave an
    /// empty one. So the hint is set after the tooltip, and holds only what the tooltip adds.
    @Test func theSpokenHintIsSetAfterTheTooltipAndNeverRepeatsTheName() throws {
        let button = try source("IconButton.swift")
        let help = try #require(button.range(of: ".help(tooltip)"))
        let hint = try #require(button.range(of: ".accessibilityHint(spokenHint)"))
        #expect(help.upperBound <= hint.lowerBound, "the hint has to come after `.help`, or `.help` wins")
        #expect(button.contains("private var spokenHint: Text { help ?? hint ?? Text(verbatim: \"\") }"))
    }

    /// A destructive control is red — `.plain` draws no role — it shows an edge when the reader
    /// asked for edges, and the 28 pt floor is still there.
    @Test func aDestructiveIconIsTintedAndEveryIconCanShowAnEdge() throws {
        let button = try source("IconButton.swift")
        #expect(button.contains("guard role == .destructive, isEnabled else { return nil }"))
        #expect(button.contains("StatusPalette.destructive.color(in: scheme, contrast: contrast)"))
        #expect(button.contains(".modifier(Tinted(tint: tint))"))
        #expect(button.contains(".showBordersEdge()"))
        #expect(button.contains(".frame(minWidth: Token.Target.minimum, minHeight: Token.Target.minimum)"))
        #expect(try source("AccessibilityAdaptation.swift").contains("@Environment(\\.accessibilityShowBorders)"))
    }

    /// **Every way in stores the action's parts, and the defaults for what it was not given** (audit
    /// 2026-10-08). The three initialisers store through one, so the one taking a `LocalizedStringResource` —
    /// the name `StudyPresentation` hands over — cannot drift from the `LocalizedStringKey` one beside it.
    @MainActor @Test func everyWayInStoresTheSameParts() {
        let key = KeyboardShortcut("z", modifiers: .command)
        let keyed = IconButton(.deletePermanently, title: "Delete", shortcut: key, size: 11) {}
        let resourced = IconButton(.deletePermanently, title: LocalizedStringResource("Delete"), shortcut: key, size: 11) {}
        for button in [keyed, resourced] {
            #expect(button.symbol == ActionSymbol.deletePermanently.symbol)
            // Destructive, so a way in that dropped the action's role would be seen here.
            #expect(button.role == .destructive)
            #expect(button.shortcut == key)
            #expect(button.size == 11)
            #expect(button.help == nil)
            #expect(button.hint == nil)
            #expect(button.isEnabled)
        }
        let named = IconButton(title: "Copy", symbol: ActionSymbol.copy.symbol, hint: "Copies it", role: .destructive,
                               isEnabled: false) {}
        #expect(named.symbol == ActionSymbol.copy.symbol)
        #expect(named.role == .destructive)
        #expect(named.hint != nil)
        #expect(named.help == nil)
        #expect(named.shortcut == nil)
        #expect(named.size == nil)
        #expect(!named.isEnabled)
    }

    /// Outside a menu it is an icon and nothing else: no worded mode was added.
    @Test func thereIsNoTitleAndIconModeOutsideAMenu() throws {
        let button = try source("IconButton.swift")
        #expect(!button.contains(".titleAndIcon"))
    }

    /// A worded `Button("…")` survives only where an icon alone cannot be read: Cancel in a
    /// confirmation dialog, and the one next step an empty state offers. The counts are those, per
    /// file — a new worded button anywhere else moves a count and fails here.
    ///
    /// **Changed 2026-10-02.** The counts were 2 and 4: the erase dialog's action and Cancel, and
    /// the Saved row's four hand-written menu rows. The menu is now the toolbar's own builder, so
    /// its rows are `IconButton`s drawn with their titles; each dialog's destructive button takes
    /// its title from `ActionSymbol` and so is not a `Button("…")` either. Review gained one — the
    /// empty state's "Show in Saved", the remedy its sentence used to name and not offer. And
    /// every icon button is built from an `ActionSymbol` case, so `IconButton(title:` — which
    /// this used to require — is now what must not appear.
    @Test(arguments: [
        ("LearningLibraryView.swift", 1),  // Cancel, in the permanent-delete dialog
        ("LibraryView.swift", 1),          // Cancel, in the Saved removals' dialog
        ("ReviewView.swift", 1),           // "Show in Saved", in the empty state
        ("LibraryReviewPane.swift", 0),
    ])
    func wordedButtonsAreOnlyInMenusAndDialogs(file: String, worded: Int) throws {
        let text = try source(file)
        #expect(text.components(separatedBy: " Button(\"").count - 1 == worded)
        #expect(text.contains("IconButton(."))
        #expect(!text.contains("IconButton(title: "))
        #expect(!text.contains("Button(undoable.name)"))
    }

    /// **The Review grades are icons, with thumbs and their keys.** The key is passed as
    /// `shortcut:`, which binds it and names it in the tooltip; a separate `.keyboardShortcut`
    /// beside it would bind the key twice.
    @Test func theReviewGradesNameTheirKeys() throws {
        let review = try source("ReviewView.swift")
        #expect(review.contains("IconButton(.forgot, shortcut: KeyboardShortcut(\"1\", modifiers: [])"))
        #expect(review.contains("IconButton(.remembered, hint: "))
        #expect(review.contains("shortcut: KeyboardShortcut(\"2\", modifiers: [])"))
        #expect(review.contains("shortcut: KeyboardShortcut(\"s\", modifiers: [])"))
        #expect(review.contains("shortcut: KeyboardShortcut(\"t\", modifiers: [])"))
        #expect(review.contains("IconButton(.showMeaning, shortcut: KeyboardShortcut(.space, modifiers: [])"))
        // **The answers are the size of the question.** They are what the surface is for, and
        // were drawn at the size of a card's incidental actions — four small grey glyphs in a
        // corner (E2E Mac, 2026-10-02). Still icons, as the reader asked: larger, and the two
        // verdicts on memory set apart from the two that only move the card.
        for answer in ["showMeaning", "forgot", "remembered"] {
            let call = try #require(review.range(of: "IconButton(.\(answer),"))
            let line = review[call.lowerBound...].prefix(260)
            #expect(line.contains("size: scale.text.strong"), "\(answer) is drawn at an incidental action's size")
        }
        let grades = try #require(review.range(of: "IconButton(.remembered,"))
        let deferrals = try #require(review.range(of: "IconButton(.skip,"))
        #expect(review[grades.upperBound..<deferrals.lowerBound].contains("Divider()"),
                "nothing separates a verdict on memory from putting the card off")
        #expect(!review.contains(".keyboardShortcut("), "a key is bound outside the button that names it")
    }

    /// **A menu shows the words.** The disposition actions are one builder for the toolbar and the
    /// right-click menu, so the same buttons have to read as icons in one and as rows in the other.
    @Test func aRightClickMenuShowsTitles() throws {
        #expect(try source("LibraryCollection.swift").contains(".environment(\\.iconButtonShowsTitle, true)"))
    }
}
