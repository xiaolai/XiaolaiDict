import XiaolaiDictCore
import SwiftUI

/// The reader's own sentence with the looked-up word picked out.
///
/// **One implementation, because there were two and they had already drifted.** The history card
/// honoured the reader's emphasis setting and coloured the word with its own accent; the lookup
/// card hardcoded semibold in `.primary` and ignored the setting altogether. Same word, same
/// sentence, two surfaces, two answers — and a preference that worked in one place and silently
/// did nothing in the other.
///
/// Which ranges to mark still belongs to the caller: the history card has them from the ledger
/// (`ReadingEntry.markedRanges`, grown from the captured range), and the lookup card works them
/// out from the term. What they must not each decide is how a marked word *looks*.
enum MarkedSentence {
    static func text(
        _ sentence: String, marking ranges: [NSRange], size: CGFloat,
        emphasis: WordEmphasis, accent: Color
    ) -> AttributedString {
        var text = AttributedString(sentence)
        var font = Font.system(size: size, weight: emphasis.weight)
        if emphasis.isItalic { font = font.italic() }
        for range in ranges {
            guard let swift = Range(range, in: sentence),
                  let marked = Range(swift, in: text) else { continue }
            text[marked].font = font
            text[marked].foregroundColor = accent
        }
        return text
    }
}
