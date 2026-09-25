import Foundation
import NaturalLanguage

/// The sentence found around a selection, and whether it may be only part of one.
public struct SentenceContext: Equatable, Sendable {
    /// Never blank.
    public let text: String
    /// The text searched was a window cut from a longer document, and this sentence runs into the
    /// cut: it may go on past what was read.
    public let mayBeCut: Bool
    /// Where the selection sits in `text`, UTF-16. Nil when that is not known, or the selection is
    /// not wholly inside the sentence.
    public let selection: NSRange?

    /// Nil for blank text — no sentence, rather than an empty one — or for a selection outside it.
    public init?(text: String, mayBeCut: Bool, selection: NSRange? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let selection {
            guard selection.location >= 0, selection.length >= 0,
                  selection.location <= text.utf16.count, selection.length <= text.utf16.count - selection.location
            else { return nil }
        }
        self.text = text
        self.mayBeCut = mayBeCut
        self.selection = selection
    }
}

/// Sentence segmentation for selections. NLTokenizer handles scripts written without spaces
/// (Chinese), which splitting on punctuation and whitespace would not.
///
/// Word-under-the-pointer segmentation (Milestone 2 hover) lives in the screen-word spike until
/// that milestone ports it: product code carries no API without a caller.
/// A word found under a pointer, with the sentence it sits in.
public struct WordAtPoint: Equatable, Sendable {
    public let word: String
    /// The sentence around it, carrying its own `mayBeCut` flag and the word's range within it.
    public let sentence: SentenceContext

    public init(word: String, sentence: SentenceContext) {
        self.word = word
        self.sentence = sentence
    }
}

public enum TextSegmenter {
    /// Which ends of a text are cuts in a longer document rather than the document's own ends.
    public struct Clipping: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let start = Clipping(rawValue: 1 << 0)
        public static let end = Clipping(rawValue: 1 << 1)
    }

    /// The sentence covering a selection — or the run of sentences, when the selection crosses a
    /// boundary. `range` is UTF-16, as Accessibility reports it. When `text` is a window into a
    /// longer document, `clipped` says which of its ends are cuts, so a sentence running into one
    /// is reported as possibly cut rather than as complete.
    ///
    /// Nil when the range falls outside `text` — including ranges whose end overflows, such as
    /// `NSNotFound` locations — or when no sentence covers it.
    public static func sentence(in text: String, around range: NSRange, clipped: Clipping = []) -> SentenceContext? {
        let count = text.utf16.count
        // Written so that no sum can overflow: a range from another process can be anything.
        guard range.location >= 0, range.length >= 0, range.location < count,
              range.length <= count - range.location,
              let selection = Range(range, in: text)
        else { return nil }
        let covering = tokens(.sentence, in: text).filter {
            $0.overlaps(selection) || $0.contains(selection.lowerBound)
        }
        guard let first = covering.first, let last = covering.last else { return nil }
        let mayBeCut = (clipped.contains(.start) && first.lowerBound == text.startIndex)
            || (clipped.contains(.end) && last.upperBound == text.endIndex)
        let sentence = trimmed(first.lowerBound..<last.upperBound, in: text)
        // The selection relative to the sentence, when it lies wholly inside it.
        let start = text.utf16.distance(from: text.startIndex, to: sentence.lowerBound)
        let length = text.utf16.distance(from: sentence.lowerBound, to: sentence.upperBound)
        let offset = range.location - start
        let inside = offset >= 0 && range.length <= length - offset
        return SentenceContext(
            text: String(text[sentence]), mayBeCut: mayBeCut,
            selection: inside ? NSRange(location: offset, length: range.length) : nil)
    }

    /// Every word in `text`, as the tokeniser breaks them. Used by the bounds-scan dialect, which
    /// asks the app where each of them sits, and by the recogniser, which needs a box per word.
    public static func wordRanges(in text: String) -> [Range<String.Index>] {
        tokens(.word, in: text).map { trimmed($0, in: text) }.filter { !$0.isEmpty }
    }

    /// The word containing `utf16Offset`, and the sentence around it.
    ///
    /// `clipped` says whether the text this was read from ran into the edge of what could be
    /// captured, so a sentence spliced from two cut lines is marked rather than passed off as
    /// whole. Nil when the offset is outside the text or lands on no word.
    public static func word(
        in text: String, utf16Offset: Int, clipped: Clipping = []
    ) -> WordAtPoint? {
        guard utf16Offset >= 0, utf16Offset < text.utf16.count else { return nil }
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        // An offset landing on the *low* surrogate of a pair has no `String.Index`, and the hover
        // paths estimate offsets from a pointer position — so pointing at the right half of a
        // supplementary character produced exactly that and the word was lost. Step back to the
        // character it belongs to rather than refusing.
        var index = String.Index(utf16Index, within: text)
        if index == nil, utf16Offset > 0 {
            index = String.Index(text.utf16.index(before: utf16Index), within: text)
        }
        guard let index else { return nil }
        guard let range = wordRanges(in: text).first(where: { $0.contains(index) || $0.lowerBound == index })
        else { return nil }
        let word = String(text[range])
        guard !word.isEmpty else { return nil }
        let location = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.utf16.distance(from: range.lowerBound, to: range.upperBound)
        guard let sentence = sentence(
            in: text, around: NSRange(location: location, length: length), clipped: clipped)
        else { return nil }
        return WordAtPoint(word: word, sentence: sentence)
    }

    private static func tokens(_ unit: NLTokenUnit, in text: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: unit)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
    }

    private static func trimmed(_ range: Range<String.Index>, in text: String) -> Range<String.Index> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
        while lower < upper, text[text.index(before: upper)].isWhitespace { upper = text.index(before: upper) }
        return lower..<upper
    }
}
