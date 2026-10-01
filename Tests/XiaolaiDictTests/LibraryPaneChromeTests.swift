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

    private func app(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Sources/XiaolaiDict/\(name)"),
            encoding: .utf8)
    }

    /// Every file of the Library window, for the sweeps that hold of all of them.
    static let libraryFiles = ["LearningLibraryView.swift", "LibraryView.swift", "LibraryCollection.swift",
                               "LibraryPaneChrome.swift", "LibraryReviewPane.swift", "ReviewView.swift",
                               "LibrarySearch.swift", "LibraryLayout.swift"]

    @Test(arguments: ["LearningLibraryView.swift", "LibraryView.swift"])
    func aCollectionPaneIsBuiltOnTheSharedSkeleton(file: String) throws {
        #expect(try source(file).contains(".modifier(LibraryPaneChrome("),
                "\(file) lays its pane out by hand, so its top will not match the others")
    }

    /// **Nothing is attached at the bottom, and the notice at the top is a bar.**
    ///
    /// Changed 2026-10-02 with the footer's removal. This asserted a top and a bottom
    /// `safeAreaInset` and *no* `safeAreaBar`: both floated as glass pills. The pill at the bottom
    /// held the only route to Confirm, Pause, Archive, Remove and Delete in the window's far
    /// corner, under the inspector when one was open, as glass in the content layer — so its
    /// contents are toolbar items now and there is no bottom attachment to assert. The notice is
    /// `safeAreaBar`, which is what registers it with the scroll edge effect.
    @Test func theNoticeIsABarAndNothingIsAttachedAtTheBottom() throws {
        let chrome = try source("LibraryPaneChrome.swift")
        #expect(chrome.contains(".safeAreaBar(edge: .top"))
        #expect(!chrome.contains("edge: .bottom"), "something is attached under the collection again")
        #expect(!chrome.contains(".safeAreaInset("), "an inset registers no scroll edge effect")
        // **Only while there is a notice.** An empty bar was measured to draw a hairline under the
        // title bar on a pane with nothing to say, which is why this used to forbid bars outright.
        #expect(chrome.contains("if showsNotice {"))
    }

    /// **No glass in the content layer, and no footer.** Was `theFooterAndTheNoticeAreEachOnePillOf
    /// Glass`, which counted two `LibraryFooterLabel` pills and required `.glassEffect()`: glass is
    /// for the floating navigation layer, which here is the system's toolbar and sidebar.
    @Test(arguments: ["LibraryPaneChrome.swift", "LearningLibraryView.swift", "LibraryView.swift",
                      "LibraryReviewPane.swift", "ReviewView.swift", "LibraryCollection.swift", "LibrarySearch.swift"])
    func noLibraryFileDrawsGlassOrAFooter(file: String) throws {
        let text = try source(file)
        #expect(!text.contains(".glassEffect("), "\(file) draws glass in the content layer")
        #expect(!text.contains(".buttonStyle(.glass"), "\(file) has a glass button in content")
        #expect(!text.contains("LibraryFooter {"), "\(file) still builds the footer pill")
        #expect(!text.contains("LibraryFooterLabel"))
    }

    /// **What is always true of the pane is in the title bar; the footer holds only what comes and
    /// goes.** The count is the window's subtitle, where macOS puts one, and Export is a toolbar
    /// button, because it acts on the collection and not on a selection — beside the selection's
    /// own buttons it read as one of them.
    @Test(arguments: ["LearningLibraryView.swift", "LibraryView.swift"])
    func aPanesCountIsTheWindowsSubtitle(file: String) throws {
        #expect(try source(file).contains(".navigationSubtitle("))
    }

    /// Changed 2026-10-02: there is no footer to be absent from, and the label comes from
    /// `ActionSymbol` rather than a string. What it still holds is that Export is a toolbar item
    /// of its own and not one of the selection's actions.
    @Test func exportIsAToolbarButton() throws {
        let saved = try source("LibraryView.swift")
        let actions = try #require(saved.range(of: "private func selectionActions"))
        let afterActions = saved[actions.upperBound...]
        let end = afterActions.range(of: "\n    }\n")?.lowerBound ?? afterActions.endIndex
        #expect(afterActions[..<end].contains("IconButton(.archive"), "positive control: this is the selection's builder")
        #expect(!afterActions[..<end].contains(".export"), "Export is among the selection's buttons")
        #expect(saved.contains("Button { act(.export) } label: { ActionSymbol.export.label }"))
    }

    /// **The selection's actions and Undo are toolbar items, present only while there is a
    /// selection or something to undo.** Was `aFooterWithNothingInItIsAbsent`, which required
    /// `LibraryFooter {` and `if hasFooter`; the same rule now holds of the toolbar groups, where
    /// "absent" is an optional that is nil.
    @Test(arguments: ["LearningLibraryView.swift", "LibraryView.swift"])
    func theSelectionGroupAndUndoAreToolbarItemsOnlyWhileNeeded(file: String) throws {
        let text = try source(file)
        #expect(text.contains("LibrarySelectionToolbar(count: "))
        #expect(text.contains("LibraryUndoToolbar(title: "))
        #expect(!text.contains("hasFooter"))
        let chrome = try source("LibraryPaneChrome.swift")
        #expect(chrome.contains("if let count {"), "the selection group is there with nothing selected")
        #expect(chrome.contains("if let title {"), "Undo is there with nothing to undo")
        // Words and icons do not share one background.
        #expect(chrome.contains(".sharedBackgroundVisibility(.hidden)"))
    }

    /// **Undo is one visible control on Command-Z in every pane.** History and Saved had an icon
    /// with no key; Review had a key with no icon — a button at zero opacity, hidden from
    /// VoiceOver.
    @Test func undoIsBoundToCommandZAndNeverHidden() throws {
        let chrome = try source("LibraryPaneChrome.swift")
        #expect(chrome.contains("IconButton(.undo, title: title, shortcut: KeyboardShortcut(\"z\", modifiers: .command)"))
        #expect(try source("LibraryReviewPane.swift").contains("LibraryUndoToolbar(title: canUndo ?"))
        let scene = try app("ReviewModel.swift")
        #expect(!scene.contains(".opacity(0)"), "Review still hides its Undo")
        #expect(!scene.contains(".keyboardShortcut(\"z\""), "Command-Z is bound twice")
        #expect(try app("LibraryModel.swift").contains("canUndo: review.canUndo"))
    }

    /// **"Show More" is the last row of the collection**, where a reader who reached the end is
    /// looking; it was an icon among the selection's buttons in the corner pill.
    @Test func showMoreIsTheLastRowOfTheCollection() throws {
        let collection = try source("LibraryCollection.swift")
        let columns = try #require(collection.range(of: "metrics.dealt(rows)"))
        let more = try #require(collection.range(of: "ActionSymbol.showMore.label"))
        #expect(columns.upperBound < more.lowerBound, "the row is drawn before the cards")
        for file in ["LearningLibraryView.swift", "LibraryView.swift"] {
            #expect(!(try source(file)).contains("IconButton(.showMore"), "\(file) still offers it as an icon")
        }
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
        // **Open or closed is the reader's, not the selection's.** The binding was `inspector != nil`,
        // so one click took a column out of the grid and nothing but deselecting gave it back.
        #expect(!text.contains(".inspector(isPresented: Binding(get: { "), "\(file) welds the inspector to the selection")
        #expect(text.contains("LibraryInspectorToolbar(isShown: "), "\(file) has no way to toggle it")
        #expect(text.contains("LibraryInspectorPlaceholder("), "\(file) shows nothing when nothing is selected")
    }

    /// A toolbar toggle on Option-Command-I, a column the reader can resize, and an empty state.
    @Test func theInspectorCanBeToggledAndResized() throws {
        let chrome = try source("LibraryPaneChrome.swift")
        #expect(chrome.contains(".keyboardShortcut(\"i\", modifiers: [.option, .command])"))
        #expect(chrome.contains("ActionSymbol.inspector.label"))
        // The floor is the opening width, so the column has one width until the reader drags it:
        // with a narrower floor it opened at 264 pt or 312 pt depending on the pane visited before.
        #expect(chrome.contains(".inspectorColumnWidth(min: scale.space.libraryInspectorWidth"))
        #expect(!chrome.contains(".inspectorColumnWidth(scale.space.libraryInspectorWidth)"), "one fixed width")
        #expect(try source("LearningLibraryView.swift").contains("Select a reading to see its details"))
    }

    /// **The Saved inspector's histories are in the inspector's own scroll view, one above the
    /// other, the sentence uncut.** Side by side in a 312 pt column they wrapped the date, cut the
    /// sentence to "The / meeti…" and broke the source mid-word; and they had a second scroll view
    /// inside the column's own.
    @Test func theSavedInspectorHasOneScrollViewAndAFullSentence() throws {
        let saved = try source("LibraryView.swift")
        let start = try #require(saved.range(of: "private func inspector(_ inspector:"))
        let end = try #require(saved.range(of: "private var isDraftBlank", range: start.upperBound..<saved.endIndex))
        let inspector = saved[start.upperBound..<end.lowerBound]
        #expect(inspector.contains("timeline(inspector)"), "positive control: this is the inspector")
        #expect(!inspector.contains("ScrollView {"), "a scroll view inside the inspector's own")
        #expect(!inspector.contains("inspectorHistoryHeight"))
        let timeline = try #require(inspector.range(of: "private func timeline"))
        #expect(!inspector[timeline.upperBound...].contains(".lineLimit("), "the reader's sentence is cut short")
        #expect(inspector[timeline.upperBound...].contains("VStack(alignment: .leading, spacing: scale.space.stack)"))
    }

    /// **No focus ring around the collection.** The system draws one round whatever takes keyboard
    /// focus — here a rectangle the height of the window round the whole column of cards — and the
    /// selected card already wears a border that says where the keyboard is.
    @Test func theCollectionDrawsNoFocusRing() throws {
        let collection = try source("LibraryCollection.swift")
        #expect(collection.contains(".focusEffectDisabled()"))
        // **But the card's ring still says whether the keyboard is here.** It was a constant accent
        // stroke: the same in a window at the back, and the same while the search field had the
        // keyboard.
        #expect(collection.contains("SelectionAppearance.ring(appearsActive: appearsActive && hasFocus)"))
        #expect(!collection.contains("strokeBorder(Color.accentColor"))
    }

    /// A card is a control: VoiceOver can select it, and the keys beyond the arrows are handled.
    @Test func aCardCanBeSelectedWithoutAPointer() throws {
        let collection = try source("LibraryCollection.swift")
        #expect(collection.contains(".accessibilityAction { select(item, command: false, shift: false) }"))
        #expect(collection.contains(".accessibilityAction(named: Text(\"Select\"))"))
        // Never the button trait: a button is a leaf, and the card's own buttons vanished under it.
        #expect(!collection.contains(".isButton"), "a card marked as a button hides the buttons inside it")
        #expect(collection.contains("LibraryCollectionCommand.command(for: press.key, modifiers: press.modifiers)"))
        #expect(collection.contains(".onDeleteCommand {"))
        #expect(collection.contains(".onExitCommand {"))
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
        // Was `LibraryFooter {`: the way to the unconfirmed meanings was a warning triangle in a
        // corner pill on every visit. It is a toolbar item now, and only when there are some.
        #expect(pane.contains("if unconfirmed > 0, !sittingOffersFind {"))
        #expect(pane.contains("IconButton(.findUnconfirmed"))
        #expect(try app("LibraryModel.swift").contains("LibraryReviewPane("), "the Library still lays Review out by hand")
    }

    /// **And nothing pads the pane around its collection.** The collection pads its own content; a
    /// second padding outside it is what held the scroll view off every edge, the toolbar included.
    @Test func theArchivePaneDoesNotPadItsCollection() throws {
        let view = try source("LearningLibraryView.swift")
        let start = try #require(view.range(of: "private var archiveView: some View"))
        let end = try #require(view.range(of: "private var archiveStatus", range: start.upperBound..<view.endIndex))
        #expect(!view[start.upperBound..<end.lowerBound].contains(".padding(scale.space.padAcross)\n        .modifier(LibrarySearch"))
    }

    // MARK: - The system's controls (2026-10-02)

    /// **The sidebar is the system's list with the system's selection.** Its rows were plain
    /// buttons marked current by darker text alone.
    @Test func theSidebarIsAListWithASelection() throws {
        let view = try source("LearningLibraryView.swift")
        #expect(view.contains("List(selection: Binding<Set<LibrarySidebarItem>>("))
        #expect(view.contains(".tag(LibrarySidebarItem.pane(item))"))
        #expect(view.contains("Section(\"Filters\")"))
        #expect(!view.contains(".buttonStyle(.plain)"), "a sidebar row is a button again")
        #expect(!view.contains(".foregroundStyle(pane == item"), "the current row is marked by colour alone")
        #expect(view.contains(".navigationSplitViewColumnWidth(min: Token.Library.sidebarMinWidth, ideal: Token.Library.sidebarWidth"))
        // What the end-to-end harness reaches a pane by.
        #expect(view.contains(".accessibilityIdentifier(\"library-pane-\\(item.rawValue)\")"))
    }

    /// **Search is the system's field, named for its pane, and nothing wipes it.** It was a
    /// magnifier that swapped itself for a `TextField` whose close button cleared the query.
    @Test func searchIsTheSystemsFieldAndIsNeverWiped() throws {
        let search = try source("LibrarySearch.swift")
        #expect(search.contains(".searchable(text: $text, placement: .toolbar, prompt: prompt)"))
        #expect(!search.contains("TextField("))
        #expect(!search.contains("text = \"\""), "something clears the reader's search for them")
        #expect(try source("LearningLibraryView.swift").contains("\"Search Discarded\" : \"Search History\""))
        #expect(try source("LibraryView.swift").contains("prompt: \"Search Saved\""))
        #expect(!(try source("LibraryReviewPane.swift")).contains("LibrarySearch"), "Review has nothing to search")
    }

    /// **List or grid is a segmented control in an item of its own**, each segment with a tooltip
    /// and the identifier the end-to-end harness presses.
    @Test func theLayoutSwitchIsASegmentedPickerOfItsOwn() throws {
        let chrome = try source("LibraryPaneChrome.swift")
        #expect(chrome.contains(".pickerStyle(.segmented)"))
        #expect(chrome.contains(".help(mode.hint)"))
        #expect(chrome.contains(".accessibilityIdentifier(\"library-layout-\\(mode.rawValue)\")"))
        #expect(chrome.contains("ToolbarSpacer(.fixed)"))
        #expect(!chrome.contains(".toggleStyle(.button)"))
    }

    /// **Empty states are the system's, with the pane's own symbol**, and a search that found
    /// nothing names what it looked for. Discarded drew History's clock.
    @Test(arguments: ["LearningLibraryView.swift", "LibraryView.swift"])
    func anEmptyPaneSaysSoInTheSystemsWay(file: String) throws {
        let text = try source(file)
        #expect(text.contains("ContentUnavailableView.search(text: "))
        #expect(text.contains("LibraryEmptyState {"))
        #expect(!text.contains("systemImage: \"clock\""))
    }

    /// **What cannot be taken back asks first**, with Cancel, and the destructive button is the
    /// title's own verb. Saved's two removals ran on one click.
    @Test func irreversibleRemovalsAskFirst() throws {
        let saved = try source("LibraryView.swift")
        #expect(saved.contains(".confirmationDialog(pending?.title"))
        #expect(saved.contains("Button(\"Cancel\", role: .cancel)"))
        let actions = try #require(saved.range(of: "private func selectionActions"))
        let builder = saved[actions.upperBound...]
        let end = builder.range(of: "\n    }\n")?.lowerBound ?? builder.endIndex
        #expect(builder[..<end].contains("pending = PendingRemoval(kind: .removeFromSaved"))
        #expect(builder[..<end].contains("pending = PendingRemoval(kind: .deleteReadings"))
        #expect(!builder[..<end].contains(".removeFromStudy"), "the builder removes without asking")
        #expect(!builder[..<end].contains("(.deleteReading,"), "the builder deletes without asking")
        let archive = try source("LearningLibraryView.swift")
        #expect(archive.contains("Text(ActionSymbol.deletePermanently.title)"))
        #expect(!archive.contains("Permanently delete reading"))
    }

    /// One builder serves the toolbar and the right-click menu, in both collection panes.
    @Test func theMenuAndTheToolbarShareOneBuilder() throws {
        let saved = try source("LibraryView.swift")
        #expect(saved.contains("selectionActions(state.selectionTarget, inToolbar: true)"))
        #expect(saved.contains("selectionActions(state.target(of: row), inToolbar: false)"))
        let archive = try source("LearningLibraryView.swift")
        #expect(archive.contains("dispositionActions(archive.selectedLookupIDs, inToolbar: true)"))
        #expect(archive.contains("dispositionActions(targets(row), inToolbar: false)"))
    }

    // MARK: - The sweeps

    /// **No action's symbol is written as a string**: it comes from `ActionSymbol`, so one action
    /// cannot wear two symbols. And none of the retired colours: orange text, and tertiary for
    /// text that is meant to be read.
    @Test(arguments: libraryFiles)
    func symbolsAndColoursComeFromTheSharedTables(file: String) throws {
        let text = try source(file)
        #expect(!text.contains("systemImage: \""), "\(file) names a symbol by string")
        #expect(!text.contains("symbol: \""), "\(file) names a symbol by string")
        #expect(!text.contains("IconButton(title: "), "\(file) builds an icon button outside ActionSymbol")
        #expect(!text.contains(".foregroundStyle(.orange)"), "\(file) uses orange text for status")
        #expect(!text.contains(".foregroundStyle(.tertiary)"), "\(file) sets readable text in tertiary")
        #expect(!text.contains("accent(for: row.word)"), "\(file) keys a colour by the surface form")
        #expect(!text.contains(".opacity(Token.Opacity.accentBorder)"), "\(file) ignores Increase Contrast on a card edge")
    }

    /// **Every count is inflected.** "Discard 1 readings" and "Permanently delete 1 readings?" were
    /// both on screen. A number followed by a counted noun must sit inside `^[…](inflect: true)`.
    @Test(arguments: libraryFiles)
    func everyCountedNounIsInflected(file: String) throws {
        let text = try source(file)
        let bare = try NSRegularExpression(
            pattern: #"(?<!\^\[)\\\([^()]*(?:\([^()]*\))?[^()]*\) (readings?|cards?|meanings?|days?|places?|reviews?|times?)\b"#,
            options: [.caseInsensitive])
        let found = bare.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        #expect(found.isEmpty, "\(file) counts without inflecting: \(found)")
    }

    /// The positive control for the scan above: it finds the two strings the audit found.
    @Test func theInflectionScanFindsAnUninflectedCount() throws {
        let bare = try NSRegularExpression(
            pattern: #"(?<!\^\[)\\\([^()]*(?:\([^()]*\))?[^()]*\) (readings?|cards?|meanings?|days?|places?|reviews?|times?)\b"#,
            options: [.caseInsensitive])
        func hits(_ text: String) -> Int { bare.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) }
        #expect(hits(#"Text("\(archive.total) reading encounters")"#) == 1)
        #expect(hits(#""Discard \(ids.count) readings""#) == 1)
        #expect(hits(#""Discard ^[\(ids.count) Reading](inflect: true)""#) == 0)
    }

    /// **The dead split-view branch is gone.** `showsSidebar: true` had no caller and still carried
    /// `backgroundExtensionEffect()`, which the window had already decided against.
    @Test func theSavedPaneHasNoSplitViewOfItsOwn() throws {
        let saved = try source("LibraryView.swift")
        #expect(!saved.contains("showsSidebar"))
        #expect(!saved.contains("NavigationSplitView {"))
        #expect(!saved.contains(".backgroundExtensionEffect()"))
    }

    /// **History draws one card per reading, by the drawer's rule and not a second one.**
    @Test func theArchiveFoldsRepeatsWithTheDrawersRule() throws {
        let model = try app("LibraryModel.swift")
        #expect(model.contains("ReadingHistory.days(from: lookups, now: now, calendar: calendar).flatMap(\\.entries)"))
        // Drawn by the card both surfaces share: the count beside the word, and the hour for a
        // reading made today.
        #expect(try source("LearningLibraryView.swift").contains("ReadingCardView(entry: row, density: .library"))
        let card = try source("ReadingCardComponents.swift")
        #expect(card.contains("if entry.times > 1 { timesRead }"))
        #expect(card.contains("ArchiveCardDate.showsTime(entry.at"))
    }
}
