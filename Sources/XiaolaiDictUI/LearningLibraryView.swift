import CaptureModel
import DictionaryModel
import Foundation
import StudyKit
import SwiftUI

public enum LibraryPane: String, Sendable, CaseIterable {
    case history, saved, review, discarded
    public var name: LocalizedStringKey {
        switch self { case .history: "History"; case .saved: "Saved"; case .review: "Review"; case .discarded: "Discarded" }
    }
    /// The pane's symbol and name in the sidebar, and the symbol of its empty state.
    var action: ActionSymbol {
        switch self { case .history: .historyPane; case .saved: .savedPane; case .review: .reviewPane; case .discarded: .discardedPane }
    }
}
public struct ArchivePresentation: Sendable {
    public let rows: [ReadingEntry]
    public let total: Int
    public let search: String
    public let hasMore: Bool
    public let problem: String?
    public let undoCount: Int
    public let focused: Int?
    public let selection: Set<Int>
    public var inspector: ReadingEntry? {
        guard selection.count == 1 else { return nil }
        return rows.first { selection.contains($0.id) }
    }
    public var selectedLookupIDs: [Int] {
        Array(Set(rows.filter { selection.contains($0.id) }.flatMap(\.lookupIDs))).sorted()
    }
    public init(rows: [ReadingEntry] = [], total: Int = 0, search: String = "", hasMore: Bool = false,
                problem: String? = nil, undoCount: Int = 0, focused: Int? = nil, selection: Set<Int> = []) {
        self.rows = rows; self.total = total; self.search = search; self.hasMore = hasMore
        self.problem = problem; self.undoCount = undoCount; self.focused = focused; self.selection = selection
    }
}
public enum ArchiveAction: Sendable {
    case select(Set<Int>), retry, confirm(UUID), search(String), more, discard([Int]), restore([Int]), undo, keep(Int), clarify(Int), erase([Int])
}

/// One row of the sidebar: a pane, or — under Saved — one of its filters.
enum LibrarySidebarItem: Hashable {
    case pane(LibraryPane)
    case filter(LibraryPresentation.Filter)
}

/// What the sidebar shows as chosen, and what a click on it means.
///
/// **The system's list and the system's selection.** The rows were plain buttons whose only mark of
/// being current was darker text: no highlight, no arrow keys, and nothing at all for a reader who
/// cannot tell two greys apart. A `List(selection:)` has all three.
///
/// **Two rows are current under Saved** — the pane and the filter it is narrowed to — so the
/// selection is a set, and a click is read as *what was added to it*. Clicking a row that is
/// already current adds nothing and changes nothing.
enum LibrarySidebar {
    static func selection(pane: LibraryPane, filter: LibraryPresentation.Filter) -> Set<LibrarySidebarItem> {
        pane == .saved ? [.pane(pane), .filter(filter)] : [.pane(pane)]
    }

    /// The row the reader just chose: the one in `new` that `old` did not have. A pane before a
    /// filter, should a range ever take in both — the filter means nothing until its pane is shown.
    static func chosen(from old: Set<LibrarySidebarItem>, to new: Set<LibrarySidebarItem>) -> LibrarySidebarItem? {
        let added = new.subtracting(old)
        for pane in LibraryPane.allCases where added.contains(.pane(pane)) { return .pane(pane) }
        for filter in LibraryPresentation.Filter.allCases where added.contains(.filter(filter)) { return .filter(filter) }
        return nil
    }
}

/// When a History card says the time rather than the date: for a reading made today, where the
/// date is the same on every card and the hour is what tells them apart.
enum ArchiveCardDate {
    static func showsTime(_ at: Date, now: Date, calendar: Calendar) -> Bool {
        calendar.isDate(at, inSameDayAs: now)
    }
}

