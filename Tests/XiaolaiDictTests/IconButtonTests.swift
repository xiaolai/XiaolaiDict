import Foundation
import Testing

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
        #expect(button.contains("Label(title, systemImage: symbol)"), "without a label the icon has no name for VoiceOver")
        #expect(button.contains(".labelStyle(.iconOnly)"))
        // A hint is said after the name, never instead of it.
        #expect(button.contains("Text(\"\\(Text(title)) — \\(Text(hint))\")"))
    }

    /// A worded `Button("…")` survives only where an icon alone cannot be read: the rows of a
    /// right-click menu and the buttons of a confirmation dialog. The counts are those, per file —
    /// a new worded button anywhere else moves a count and fails here.
    @Test(arguments: [
        ("LearningLibraryView.swift", 2),  // the permanent-delete dialog: its action, and Cancel
        ("LibraryView.swift", 4),          // the Saved row's right-click menu
        ("ReviewView.swift", 0),
        ("LibraryReviewPane.swift", 0),
    ])
    func wordedButtonsAreOnlyInMenusAndDialogs(file: String, worded: Int) throws {
        let text = try source(file)
        #expect(text.components(separatedBy: " Button(\"").count - 1 == worded)
        #expect(text.contains("IconButton(title: "))
        #expect(!text.contains("Button(undoable.name)"))
    }

    /// **A menu shows the words.** The disposition actions are one builder for the footer and the
    /// right-click menu, so the same buttons have to read as icons in one and as rows in the other.
    @Test func aRightClickMenuShowsTitles() throws {
        #expect(try source("LibraryCollection.swift").contains(".environment(\\.iconButtonShowsTitle, true)"))
    }
}
