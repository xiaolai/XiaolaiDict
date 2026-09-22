import XiaolaiDictCore
import SwiftUI

/// The reader's sentence, as much of it as the card's lines hold with the word still in view.
///
/// **Chosen by layout, not by counting.** The card used to cut every sentence a fixed six words
/// before its word. That took "He did not" off a sentence that fitted whole — a learner read the
/// opposite of what was written — and could not promise the word was visible anyway: six long
/// words, an emoji or a line break still pushed it past the last line. So the card offers every
/// window, whole sentence first, and shows the first that fits its lines at its width and in its
/// font — which only layout knows. The last window is held to the line limit and truncates after
/// the word, which is where the word must never be cut from.
struct SentenceWindowText: View {
    @Environment(\.scale) private var scale
    /// Most context first; `SentenceExcerpt.windows(sentence:marks:)` makes them.
    let windows: [SentenceExcerpt]
    /// The sentence as the reader read it, a hover away wherever a window cut its start.
    let fullSentence: String
    /// How a window is set — the marked word picked out, as the card does it.
    let style: (SentenceExcerpt) -> AttributedString

    var body: some View {
        AtMost(height: scale.text.height(ofLines: Token.Limit.wrapLines)) {
            ViewThatFits(in: .vertical) {
                ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                    Text(style(window))
                        .font(.system(size: scale.text.body))
                        .lineSpacing(scale.text.leading)
                        // Every window but the last is measured at its full height, so a window
                        // that runs over the lines is one that does not fit. The last is the
                        // fallback, and is held to the lines instead.
                        .lineLimit(index == windows.count - 1 ? Token.Limit.wrapLines : nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(window.clippedBefore ? Text(fullSentence) : Text(verbatim: ""))
                }
            }
        }
    }
}

/// Proposes at most `height` to what it holds, whatever it was proposed itself.
///
/// `ViewThatFits` shows the first candidate whose height fits the height it is *proposed* — and
/// inside a scroll view, or under `fixedSize`, nothing proposes a height at all, so every candidate
/// fits and the first always wins. That is the sentence shown whole whatever its length: the bug
/// this replaced, back by another road. This turns "no height" into "this much", and reports the
/// size of what was chosen — so nothing is reserved for lines a short sentence does not use.
struct AtMost: Layout {
    let height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(bounded(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: proposal.width ?? bounds.width, height: bounded(proposal).height))
    }

    private func bounded(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width, height: min(proposal.height ?? height, height))
    }
}