/// One navigation and one detail area. Review never competes with a collection inspector.
public struct LearningLibraryView<Review: View>: View {
    @Environment(\.scale) private var scale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let layout: LibraryLayout
    let chooseLayout: @MainActor (LibraryLayout) -> Void
    let inspectorShown: Bool
    let showInspector: @MainActor (Bool) -> Void
    let pane: LibraryPane
    let saved: LibraryPresentation
    let archive: ArchivePresentation
    let choose: @MainActor (LibraryPane) -> Void
    let savedAction: @MainActor (LibraryAction) -> Void
    let archiveAction: @MainActor (ArchiveAction) -> Void
    let review: Review
    @State private var erasePending: [Int] = []
    @State private var historyInteraction = LibraryCollectionInteraction<Int>()
    @State private var discardedInteraction = LibraryCollectionInteraction<Int>()
    @State private var archiveSearch = ""
    /// Bumped on every sidebar click, so the list is asked again what is selected: a click on a
    /// row that is already current changes no state, and the list would otherwise keep showing
    /// only the row that was clicked.
    @State private var sidebarClicks = 0
    private var interaction: Binding<LibraryCollectionInteraction<Int>> {
        pane == .discarded ? $discardedInteraction : $historyInteraction
    }
    private var inspectorBinding: Binding<Bool> {
        Binding(get: { inspectorShown }, set: { showInspector($0) })
    }
    public init(pane: LibraryPane, saved: LibraryPresentation, archive: ArchivePresentation,
                layout: LibraryLayout = .grid, chooseLayout: @escaping @MainActor (LibraryLayout) -> Void = { _ in },
                inspectorShown: Bool = true, showInspector: @escaping @MainActor (Bool) -> Void = { _ in },
                choose: @escaping @MainActor (LibraryPane) -> Void,
                savedAction: @escaping @MainActor (LibraryAction) -> Void,
                archiveAction: @escaping @MainActor (ArchiveAction) -> Void,
                @ViewBuilder review: () -> Review) {
        self.layout = layout; self.chooseLayout = chooseLayout
        self.inspectorShown = inspectorShown; self.showInspector = showInspector
        self.pane = pane; self.saved = saved; self.archive = archive; self.choose = choose
        self.savedAction = savedAction; self.archiveAction = archiveAction; self.review = review()
    }
    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            Group {
                switch pane {
                case .saved:
                    LibraryView(state: saved, layout: layout, chooseLayout: chooseLayout,
                                inspectorShown: inspectorBinding, act: savedAction)
                case .review: review
                case .history, .discarded: archiveView
                }
            }
            // **The toolbar's background is the system's, and nothing here touches it.** Every pane's
            // scroll view runs beneath the toolbar, and the scroll edge effect is what keeps the
            // title legible over the cards passing under it. Hiding the toolbar's background to be
            // rid of its edge took that with it, and the cards ran straight through the title —
            // seen 2026-10-02. Apple's guidance is to remove custom effects from toolbars and split
            // views and let the system decide (Adopting Liquid Glass).
            //
            // `backgroundExtensionEffect` stays gone: it mirrors and blurs the pane's edge into the
            // sidebar, which suits a hero image and smears the top card's colour for a list.
        }
        // The pane, not the window: the sidebar already says this is the Library.
        .navigationTitle(pane.name)
        // **The title asks, and the button is the title's own verb.** The title did not inflect —
        // "1 readings?" — and the button under it named one reading whatever the count.
        .confirmationDialog(Text("Delete ^[\(erasePending.count) reading](inflect: true) permanently?"), isPresented: Binding(
            get: { !erasePending.isEmpty }, set: { if !$0 { erasePending = [] } })) {
                Button(role: .destructive) {
                    archiveAction(.erase(erasePending)); erasePending = []
                } label: { Text(ActionSymbol.deletePermanently.title) }
                Button("Cancel", role: .cancel) { erasePending = [] }
            } message: {
                Text("This cannot be undone. Backup copies this app made are deleted too; copies you made yourself are not touched. Saved meanings stay, but may need a new sentence.")
            }
    }

    /// **Rows the system draws, tints and highlights.** No colour is set here: on macOS 27 a
    /// sidebar's symbols take the accent colour and its current row the highlight and the heavier
    /// weight, and a style of our own would be the one thing in the sidebar that did not follow
    /// the reader's accent setting.
    private var sidebar: some View {
        let shown = LibrarySidebar.selection(pane: pane, filter: saved.filter)
        return List(selection: Binding<Set<LibrarySidebarItem>>(
            get: { _ = sidebarClicks; return shown },
            set: { chosen in
                sidebarClicks += 1
                switch LibrarySidebar.chosen(from: shown, to: chosen) {
                case .pane(let item): choose(item)
                case .filter(let filter): savedAction(.filter(filter))
                case nil: break
                }
            })) {
            Section {
                ForEach(LibraryPane.allCases, id: \.self) { item in
                    item.action.label
                        .tag(LibrarySidebarItem.pane(item))
                        .accessibilityIdentifier("library-pane-\(item.rawValue)")
                }
            }
            if pane == .saved {
                Section("Filters") {
                    ForEach(LibraryPresentation.Filter.allCases, id: \.self) { filter in
                        filter.action.label
                            .tag(LibrarySidebarItem.filter(filter))
                            .accessibilityIdentifier("library-filter-\(filter.rawValue)")
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: Token.Library.sidebarMinWidth, ideal: Token.Library.sidebarWidth,
                                        max: Token.Library.sidebarMaxWidth)
    }

    private var archiveView: some View {
        Group {
            if archive.rows.isEmpty { archiveEmpty } else { archiveCollection }
        }
        // **The reader's to open and close**, with the toolbar button or Option-Command-I, and it
        // stays as they left it. It was welded to the selection: one card selected opened it and
        // took a column out of the grid under the pointer, and nothing could close it but letting
        // go of the card.
        .inspector(isPresented: inspectorBinding) { archiveInspectorColumn }
        .modifier(LibraryPaneChrome(showsNotice: archive.problem != nil || (pane == .discarded && !archive.rows.isEmpty)) { archiveStatus })
        // The count is the window's subtitle, where macOS puts one, rather than a line of its own.
        .navigationSubtitle(Text("^[\(archive.total) reading](inflect: true)"))
        .onChange(of: archive.focused, initial: true) { _, id in
            if let id { interaction.wrappedValue.focused = id; interaction.wrappedValue.viewed = id }
        }
        .modifier(LibrarySearch(text: $archiveSearch, current: archive.search,
                                prompt: pane == .discarded ? "Search Discarded" : "Search History") { archiveAction(.search($0)) })
        .toolbar {
            LibraryLayoutToolbar(layout: layout, choose: chooseLayout)
            LibrarySelectionToolbar(count: archive.selection.isEmpty ? nil
                : LibrarySelectionCount(cards: archive.selection.count, readings: archive.selectedLookupIDs.count)) {
                dispositionActions(archive.selectedLookupIDs, inToolbar: true)
            }
            LibraryUndoToolbar(title: archive.undoCount > 0 ? "Undo Discarding ^[\(archive.undoCount) Reading](inflect: true)" : nil) {
                archiveAction(.undo)
            }
            LibraryInspectorToolbar(isShown: inspectorBinding)
        }
    }

    /// What is wrong, and what this pane is — above the collection, and absent when there is neither.
    @ViewBuilder private var archiveStatus: some View {
        if let problem = archive.problem {
            LibraryNotice {
                // A failure is marked by its symbol as well as by where it is: in orange text alone
                // it differed from the note below only by hue.
                StatusLabel(.error, text: Text(verbatim: problem), prominence: .secondary).textSelection(.enabled)
                IconButton(.retry) { archiveAction(.retry) }
            }
        } else if pane == .discarded, !archive.rows.isEmpty {
            // Over the readings it is about. An empty pane says the same thing in its own words.
            LibraryNotice {
                Text("Discarded readings remain recoverable until you delete them permanently.")
            }
        }
    }

    /// **The pane's own symbol, and a search that found nothing says what it looked for.** Both
    /// panes drew History's clock, and a failed search kept the title of a pane with no readings.
    private var archiveEmpty: some View {
        LibraryEmptyState {
            if !archive.search.isEmpty {
                ContentUnavailableView.search(text: archive.search)
            } else if pane == .discarded {
                ContentUnavailableView {
                    Label("No Discarded Readings", systemImage: pane.action.symbol)
                } description: {
                    Text("Readings you discard appear here and can be restored.")
                }
            } else {
                ContentUnavailableView {
                    Label("No Reading History", systemImage: pane.action.symbol)
                } description: {
                    Text("Words you look up while reading appear here.")
                }
            }
        }
    }

    private var archiveCollection: some View {
        LibraryCollection(rows: archive.rows, layout: layout, identifier: "library-\(pane.rawValue)-row",
            selection: Binding(get: { archive.selection }, set: { archiveAction(.select($0)) }),
            interaction: interaction,
            keys: archiveKeys, more: archiveMore,
            name: { Text(verbatim: $0.surface) }) { row in
                archiveCard(row)
            } menu: { row in
                dispositionActions(targets(row), inToolbar: false)
            }
    }

    private var archiveKeys: LibraryCollectionKeys {
        var keys = LibraryCollectionKeys(toggleInspector: { showInspector(!inspectorShown) })
        // Discarding can be taken back; the Discarded pane's only removal cannot, so the Delete
        // key does nothing there.
        if pane != .discarded { keys.delete = { archiveAction(.discard(archive.selectedLookupIDs)) } }
        return keys
    }

    private var archiveMore: (@MainActor () -> Void)? {
        guard archive.hasMore else { return nil }
        return { archiveAction(.more) }
    }

    /// The counted disposition controls, for exactly `ids`. **One builder for the context menu and the
    /// toolbar's selection group**, so the two cannot come to offer different actions or different
    /// counts. The count is of readings, which is what each action reaches.
    @ViewBuilder private func dispositionActions(_ ids: [Int], inToolbar: Bool) -> some View {
        let size: CGFloat? = inToolbar ? Token.Library.toolbarGlyph : nil
        if pane == .discarded {
            IconButton(.restoreReading, title: "Restore ^[\(ids.count) Reading](inflect: true)", size: size) { archiveAction(.restore(ids)) }
                .accessibilityIdentifier(inToolbar ? "library-selection-restore" : "")
            // An ellipsis, because it asks before it deletes.
            IconButton(.deletePermanently, title: "Delete ^[\(ids.count) Reading](inflect: true) Permanently…", size: size) { erasePending = ids }
        } else {
            IconButton(.discardReading, title: "Discard ^[\(ids.count) Reading](inflect: true)",
                       hint: inToolbar ? "or press Delete" : nil, size: size) { archiveAction(.discard(ids)) }
                .accessibilityIdentifier(inToolbar ? "library-selection-discard" : "")
        }
    }

    /// What a counted control on `row` reaches: the selection when the row is part of it.
    private func targets(_ row: ReadingEntry) -> [Int] {
        archive.selection.contains(row.id) ? archive.selectedLookupIDs : Self.own(row)
    }

    /// The lookups `row` itself stands for. **What a card's own button reaches**: it is labelled with
    /// the word, not a count, so it may not reach a selection behind it — a destructive control
    /// reaches exactly what its label counts (ADR-0035).
    private static func own(_ row: ReadingEntry) -> [Int] { Array(Set(row.lookupIDs)).sorted() }

    private func archiveCard(_ row: ReadingEntry) -> some View {
        // **The same card the Reading History panel draws**, so one reading looks one way. This
        // pane drew its own, and the two disagreed on fourteen points about one record.
        ReadingCardView(entry: row, density: .library, actions: ReadingCardActions(
            discard: pane == .discarded ? nil : { archiveAction(.discard(Self.own(row))) },
            restore: pane == .discarded ? { archiveAction(.restore(Self.own(row))) } : nil,
            save: pane == .history && row.studyNoteID == nil ? { archiveAction(.keep(row.id)) } : nil))
    }

    /// The inspector column: one reading's details, or what to do to see some.
    @ViewBuilder private var archiveInspectorColumn: some View {
        if let row = archive.inspector {
            archiveInspector(row)
        } else if archive.selection.isEmpty {
            LibraryInspectorPlaceholder(title: Text("No Selection"),
                                        description: Text("Select a reading to see its details"))
        } else {
            LibraryInspectorPlaceholder(
                title: LibrarySelectionCount(cards: archive.selection.count, readings: archive.selectedLookupIDs.count).text,
                description: Text("Select one reading to see its details"))
        }
    }

    /// Everything the inspector says about a meaning — dictionary, sense badge and the revealed text —
    /// is read off `row.shown`, one value describing the note "Confirm This Meaning" acts on. Reading
    /// the dictionary off `row.sense` drew an auxiliary tap's name over the saved note's meaning.
    private func archiveInspector(_ row: ReadingEntry) -> some View {
        let shown = row.shown
        // Keyed by the lemma, as every surface is, and a legible grey where nothing was found.
        let accent = ReadingPalette.color(for: row, in: scheme, contrast: contrast)
        let revealed = interaction.wrappedValue.revealed.contains(row.id)
        let meaning = shown.meaning.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        // Laid out as the card beside it is: the word and when, the sentence, the small facts, and a
        // last row of what can be done.
        return LibraryInspector(accent: accent) {
            HStack(spacing: scale.space.inline) {
                Text(verbatim: row.surface).font(.system(size: scale.text.strong, weight: .semibold)).foregroundStyle(accent)
                Spacer(minLength: 0)
                Text(row.at, format: .dateTime.year().month().day().hour().minute())
            }
            if row.cue != .none {
                Text(verbatim: row.sentence).font(.system(size: scale.text.small)).foregroundStyle(.primary).textSelection(.enabled)
            }
            if row.times > 1 { Text("Read ^[\(row.times) time](inflect: true), in this same sentence") }
            if let place = row.place.label ?? row.place.name { Text(verbatim: place) }
            if let sense = shown.sense {
                // The badge names the dictionary too, so it stands in for the name where there is one.
                if let badge = CardBadge(of: shown) { Text(verbatim: badge.text).help(Text(badge.explanation)) }
                else { Text(verbatim: sense.dictionary) }
            }
            if row.result == .notFound { Text("Not found") }
            if row.result == .pending { Text("No dictionary entry was recorded.") }
            if row.cue == .none { Text("No sentence was captured.") }
            if row.cue == .truncatedSentence {
                StatusLabel(.caution, "The sentence may be cut short", size: scale.text.micro, prominence: .secondary)
            }
            if let meaning, revealed {
                Text(verbatim: meaning).font(.system(size: scale.text.small)).foregroundStyle(.primary).textSelection(.enabled)
            } else if meaning == nil {
                Text("No meaning is available for this reading.")
            }
            if pane == .history, row.studyNoteID != nil {
                Label { Text(ActionSymbol.savedState.title) } icon: { ActionSymbol.savedState.image }
            }
            HStack(spacing: scale.space.inline) {
                if meaning != nil, !revealed {
                    IconButton(.showMeaning) { interaction.wrappedValue.revealed.insert(row.id) }
                }
                Spacer(minLength: 0)
                if pane == .history {
                    if row.studyNoteID == nil {
                        IconButton(.saveMeaning) { archiveAction(.keep(row.id)) }
                    }
                    // **Only where confirming changes something**, and only beside the revealed
                    // meaning — which is why a confirmation from here is one that showed the answer
                    // (`LibraryModel`'s cooldown hook). An entry rung carrying the dictionary's text is
                    // `.needsConfirmation` too, and Confirm over it wrote nothing (ADR-0030).
                    if row.studyObstacle == .confirmation, revealed, let note = row.studyNoteID {
                        IconButton(.confirmMeaning) { archiveAction(.confirm(note)) }
                    }
                    IconButton(.chooseMeaning) { archiveAction(.clarify(row.id)) }
                }
            }
        }
        .font(.system(size: scale.text.micro))
        .foregroundStyle(.secondary)
    }

}
