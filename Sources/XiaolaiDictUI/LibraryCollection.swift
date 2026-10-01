import AppKit
import SwiftUI

struct LibraryGridMetrics {
    let columns: Int
    let cardWidth: CGFloat
    init(availableWidth: CGFloat, scale: Scale) {
        let width = max(0, availableWidth - scale.space.padAcross - scale.space.padAcross)
        columns = max(1, Int((width + scale.space.stack) / (scale.space.cardMinWidth + scale.space.stack)))
        cardWidth = max(0, (width - CGFloat(columns - 1) * scale.space.stack) / CGFloat(columns))
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
            let metrics = LibraryGridMetrics(availableWidth: geometry.size.width, scale: scale)
            ScrollViewReader { proxy in
                Group {
                    if layout == .list {
                        List(rows, selection: $selection) { item in
                            cell(item).tag(item.id)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        .listStyle(.inset)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(metrics.cardWidth), spacing: scale.space.stack), count: metrics.columns), spacing: scale.space.stack) {
                                ForEach(rows) { item in cell(item) }
                            }
                            .padding(.horizontal, scale.space.padAcross)
                            .padding(.vertical, scale.space.padDown)
                        }
                    }
                }
                .focusable().focused($hasFocus)
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
            .contextMenu { menu(item) }
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
                                     columns: layout == .list ? 1 : columns, extend: modifiers.contains(.shift))
        return .handled
    }
}
