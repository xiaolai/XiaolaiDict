import SwiftUI

/// The skeleton every collection pane of the Library is built on.
///
/// **The collection reaches the pane's edges, and what is said about it is attached to the safe
/// area.** A scroll view that touches the top of the pane is run under the toolbar by the system,
/// which is what gives the toolbar its glass; one held off the edge by a padded stack — a status
/// line above it, a footer below — leaves the toolbar nothing to sit over and it draws as a solid
/// bar. That was the whole difference between Review, which is a scroll view at its root, and the
/// three panes beside it.
///
/// **Nothing is attached at the bottom.** What can be done to a selection, Undo and the count of
/// what is selected are in the window's toolbar, as Finder has them, and the way to the next page
/// is the last row of the collection. They were a pill of glass floating at the bottom-right corner
/// (until 2026-10-02): glass in the content layer, the destructive buttons furthest from the cards
/// they acted on, and — with the inspector open — under the inspector rather than under the list.
///
/// **The notice is a bar, and only while there is one.** `safeAreaBar` is what registers it with
/// the scroll edge effect, so the cards blur out beneath it instead of running through its words.
/// An empty bar was measured to draw a hairline under the title bar on a pane with nothing to say
/// (2026-10-02), so a pane with no notice attaches no bar at all.
struct LibraryPaneChrome<Notice: View>: ViewModifier {
    let showsNotice: Bool
    @ViewBuilder let notice: Notice

    func body(content: Content) -> some View {
        if showsNotice {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .top, spacing: 0) { notice }
        } else {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// What a pane has to say about itself — something wrong, or what kind of pane this is — in a bar
/// at the top of the collection.
///
/// **Plain, not glass.** It is a sentence, not a control: glass is for what floats and is pressed,
/// and the bar it sits in already has the scroll edge effect behind it.
struct LibraryNotice<Content: View>: View {
    @Environment(\.scale) private var scale
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: scale.space.inline) { content }
            .font(.system(size: scale.text.small))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, scale.space.padAcross)
            .padding(.vertical, scale.space.line)
    }
}

/// A pane with nothing in it: one message, centred in the pane.
///
/// **A scroll view all the same.** The toolbar takes its glass from the scroll view beneath it, and
/// a pane that put a bare message there drew a hard line under the toolbar that no pane with cards
/// has — seen on Discarded, 2026-10-01. The message is as tall as the pane, so nothing scrolls
/// until the text is larger than the window.
struct LibraryEmptyState<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

// MARK: - The toolbar

/// List or grid: one segmented control of its own, apart from everything else in the toolbar.
///
/// **The system's control for a choice between views.** It was two toggle buttons sharing one
/// capsule with the search field and Export, the chosen one a solid accent disc, neither with a
/// tooltip.
struct LibraryLayoutToolbar: ToolbarContent {
    let layout: LibraryLayout
    let choose: @MainActor (LibraryLayout) -> Void

