import SwiftUI

/// The skeleton every collection pane of the Library is built on.
///
/// **The collection reaches the pane's edges, and what is said about it is attached as bars.** A
/// scroll view that touches the top of the pane is run under the toolbar by the system, which is
/// what gives the toolbar its glass; one held off the edge by a padded stack — a status line above
/// it, a footer below — leaves the toolbar nothing to sit over and it draws as a solid bar. That was
/// the whole difference between Review, which is a scroll view at its root, and the three panes
/// beside it.
///
/// **Neither the notice nor the footer is a bar.** A bar is a band across the window with a hard
/// line where it meets the collection: at the bottom it was mostly blank height around a count and
/// two buttons, and at the top it drew a hairline under the title bar even on a pane with nothing
/// to say. Both float instead — insets, so the collection can scroll clear of them — with the cards
/// visible beneath: buttons are glass, and text wears `LibraryFooterLabel` so it reads over whatever
/// is under it. A pane with no notice and nothing pending attaches nothing at all.
struct LibraryPaneChrome<Notice: View, Footer: View>: ViewModifier {
    @ViewBuilder let notice: Notice
    @ViewBuilder let footer: Footer

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { notice }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }
}

/// A pane's footer: what can be done right now, floating over the collection.
///
/// **Only what comes and goes.** A selection and its buttons, an undo, more to show. What is always
/// true of the pane — how many it holds, exporting it — is in the title bar, so a pane with nothing
/// pending draws no `LibraryFooter` and the cards run to the bottom of the window.
struct LibraryFooter<Content: View>: View {
    @Environment(\.scale) private var scale
    @ViewBuilder let content: Content

    var body: some View {
        // **One pill of glass, at the trailing corner, as wide as what is in it.** The buttons are
        // icons with no bezel of their own, like the voice on a card, so the pill is what makes
        // them legible over the cards — and one surface, never glass inside glass.
        HStack(spacing: scale.space.inline) { content }
            .modifier(LibraryFooterLabel())
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, scale.space.padAcross)
            .padding(.vertical, scale.space.line)
    }
}

/// What a pane has to say about itself — something wrong, or what kind of pane this is — floating
/// at the top of the collection, on glass for the same reason the footer's text is.
struct LibraryNotice<Content: View>: View {
    @Environment(\.scale) private var scale
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: scale.space.inline) { content }
            .font(.system(size: scale.text.small))
            .foregroundStyle(.secondary)
            .modifier(LibraryFooterLabel())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, scale.space.padAcross)
            .padding(.vertical, scale.space.line)
    }
}

/// A footer's or a notice's text, on glass: bare text over scrolling cards is text nobody can read.
struct LibraryFooterLabel: ViewModifier {
    @Environment(\.scale) private var scale

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, scale.space.inline)
            .padding(.vertical, scale.space.tight)
            .glassEffect()
    }
}

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
struct LibraryInspector<Content: View>: View {
    @Environment(\.scale) private var scale
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: scale.space.tight) { content }
                .padding(scale.space.pad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(ReadingCardChrome(accent: accent.opacity(Token.Opacity.accentBorder)))
                .padding(.horizontal, scale.space.padAcross)
                .padding(.vertical, scale.space.padDown)
        }
        .scrollBounceBehavior(.basedOnSize)
        .inspectorColumnWidth(scale.space.libraryInspectorWidth)
    }
}
