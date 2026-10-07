import AppKit
import StudyPresentation
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

/// What a key means to a collection, apart from the arrows. **Decided here, as a value**, so the
/// rule is tested without a window: the view only carries the answer out.
enum LibraryCollectionCommand: Equatable {
    case selectAll, deselectAll, toggleInspector, clearSelection, delete

    /// Command-A selects every card and Shift-Command-A lets go of them, as in Finder; Escape lets
    /// go too; Delete puts the selection away; Return shows or hides the inspector. Option and
    /// Control are refused, so a shortcut some other part of the system owns is never taken.
    static func command(for key: KeyEquivalent, modifiers: EventModifiers) -> LibraryCollectionCommand? {
        guard !modifiers.contains(.option), !modifiers.contains(.control) else { return nil }
        let command = modifiers.contains(.command), shift = modifiers.contains(.shift)
        if String(key.character).lowercased() == "a", command { return shift ? .deselectAll : .selectAll }
        guard !command, !shift else { return nil }
        switch key {
        case .escape: return .clearSelection
        case .delete, .deleteForward: return .delete
        case .return: return .toggleInspector
        default: return nil
        }
    }
}

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

    /// Every card on screen. The anchor goes to the first, so a Shift-click afterwards extends
    /// from the top as it does in Finder; where the keyboard is stays where it was.
    mutating func selectAll(ordered: [ID]) -> Set<ID> {
        anchor = ordered.first
        if focused == nil { focused = ordered.first }
        return Set(ordered)
    }

    /// Nothing selected. **Where the keyboard is stays**, so the next arrow key moves from the
    /// card the reader was on rather than jumping back to the first.
    mutating func deselectAll() -> Set<ID> {
        anchor = nil
        return []
    }
}

/// What the keys beyond the arrows do in one pane. The collection knows which key was pressed;
/// only the pane knows what putting a selection away means there.
struct LibraryCollectionKeys {
    /// Delete: discard in History, archive in Saved. **Nil where nothing undoable answers to it** —
    /// Discarded, whose only removal is permanent and asks first.
    var delete: (@MainActor () -> Void)?
    /// Return: show or hide the inspector.
    var toggleInspector: @MainActor () -> Void = {}
}

