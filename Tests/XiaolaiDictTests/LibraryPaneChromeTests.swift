import Foundation
import Testing

/// Every pane of the Library is built on one skeleton, so they look like one window.
///
/// Review was a `ScrollView` at the pane's root, which the system runs under the toolbar and gives
/// glass; History, Discarded and Saved wrapped their scroll view in a padded stack with a status line
/// above and a footer below, so nothing reached the toolbar and it drew as a solid bar — seen
/// 2026-10-02, two panes of one window with two different tops.
///
/// Read from the source, the way `NoMagicValuesTests` reads it: `ImageRenderer` draws a `ScrollView`
/// and glass as one flat tone, so what sits under a toolbar cannot be pixel-tested.
struct LibraryPaneChromeTests {
    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Sources/XiaolaiDictUI/\(name)"),
            encoding: .utf8)
    }

    @Test(arguments: ["LearningLibraryView.swift", "LibraryView.swift"])
    func aCollectionPaneIsBuiltOnTheSharedSkeleton(file: String) throws {
        #expect(try source(file).contains(".modifier(LibraryPaneChrome("),
                "\(file) lays its pane out by hand, so its top will not match the others")
    }

    /// Attached to the safe area rather than stacked beside the collection: a stack with the footer
    /// as a sibling is the shape that pushed the scroll view off the toolbar.
    ///
    /// **The footer is glass controls over the cards, not a bar.** A bar across the bottom was a
    /// band of blank height for a count and two buttons; the cards now scroll visibly beneath, and
    /// the controls are glass so they stay legible over whatever is under them.
    @Test func theSkeletonFloatsItsFooterOverTheCollection() throws {
        let chrome = try source("LibraryPaneChrome.swift")
        #expect(chrome.contains(".safeAreaInset(edge: .top"))
        #expect(chrome.contains(".safeAreaInset(edge: .bottom"))
        // A bar, at either edge, is a band with a hard line where it meets the collection — the
        // hairline under the title bar, seen 2026-10-02 on panes that had no notice to show at all.
        #expect(!chrome.contains(".safeAreaBar("), "a bar draws a band and a line; these float")
    }

    /// **One pill of glass each, and nothing glass inside it.** The footer's count and its icons,
    /// and a notice's words, sit on a single surface that makes them legible over the cards; a
    /// caller that put its own glass label inside would be glass on glass.
    @Test func theFooterAndTheNoticeAreEachOnePillOfGlass() throws {
        let chrome = try source("LibraryPaneChrome.swift")
        #expect(chrome.components(separatedBy: ".modifier(LibraryFooterLabel())").count - 1 == 2)
        #expect(chrome.contains(".glassEffect()"))
        for file in ["LearningLibraryView.swift", "LibraryView.swift", "LibraryReviewPane.swift"] {
            #expect(!(try source(file)).contains("LibraryFooterLabel"), "\(file) puts glass inside the pill")
        }
    }

    /// **What is always true of the pane is in the title bar; the footer holds only what comes and
    /// goes.** The count is the window's subtitle, where macOS puts one, and Export is a toolbar
    /// button, because it acts on the collection and not on a selection — beside the selection's
    /// own buttons it read as one of them.
    @Test(arguments: ["LearningLibraryView.swift", "LibraryView.swift"])
    func aPanesCountIsTheWindowsSubtitle(file: String) throws {
        #expect(try source(file).contains(".navigationSubtitle("))
    }

    @Test func exportIsAToolbarButton() throws {
        let saved = try source("LibraryView.swift")
        let footer = try #require(saved.range(of: "private var footer"))
        let afterFooter = saved[footer.upperBound...]
        let end = afterFooter.range(of: "\n    }\n")?.lowerBound ?? afterFooter.endIndex
        #expect(!afterFooter[..<end].contains("Export…"), "Export is still among the selection's buttons")
        #expect(saved.contains("Label(\"Export…\", systemImage:"))
    }

    /// With nothing selected, nothing to undo and nothing more to show, there is no footer at all —
    /// not an empty strip holding the cards off the bottom of the window.
    @Test(arguments: ["LearningLibraryView.swift", "LibraryView.swift"])
    func aFooterWithNothingInItIsAbsent(file: String) throws {
        #expect(try source(file).contains("LibraryFooter {"))
        #expect(try source(file).contains("if hasFooter"))
    }

    /// **The inspector is a card beside the cards**, on one container for both panes. It was bare
    /// text on the window with an indent of its own and a divider — seen 2026-10-02, the one part of
    /// the pane that looked like a different app.
    @Test(arguments: ["LearningLibraryView.swift", "LibraryView.swift"])
    func aPanesInspectorIsTheSharedCard(file: String) throws {
        let text = try source(file)
        #expect(text.contains("LibraryInspector("))
        // **The system's inspector column, not a second scroll view placed beside the list.** A
        // column of our own left the toolbar's scroll edge effect covering the list and stopping at
        // the inspector — half a bar, seen 2026-10-02. Apple's guidance for a sidebar-and-inspector
        // layout is `inspector(isPresented:content:)` (Adopting Liquid Glass).
        #expect(text.contains(".inspector(isPresented:"))
        #expect(!text.contains(".frame(width: scale.space.libraryInspectorWidth)"),
                "\(file) still lays its inspector out by hand")
        #expect(try source("LibraryPaneChrome.swift").contains(".modifier(ReadingCardChrome("))
    }

    /// **No focus ring around the collection.** The system draws one round whatever takes keyboard
    /// focus — here a rectangle the height of the window round the whole column of cards — and the
    /// selected card already wears a border that says where the keyboard is.
    @Test func theCollectionDrawsNoFocusRing() throws {
        #expect(try source("LibraryCollection.swift").contains(".focusEffectDisabled()"))
    }

    /// **The title names the pane being shown, not the window.** "Library" over every pane said what
    /// the sidebar beside it already said, in the one line that could have said where the reader is.
    /// A window's title names its content — a mailbox in Mail, a folder in Finder, the pane in this
    /// app's own Settings — and the count sits under it as the subtitle.
    @Test func theTitleIsThePaneBeingShown() throws {
        #expect(try source("LearningLibraryView.swift").contains(".navigationTitle(pane.name)"))
        for file in ["LearningLibraryView.swift", "LibraryView.swift"] {
            #expect(!(try source(file)).contains(".navigationTitle(\"Library\")"))
        }
    }

    /// **Review's question is a card, like every other reading in the window.** It was its own
    /// window once and the window was the card; as a pane its content sat bare on the background.
    @Test func reviewDrawsItsQuestionAsACard() throws {
        let review = try source("ReviewView.swift")
        #expect(review.contains(".modifier(ReadingCardChrome("))
        // Edge to edge, as a History card in a list is: a card centred in the pane at a width of
        // its own was the one card in the window that did not line up with the others.
        #expect(!review.contains("cardMaxWidth"))
    }

    /// **Review is a pane like the others, on the same skeleton.** It was wrapped in a stack — a
    /// header above it, a button below — which is the shape that held the other panes' scroll
    /// views off the toolbar, and it put a header no other pane has over the card.
    @Test func reviewIsBuiltOnTheSharedSkeletonToo() throws {
        let pane = try source("LibraryReviewPane.swift")
        #expect(pane.contains(".modifier(LibraryPaneChrome("))
        #expect(pane.contains(".navigationSubtitle("))
        #expect(pane.contains("LibraryFooter {"))
        let scene = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Sources/XiaolaiDict/LibraryModel.swift"),
            encoding: .utf8)
        #expect(scene.contains("LibraryReviewPane("), "the Library still lays Review out by hand")
    }

    /// **And nothing pads the pane around its collection.** The collection pads its own content; a
    /// second padding outside it is what held the scroll view off every edge, the toolbar included.
    @Test func theArchivePaneDoesNotPadItsCollection() throws {
        let view = try source("LearningLibraryView.swift")
        let start = try #require(view.range(of: "private var archiveView: some View"))
        let end = try #require(view.range(of: "private var archiveStatus", range: start.upperBound..<view.endIndex))
        #expect(!view[start.upperBound..<end.lowerBound].contains(".padding(scale.space.padAcross)\n        .modifier(LibrarySearch"))
    }
}
