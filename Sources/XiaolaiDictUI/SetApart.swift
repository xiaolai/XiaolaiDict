import SwiftUI

/// Text set apart from what it is about, by a hairline down its leading edge.
///
/// **One gesture, drawn by two surfaces.** The lookup card sets the reader's own sentence apart
/// from the answer above it; a history card sets a revealed gloss apart from the sentence beside
/// it. Both are saying the same thing about the block they mark — *this is not the same kind of
/// text as the thing above it* — and both were written out in full, identically, which is how two
/// copies of a rule stop matching without anybody deciding that they should.
///
/// The hairline is drawn **in** the padding rather than beside it, so it lands on the block's own
/// leading edge and the text clears it by `space.inline`. Overlaid rather than stroked as a border:
/// a stroke centres on its path and would put half of itself outside the block.
struct SetApart: ViewModifier {
    @Environment(\.scale) private var scale

    func body(content: Content) -> some View {
        content
            .padding(.leading, scale.space.inline)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(Token.Opacity.border))
                    .frame(width: Token.Stroke.hairline)
            }
    }
}

extension View {
    /// Sets this block apart from what it is about — see `SetApart`.
    func setApart() -> some View { modifier(SetApart()) }
}