    var body: some ToolbarContent {
        ToolbarItem {
            Picker("Layout", selection: Binding(get: { layout }, set: { choose($0) })) {
                ForEach(LibraryLayout.allCases, id: \.self) { mode in
                    mode.action.label
                        .tag(mode)
                        .help(mode.hint)
                        .accessibilityIdentifier("library-layout-\(mode.rawValue)")
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("library-layout")
        }
        ToolbarSpacer(.fixed)
    }
}

/// How much is selected, in the unit each number counts.
///
/// **A card and a reading are not the same count.** A History card stands for every time that
/// reading was looked up, so two cards can be five readings — and "2 selected" beside "Discard 5
/// Readings" reads as a control about to reach further than the selection. Where the two differ
/// both are said; where they are the same number, once.
struct LibrarySelectionCount: Equatable {
    let cards: Int
    let readings: Int

    init(cards: Int, readings: Int? = nil) {
        self.cards = cards
        self.readings = readings ?? cards
    }

    var namesBoth: Bool { cards != readings }

    var text: Text {
        namesBoth
            ? Text("\(cards) Selected, ^[\(readings) Reading](inflect: true)")
            : Text("\(cards) Selected")
    }
}

/// The selection's own part of the toolbar: how many, then what can be done to them. **Present
/// only while something is selected**, the way Finder's are.
struct LibrarySelectionToolbar<Actions: View>: ToolbarContent {
    let count: LibrarySelectionCount?
    @ViewBuilder let actions: Actions

    var body: some ToolbarContent {
        if let count {
            // Words and icons do not share one background: the count is text on the bar, the
            // actions a group of their own.
            ToolbarItem {
                count.text
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("library-selection-count")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItemGroup { actions }
            ToolbarSpacer(.fixed)
        }
    }
}

/// Undo, in every pane, on Command-Z. **Present only while there is something to take back.**
///
/// It was a footer icon with no key in History and Saved, and in Review a button at zero opacity,
/// hidden from VoiceOver, that only Command-Z could reach: the same action with opposite
/// affordances in adjacent panes, and in one of them no way to find it at all.
struct LibraryUndoToolbar: ToolbarContent {
    /// What pressing it takes back, or nil when there is nothing to.
    let title: LocalizedStringKey?
    let undo: @MainActor () -> Void

    var body: some ToolbarContent {
        if let title {
            ToolbarItem {
                IconButton(.undo, title: title, shortcut: KeyboardShortcut("z", modifiers: .command),
                           size: Token.Library.toolbarGlyph) { undo() }
                    .accessibilityIdentifier("library-undo")
            }
            ToolbarSpacer(.fixed)
        }
    }
}

/// Shows and hides the inspector: the trailing-most toolbar button, and Option-Command-I.
struct LibraryInspectorToolbar: ToolbarContent {
    @Binding var isShown: Bool

    var body: some ToolbarContent {
        ToolbarItem {
            Button { isShown.toggle() } label: { ActionSymbol.inspector.label }
                .keyboardShortcut("i", modifiers: [.option, .command])
                .help(isShown ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
                .accessibilityIdentifier("library-inspector-toggle")
        }
    }
}

// MARK: - The inspector

/// What the inspector column holds: a card, like the ones it is about.
///
/// **The same paper, edge and lift as the cards, in the selected word's colour.** It was bare text
/// on the window, indented by a padding of its own — the one part of a pane that did not look like
/// the rest of it.
///
/// **The column itself is the system's**, put there by `inspector(isPresented:content:)` at the call
/// site: this is only what goes in it. A column of our own, placed beside the list in a stack, was a
/// second scroll view the toolbar knew nothing about, so its scroll edge effect covered the list and
/// stopped at the inspector.
///
/// **And it is the only scroll view in the column.** The Saved pane's two histories had a scroll
/// view of their own inside this one, capped at 220 pt: two scrollers on one axis, one inside the
/// other.
struct LibraryInspector<Content: View>: View {
    @Environment(\.scale) private var scale
    @Environment(\.colorSchemeContrast) private var contrast
    /// The word's colour at full strength; the edge is derived from it here.
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: scale.space.tight) { content }
                .padding(scale.space.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(ReadingCardChrome(accent: CardSurface.border(accent: accent, contrast: contrast)))
                .padding(.horizontal, scale.space.padAcross)
                .padding(.vertical, scale.space.padDown)
        }
        .scrollBounceBehavior(.basedOnSize)
        .modifier(LibraryInspectorColumn())
    }
}

/// The inspector with nothing to inspect: no selection, or several.
///
/// **The inspector is the reader's to open and close, so it can be open over nothing.** It used to
/// appear with a selection and leave with it, which took a column out of the grid under the
/// pointer on every click.
struct LibraryInspectorPlaceholder: View {
    let title: Text
    let description: Text?

    var body: some View {
        ContentUnavailableView { title } description: { if let description { description } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(LibraryInspectorColumn())
    }
}

/// The inspector column's width: the reader may drag it wider, up to a ceiling.
///
/// **The floor is the width it opens at.** With a narrower floor the column had two widths and
/// which one it took depended on the route: 264 points at launch, 312 after a visit to Review —
/// measured on the E2E Mac 2026-10-02 — so the grid beside it moved when the pane changed.
struct LibraryInspectorColumn: ViewModifier {
    @Environment(\.scale) private var scale

    func body(content: Content) -> some View {
        content.inspectorColumnWidth(min: scale.space.libraryInspectorWidth,
                                     ideal: scale.space.libraryInspectorWidth,
                                     max: scale.space.libraryInspectorMaxWidth)
    }
}
