import Foundation
import SwiftUI
import XiaolaiDictCore

public enum LibraryPane: String, Sendable, CaseIterable {
    case history, saved, review, discarded
    public var name: LocalizedStringKey {
        switch self { case .history: "History"; case .saved: "Saved"; case .review: "Review"; case .discarded: "Discarded" }
    }
    var symbol: String {
        switch self { case .history: "clock"; case .saved: "tray.full"; case .review: "rectangle.on.rectangle"; case .discarded: "archivebox" }
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

/// One navigation and one detail area. Review never competes with a collection inspector.
public struct LearningLibraryView<Review: View>: View {
    @Environment(\.scale) private var scale
    let layout: LibraryLayout
    let chooseLayout: @MainActor (LibraryLayout) -> Void
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
    private var interaction: Binding<LibraryCollectionInteraction<Int>> {
        pane == .discarded ? $discardedInteraction : $historyInteraction
    }
    public init(pane: LibraryPane, saved: LibraryPresentation, archive: ArchivePresentation,
                layout: LibraryLayout = .grid, chooseLayout: @escaping @MainActor (LibraryLayout) -> Void = { _ in },
                choose: @escaping @MainActor (LibraryPane) -> Void,
                savedAction: @escaping @MainActor (LibraryAction) -> Void,
                archiveAction: @escaping @MainActor (ArchiveAction) -> Void,
                @ViewBuilder review: () -> Review) {
        self.layout = layout; self.chooseLayout = chooseLayout
        self.pane = pane; self.saved = saved; self.archive = archive; self.choose = choose
        self.savedAction = savedAction; self.archiveAction = archiveAction; self.review = review()
    }
    public var body: some View {
        NavigationSplitView {
            List {
                ForEach(LibraryPane.allCases, id: \.self) { item in
                    Button { choose(item) } label: {
                        Label(item.name, systemImage: item.symbol)
                            .foregroundStyle(pane == item ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library-pane-\(item.rawValue)")
                }
                if pane == .saved {
                    Section("Saved filters") {
                        ForEach(LibraryPresentation.Filter.allCases, id: \.self) { filter in
                            Button { savedAction(.filter(filter)) } label: {
                                Label(filter.name, systemImage: filter.symbol)
                                    .foregroundStyle(saved.filter == filter ? .primary : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(Token.Library.sidebarWidth)
        } detail: {
            Group {
                switch pane {
                case .saved: LibraryView(state: saved, showsSidebar: false, layout: layout, chooseLayout: chooseLayout, act: savedAction)
                case .review: review
                case .history, .discarded: archiveView
                }
            }
            .backgroundExtensionEffect()
        }
        .navigationTitle("Library")
        .confirmationDialog("Permanently delete \(erasePending.count) readings?", isPresented: Binding(
            get: { !erasePending.isEmpty }, set: { if !$0 { erasePending = [] } })) {
                Button("Permanently delete reading", role: .destructive) {
                    archiveAction(.erase(erasePending)); erasePending = []
                }
                Button("Cancel", role: .cancel) { erasePending = [] }
            } message: {
                Text("This cannot be undone. App-managed migration backups will also be removed. Copies you made remain outside this app. Saved targets remain, but may need a new reading cue.")
            }
    }
    private var archiveView: some View {
        VStack(spacing: scale.space.tight) {
            archiveStatus
            HStack(alignment: .top, spacing: 0) {
                if archive.rows.isEmpty { archiveEmpty } else { archiveCollection }
                if let row = archive.inspector {
                    Divider()
                    ScrollView { archiveInspector(row) }
                        .frame(width: scale.space.libraryInspectorWidth)
                }
            }
            if !archive.selection.isEmpty {
                HStack(spacing: scale.space.inline) {
                    Text("\(archive.selection.count) selected")
                    dispositionActions(archive.selectedLookupIDs)
                }
            }
            if archive.hasMore { Button("Show more history") { archiveAction(.more) } }
            Text("\(archive.total) reading encounters")
                .font(.system(size: scale.text.micro)).foregroundStyle(.secondary)
        }
        .onChange(of: archive.focused, initial: true) { _, id in
            if let id { interaction.wrappedValue.focused = id; interaction.wrappedValue.viewed = id }
        }
        .padding(scale.space.padAcross)
        .modifier(LibrarySearch(text: Binding(get: { archive.search }, set: { archiveAction(.search($0)) }), layout: layout, chooseLayout: chooseLayout))
    }

    @ViewBuilder private var archiveStatus: some View {
        if let problem = archive.problem {
            Text(verbatim: problem).foregroundStyle(.orange).textSelection(.enabled)
            Button("Retry") { archiveAction(.retry) }
        }
        if pane == .discarded {
            Text("Discarded readings remain recoverable until you permanently delete them.")
                .font(.system(size: scale.text.small)).foregroundStyle(.secondary)
        }
        if archive.undoCount > 0 {
            Button("Undo discarding \(archive.undoCount) readings") { archiveAction(.undo) }
        }
    }

    private var archiveEmpty: some View {
        ContentUnavailableView {
            Label(pane == .discarded ? "No discarded readings" : "No reading history", systemImage: "clock")
        } description: {
            if !archive.search.isEmpty { Text("No readings match this search.") }
            else if pane == .discarded { Text("Readings you discard appear here and can be restored.") }
            else { Text("Deliberate lookups appear here. Saved meanings become reviewable after confirmation.") }
        }
    }

    private var archiveCollection: some View {
        LibraryCollection(rows: archive.rows, layout: layout, identifier: "library-\(pane.rawValue)-row",
            selection: Binding(get: { archive.selection }, set: { archiveAction(.select($0)) }),
            interaction: interaction) { row in
                archiveCard(row)
            } menu: { row in
                dispositionActions(targets(row))
            }
    }

    /// The counted disposition controls, for exactly `ids`. **One builder for the context menu and the
    /// selection footer**, so the two cannot come to offer different actions or different counts.
    @ViewBuilder private func dispositionActions(_ ids: [Int]) -> some View {
        if pane == .discarded {
            Button("Restore \(ids.count) readings") { archiveAction(.restore(ids)) }
            Button("Permanently delete \(ids.count) readings", role: .destructive) { erasePending = ids }
        } else {
            Button("Discard \(ids.count) readings") { archiveAction(.discard(ids)) }
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
        ArchiveCard(row: row, discarded: pane == .discarded,
                    discard: { archiveAction(.discard(Self.own(row))) },
                    restore: { archiveAction(.restore(Self.own(row))) })
    }

    /// Everything the inspector says about a meaning — dictionary, sense badge and the revealed text —
    /// is read off `row.shown`, one value describing the note "Confirm this meaning" acts on. Reading
    /// the dictionary off `row.sense` drew an auxiliary tap's name over the kept note's meaning.
    private func archiveInspector(_ row: ReadingEntry) -> some View {
        let shown = row.shown
        return VStack(alignment: .leading, spacing: scale.space.stack) {
            Text(verbatim: row.surface).font(.system(size: scale.text.heading, weight: .semibold))
            if row.cue != .none { Text(verbatim: row.sentence).textSelection(.enabled) }
            if let place = row.place.label ?? row.place.name { Text(verbatim: place).foregroundStyle(.secondary) }
            Text(row.at, format: .dateTime.year().month().day().hour().minute())
            if let sense = shown.sense {
                Text(verbatim: sense.dictionary).foregroundStyle(.secondary)
                if let badge = CardBadge(of: shown) { Text(verbatim: badge.text).help(Text(badge.explanation)) }
            }
            if row.result == .notFound { Text("Not found") }
            if row.result == .pending { Text("Dictionary answer unavailable") }
            if row.cue == .none { Text("No sentence was captured.") }
            if row.cue == .truncatedSentence { Text("Context may be cut") }
            if let meaning = shown.meaning, !meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if interaction.wrappedValue.revealed.contains(row.id) {
                    Text(verbatim: meaning).textSelection(.enabled)
                } else {
                    Button("Show the meaning") { interaction.wrappedValue.revealed.insert(row.id) }
                }
            } else { Text("No meaning is available for this reading.") }
            if pane == .history {
                if row.studyNoteID != nil { Text("Kept for learning") }
                else { Button("Keep for learning") { archiveAction(.keep(row.id)) } }
                if row.studyStatus == .needsConfirmation, interaction.wrappedValue.revealed.contains(row.id), let note = row.studyNoteID {
                    Button("Confirm this meaning") { archiveAction(.confirm(note)) }
                }
                Button("Choose a meaning") { archiveAction(.clarify(row.id)) }
            }
        }
        .font(.system(size: scale.text.small)).padding(scale.space.pad)
    }

}


private struct ArchiveCard: View {
    @Environment(\.scale) private var scale
    @Environment(\.colorScheme) private var scheme
    let row: ReadingEntry
    let discarded: Bool
    let discard: () -> Void
    let restore: () -> Void
    private var accent: Color { ReadingPalette.accent(for: row)?.color(in: scheme) ?? ReadingPalette.miss }
    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.tight) {
            HStack(spacing: scale.space.inline) {
                Text(verbatim: row.surface).font(.system(size: scale.text.strong, weight: .semibold)).foregroundStyle(accent)
                Spacer(minLength: 0)
                Text(row.at, format: .dateTime.month().day()).font(.system(size: scale.text.micro)).foregroundStyle(.secondary)
            }
            if row.cue != .none {
                ReadingSentence(sentence: row.sentence, ranges: row.markedRanges, accent: accent,
                                truncated: row.cue == .truncatedSentence)
            }
            if let name = row.place.name { Text(verbatim: name).font(.system(size: scale.text.micro)).foregroundStyle(.secondary).lineLimit(1) }
            if let badge = CardBadge(of: row) { Text(verbatim: badge.text).font(.system(size: scale.text.micro)).foregroundStyle(.secondary) }
            HStack(spacing: scale.space.inline) {
                ReadingPronunciation(word: row.surface, sentence: row.sentence)
                Spacer(minLength: 0)
                if discarded {
                    Button("Restore", action: restore).accessibilityLabel("Restore \(row.surface)").accessibilityIdentifier("restore-reading-\(row.id)")
                } else {
                    Button("Discard", action: discard).accessibilityLabel("Discard \(row.surface)").accessibilityIdentifier("discard-reading-\(row.id)")
                }
            }
            .font(.system(size: scale.text.micro))
        }
        .padding(scale.space.pad)
        .modifier(ReadingCardChrome(accent: accent.opacity(Token.Opacity.accentBorder)))
    }
}
