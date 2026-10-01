import AppKit
import SwiftUI

/// How many columns the grid has and how wide a card in one is — decided by the width the grid is
/// given, never chosen. Resizing the window, opening the inspector and changing the text size all
/// move that width, so a count the reader picked would be one the window could not always hold.
struct LibraryGridMetrics {
    let columns: Int
    let cardWidth: CGFloat
    /// `single` is list layout: one column the width of the pane, whatever would fit.
    init(availableWidth: CGFloat, scale: Scale, single: Bool = false) {
        let width = max(0, availableWidth - scale.space.padAcross - scale.space.padAcross)
        let fitting = Int((width + scale.space.stack) / (scale.space.cardMinWidth + scale.space.stack))
        columns = single ? 1 : min(Token.Library.maxColumns, max(1, fitting))
        cardWidth = max(0, (width - CGFloat(columns - 1) * scale.space.stack) / CGFloat(columns))
    }

    /// The rows as columns, dealt in turn: the first to the first column, the next to the second,
    /// and round again.
    ///
    /// **In turn, not to whichever column is shortest.** The shortest-column rule packs tighter, but
    /// it puts a card wherever the heights before it happened to leave room — so newest-to-oldest
    /// stops reading across, and the arrow keys stop meaning anything. Dealt in turn, `index + 1` is
    /// the card beside and `index + columns` the card below, which is the rule
    /// `LibraryCollectionInteraction.move` already keeps.
    func dealt<Row>(_ rows: [Row]) -> [[Row]] {
        var dealt = Array(repeating: [Row](), count: columns)
        for (index, row) in rows.enumerated() { dealt[index % columns].append(row) }
        return dealt
    }
}

enum LibraryNavigation { case left, right, up, down }

/// Session state lives above the lazy rows and both layout branches.
struct LibraryCollectionInteraction<ID: Hashable & Sendable> {
    var focused: ID?
    var anchor: ID?
    var viewed: ID?
    var revealed: Set<ID> = []

    mutating func click(_ id: ID, ordered: [ID], selection: Set<ID>, command: Bool, shift: Bool) -> Set<ID> {
        guard ordered.contains(id) else { return selection }
        focused = id; viewed = id
        if shift, let anchor, let start = ordered.firstIndex(of: anchor), let end = ordered.firstIndex(of: id) {
            let range = Set(ordered[min(start, end)...max(start, end)])
            return command ? selection.union(range) : range
        }
        anchor = id
        if command {
            var next = selection
            if !next.insert(id).inserted { next.remove(id) }
            return next
        }
        return [id]
    }

    mutating func move(_ direction: LibraryNavigation, ordered: [ID], selection: Set<ID>, columns: Int, extend: Bool) -> Set<ID> {
        guard !ordered.isEmpty else { return selection }
        guard let focused, let index = ordered.firstIndex(of: focused) else {
            return click(ordered[0], ordered: ordered, selection: selection, command: false, shift: false)
        }
        let distance: Int
        switch direction { case .left: distance = -1; case .right: distance = 1
        case .up: distance = -max(1, columns); case .down: distance = max(1, columns) }
        let target = ordered[max(0, min(ordered.count - 1, index + distance))]
        return click(target, ordered: ordered, selection: selection, command: false, shift: extend)
    }
}

struct LibraryCollection<Row: Identifiable, Content: View, Menu: View>: View where Row.ID: Hashable & Sendable {
    @Environment(\.scale) private var scale
    let rows: [Row]
    let layout: LibraryLayout
    let identifier: String
    @Binding var selection: Set<Row.ID>
    @Binding var interaction: LibraryCollectionInteraction<Row.ID>
    @ViewBuilder let row: (Row) -> Content
    @ViewBuilder let menu: (Row) -> Menu
    @FocusState private var hasFocus: Bool

    var body: some View {
        GeometryReader { geometry in
            // **One arrangement, with list layout as its one-column case.** A `List` was the other
            // branch, and it brought the system's own selection with it: a slab of accent colour
            // behind the row and the row's text turned white, over a card that is white — and the
            // pane's own selection running on the same click. One code path has one selection.
            let metrics = LibraryGridMetrics(availableWidth: geometry.size.width, scale: scale, single: layout == .list)
            ScrollViewReader { proxy in
                ScrollView {
                    // **Columns that each pack from the top, not rows.** A `LazyVGrid` gives a row the
                    // height of its tallest card and centres the rest in it, so a card with no
                    // sentence sat lower than its neighbour. Each column here is its own lazy stack,
                    // and a short card simply ends sooner.
                    HStack(alignment: .top, spacing: scale.space.stack) {
                        ForEach(Array(metrics.dealt(rows).enumerated()), id: \.offset) { _, column in
                            LazyVStack(spacing: scale.space.stack) {
                                ForEach(column) { item in cell(item) }
                            }
                            .frame(width: metrics.cardWidth)
                        }
                    }
                    .padding(.horizontal, scale.space.padAcross)
                    .padding(.vertical, scale.space.padDown)
                }
                .focusable().focused($hasFocus)
                // The selected card's border says where the keyboard is; the system's ring round the
                // whole column — a rectangle the height of the window — says it again, worse.
                .focusEffectDisabled()
                .onKeyPress(.leftArrow, phases: .down) { navigate(.left, columns: metrics.columns, modifiers: $0.modifiers) }
                .onKeyPress(.rightArrow, phases: .down) { navigate(.right, columns: metrics.columns, modifiers: $0.modifiers) }
                .onKeyPress(.upArrow, phases: .down) { navigate(.up, columns: metrics.columns, modifiers: $0.modifiers) }
                .onKeyPress(.downArrow, phases: .down) { navigate(.down, columns: metrics.columns, modifiers: $0.modifiers) }
                .onAppear { if let id = interaction.viewed { proxy.scrollTo(id) } }
                .onChange(of: layout) { _, _ in if let id = interaction.viewed { proxy.scrollTo(id) } }
                .onChange(of: interaction.focused) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
    }

    private func cell(_ item: Row) -> some View {
        row(item)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                if selection.contains(item.id) {
                    RoundedRectangle(cornerRadius: scale.radius.card).strokeBorder(Color.accentColor, lineWidth: Token.Stroke.selection)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                hasFocus = true
                let flags = NSEvent.modifierFlags
                selection = interaction.click(item.id, ordered: rows.map(\.id), selection: selection,
                                              command: flags.contains(.command), shift: flags.contains(.shift))
            }
            // A menu is read, so the actions it shares with the footer show their words here.
            .contextMenu { menu(item).environment(\.iconButtonShowsTitle, true) }
            .id(item.id)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(identifier)-\(item.id)")
            .accessibilityAddTraits(selection.contains(item.id) ? .isSelected : [])
            .onGeometryChange(for: Bool.self) { geometry in
                let bounds = geometry.frame(in: .scrollView)
                return bounds.minY <= 0 && bounds.maxY > 0
            } action: { atTop in if atTop { interaction.viewed = item.id } }
    }

    private func navigate(_ direction: LibraryNavigation, columns: Int, modifiers: EventModifiers) -> KeyPress.Result {
        guard hasFocus, !rows.isEmpty else { return .ignored }
        selection = interaction.move(direction, ordered: rows.map(\.id), selection: selection,
                                     columns: columns, extend: modifiers.contains(.shift))
        return .handled
    }
}