struct LibraryCollection<Row: Identifiable, Content: View, Menu: View>: View where Row.ID: Hashable & Sendable {
    @Environment(\.scale) private var scale
    @Environment(\.appearsActive) private var appearsActive
    let rows: [Row]
    let layout: LibraryLayout
    let identifier: String
    @Binding var selection: Set<Row.ID>
    @Binding var interaction: LibraryCollectionInteraction<Row.ID>
    var keys = LibraryCollectionKeys()
    /// Asks for the next page. Nil when everything that matched is already here.
    var more: (@MainActor () -> Void)?
    /// What VoiceOver calls a card: the word it is about.
    let name: (Row) -> Text
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
                    VStack(spacing: scale.space.stack) {
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
                        // **The way to the next page is the last thing in the collection**, where a
                        // reader who has read to the end is looking. It was an icon in a pill at
                        // the window's corner, among the selection's buttons. A row is read, so it
                        // carries its words.
                        if let more {
                            Button(action: more) { ActionSymbol.showMore.label }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("\(identifier)-more")
                        }
                    }
                    .padding(.horizontal, scale.space.padAcross)
                    .padding(.vertical, scale.space.padDown)
                }
                .focusable().focused($hasFocus)
                // **Deliberate, and the reader's own objection**: the system's ring goes round
                // whatever takes the keyboard, which here is the whole column — a rectangle the
                // height of the window. Where the keyboard is, is said by the selected card's ring
                // instead: accent while this collection has the keyboard and the window is the
                // one being worked in, grey otherwise (`SelectionAppearance`).
                .focusEffectDisabled()
                .onKeyPress(.leftArrow, phases: .down) { navigate(.left, columns: metrics.columns, modifiers: $0.modifiers) }
                .onKeyPress(.rightArrow, phases: .down) { navigate(.right, columns: metrics.columns, modifiers: $0.modifiers) }
                .onKeyPress(.upArrow, phases: .down) { navigate(.up, columns: metrics.columns, modifiers: $0.modifiers) }
                .onKeyPress(.downArrow, phases: .down) { navigate(.down, columns: metrics.columns, modifiers: $0.modifiers) }
                .onKeyPress(phases: .down) { press in
                    guard let command = LibraryCollectionCommand.command(for: press.key, modifiers: press.modifiers) else { return .ignored }
                    return perform(command)
                }
                // **The same three, as the commands the system sends.** Where the app's Edit menu
                // claims Command-A, or AppKit turns Delete and Escape into `delete:` and
                // `cancelOperation:` before any key press is offered, the key never reaches
                // `onKeyPress` — and a key that is handled there is never sent as a command, so
                // one press cannot act twice.
                .onCommand(#selector(NSResponder.selectAll(_:))) { _ = perform(.selectAll) }
                .onDeleteCommand { _ = perform(.delete) }
                .onExitCommand { _ = perform(.clearSelection) }
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
                    RoundedRectangle(cornerRadius: scale.radius.card)
                        .strokeBorder(SelectionAppearance.ring(appearsActive: appearsActive && hasFocus),
                                      lineWidth: Token.Stroke.selection)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                let flags = NSEvent.modifierFlags
                select(item, command: flags.contains(.command), shift: flags.contains(.shift))
            }
            // A menu is read, so the actions it shares with the toolbar show their words here.
            .contextMenu { menu(item).environment(\.iconButtonShowsTitle, true) }
            .id(item.id)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(name(item))
            .accessibilityIdentifier("\(identifier)-\(item.id)")
            // **A card can be chosen without a pointer.** Selection was a tap gesture and nothing
            // else, so VoiceOver's press landed on the buttons inside a card and never on the
            // card: the inspector and every action on a selection were out of its reach.
            //
            // **By an action, never by the button trait.** A button is a leaf to Accessibility:
            // with that trait here the card's own Discard, Save and Say It Aloud stopped being
            // elements at all, and their identifiers surfaced on the card with the card's frame —
            // measured on the E2E Mac 2026-10-02, where a click on `discard-reading-1` selected
            // the card and discarded nothing. The card stays a container and offers selecting.
            .accessibilityAddTraits(selection.contains(item.id) ? .isSelected : [])
            .accessibilityAction { select(item, command: false, shift: false) }
            .accessibilityAction(named: Text("Select")) { select(item, command: false, shift: false) }
            .onGeometryChange(for: Bool.self) { geometry in
                let bounds = geometry.frame(in: .scrollView)
                return bounds.minY <= 0 && bounds.maxY > 0
            } action: { atTop in if atTop { interaction.viewed = item.id } }
    }

    private func select(_ item: Row, command: Bool, shift: Bool) {
        hasFocus = true
        selection = interaction.click(item.id, ordered: rows.map(\.id), selection: selection,
                                      command: command, shift: shift)
    }

    private func navigate(_ direction: LibraryNavigation, columns: Int, modifiers: EventModifiers) -> KeyPress.Result {
        guard hasFocus, !rows.isEmpty else { return .ignored }
        selection = interaction.move(direction, ordered: rows.map(\.id), selection: selection,
                                     columns: columns, extend: modifiers.contains(.shift))
        return .handled
    }

    /// Carries out what a key meant. **Ignored where it would do nothing**, so Escape with nothing
    /// selected and Delete in a pane that has no undoable removal go on to whoever else wants them.
    private func perform(_ command: LibraryCollectionCommand) -> KeyPress.Result {
        guard hasFocus else { return .ignored }
        switch command {
        case .selectAll:
            guard !rows.isEmpty else { return .ignored }
            selection = interaction.selectAll(ordered: rows.map(\.id))
        case .deselectAll, .clearSelection:
            guard !selection.isEmpty else { return .ignored }
            selection = interaction.deselectAll()
        case .delete:
            guard !selection.isEmpty, let delete = keys.delete else { return .ignored }
            delete()
        case .toggleInspector:
            keys.toggleInspector()
        }
        return .handled
    }
}
