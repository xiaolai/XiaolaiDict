import SwiftUI

/// **An icon-only control that is named and can be hit.** One component, because these were two
/// properties everybody had to remember and seven of eight call sites did not.
///
/// What it fixes, both measured 2026-09-25:
///
/// - **No accessibility name.** Seven of the eight icon buttons on the lookup card and the history
///   card drew a bare `Image(systemName:)`. `.help()` gives VoiceOver a *hint*, not a name, so the
///   control announced itself as a button and nothing more. `revealButton` alone got it right, with a
///   `Label` + `.labelStyle(.iconOnly)` — which is exactly what this is.
/// - **A target the size of the glyph.** No padding and no `contentShape`, so the clickable region was
///   the symbol's own box: 13 to 19 pt (`NSImage.SymbolConfiguration` at `text.body`, per symbol), six
///   of them 6 pt apart, against macOS's 28 pt default. On a history card the *destructive* trash sat
///   6 pt from open-in-Dictionary at 14 × 16 pt.
///
/// **The floor is a minimum, never a size.** `Token.Target.minimum` does not scale — a reader asking
/// for larger text is not asking for a larger mouse — but the glyph does, so a symbol wider than the
/// floor at `TextSize.large` keeps its own width. `contentShape` is what makes the frame *hittable*
/// rather than merely occupied: without it the padding is transparent to the hit test and the target
/// is the glyph again, which is the failure this component exists to prevent, arrived at one modifier
/// short.
///
/// `title` is a `LocalizedStringKey` and `help` a `Text` on purpose. Both are the shapes the compiler
/// extracts: `Text(someString)` takes the *verbatim* overload, which is how the card's tooltips came
/// to be English in a translated build while the drawer's copies of the same sentences were
/// translated.
struct IconButton: View {
    @Environment(\.scale) private var scale
    let title: LocalizedStringKey
    let symbol: String
    /// Where the tooltip says more than the name does — the voice a word will be spoken in, why a
    /// control is refusing. Nil where the name is the whole story, and then the name is the tooltip,
    /// so a pointer still gets an answer.
    var help: Text?
    /// The type size the glyph is set at. `text.body` on the lookup card, `text.small` on a history
    /// card, which is why it is a parameter rather than a constant here.
    var size: CGFloat?
    var role: ButtonRole?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: size ?? scale.text.body))
                // Both bounds, and the floor is the *minimum* of each: a glyph wider than the floor
                // keeps its width, and one narrower is padded out to it.
                .frame(minWidth: Token.Target.minimum, minHeight: Token.Target.minimum)
                // Without this the padding is transparent to the hit test and the target is the glyph
                // again — the frame would look right and click wrong.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help ?? Text(title))
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Named, and 28 pt whether the glyph is") {
    HStack(spacing: 0) {
        IconButton(title: "Say it aloud", symbol: "speaker.wave.2") {}
        IconButton(title: "Open in Dictionary", symbol: "character.book.closed") {}
        IconButton(title: "Keep this sense as a note", symbol: "pin") {}
        IconButton(title: "Copy the word and this sense", symbol: "doc.on.doc", isEnabled: false) {}
    }
    .foregroundStyle(.secondary)
    .border(.red.opacity(0.3))
    .padding()
}
#endif
