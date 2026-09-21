import Foundation

/// A window onto the reader's sentence that is guaranteed to show the word.
///
/// The drawer's card holds the sentence to two lines and truncates from the end. On a long
/// sentence with the word late, that showed two lines of the reader's own text **without the word
/// they looked up** — measured on a real row: "ticket" at character 114 of a 248-character
/// sentence, cut at about 100. A card that exists to show a word in its sentence has to start its
/// window near the word, not at the sentence's first character.
///
/// Counted in **words**, not characters. ICU word boundaries give a Chinese sentence the same
/// amount of context as an English one, where a character budget would give it a quarter. The
/// far side is left to the view's line limit, which now truncates *after* the word.
public struct SentenceExcerpt: Equatable, Sendable {
    /// The most context a window cut short keeps before the first marked word: enough that the
    /// word reads as part of a sentence rather than a fragment. Whether it fits is the view's to
    /// measure — see `windows(sentence:marks:)`.
    public static let wordsBefore = 6

    /// The whole sentence, or `…` and the rest of it from a few words before the word.
    public let text: String
    /// The marks, in `text`'s own UTF-16 coordinates — `NSRange`'s, which is why an emoji before
    /// the word is two units and not one.
    public let marks: [NSRange]
    /// Whether the start was cut. The `…` already says so on screen; this says it to code.
    public let clippedBefore: Bool

    public init(sentence: String, marks: [NSRange], wordsBefore: Int = SentenceExcerpt.wordsBefore) {
        precondition(wordsBefore >= 0, "a window cannot keep a negative number of words")
        let whole = sentence as NSString
        guard let first = marks.map(\.location).min(), first > 0, first <= whole.length else {
            self.init(text: sentence, marks: marks, clippedBefore: false)
            return
        }
        // Every mark is at or after the first, and the cut is before the first — so no mark can
        // fall off the front. Each moves by the same amount: back by the cut, on by the ellipsis.
        let cut: Int
        if wordsBefore == 0 {
            // The last resort: the window opens at the word itself, so nothing before it — a word
            // longer than the card is wide, a line break, an emoji — can push it out of view.
            // **Measured in characters here, not words.** Text with no words in it is still text:
            // three line breaks before the word were left in place by a rule that asked how many
            // words there were to cut and found none.
            cut = first
        } else {
            var starts: [Int] = []
            whole.enumerateSubstrings(
                in: NSRange(location: 0, length: first), options: [.byWords, .substringNotRequired]
            ) { _, range, _, _ in starts.append(range.location) }
            guard starts.count > wordsBefore else {
                self.init(text: sentence, marks: marks, clippedBefore: false)
                return
            }
            cut = starts[starts.count - wordsBefore]
        }
        let ellipsis = "…"
        let shift = (ellipsis as NSString).length - cut
        self.init(
            text: ellipsis + whole.substring(from: cut),
            marks: marks.map { NSRange(location: $0.location + shift, length: $0.length) },
            clippedBefore: true)
    }

    /// How much context each tighter window keeps, after the whole sentence and `wordsBefore`.
    /// The last keeps none: it starts at the word, which is the only window nothing can push the
    /// word out of.
    static let fallbacks = [3, 1, 0]

    /// **The windows a card may show, most context first**: the whole sentence, then from
    /// `wordsBefore` words before the word, then fewer — each distinct, each with the word marked.
    ///
    /// The card shows the first that fits its lines, measured there at its width and in its font.
    /// Counting words here could not decide it: cutting every sentence six words before its word
    /// took "He did not" off a sentence that fitted whole — a learner read the opposite of what was
    /// written — and six long words, an emoji or a line break can still push the word past the
    /// last line. Only the view knows how long the words are.
    public static func windows(sentence: String, marks: [NSRange]) -> [SentenceExcerpt] {
        var windows = [SentenceExcerpt(text: sentence, marks: marks, clippedBefore: false)]
        for count in [wordsBefore] + fallbacks {
            let window = SentenceExcerpt(sentence: sentence, marks: marks, wordsBefore: count)
            if window.text != windows.last?.text { windows.append(window) }
        }
        return windows
    }

    private init(text: String, marks: [NSRange], clippedBefore: Bool) {
        self.text = text
        self.marks = marks
        self.clippedBefore = clippedBefore
    }
}
