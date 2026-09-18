import Foundation
import NaturalLanguage

/// A dictionary form, and what it rests on.
public struct Lemma: Equatable, Sendable {
    /// From most to least certain. A phrase takes its least certain word's basis.
    public enum Basis: Int, Comparable, Sendable {
        /// NLTagger's lemma.
        case tagger
        /// An irregular form NLTagger leaves unchanged — "saw", "found" — resolved from the grammar
        /// around it.
        case inferred
        /// An irregular form the sentence does not settle: "lay" may be "lie" or "lay". The word
        /// is kept as it is.
        case ambiguous
        /// No lemma known: the word is its own.
        case surface

        public static func < (lhs: Basis, rhs: Basis) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Lowercased, NFC, single-spaced: one spelling per ledger entry.
    public let text: String
    public let basis: Basis

    public init(text: String, basis: Basis) {
        self.text = text
        self.basis = basis
    }
}

/// Dictionary forms, so the ledger counts "running", "ran" and "runs" as one word (design note §9).
public enum Lemmatizer {
    /// The lemma of `word`. The sentence settles words whose lemma depends on how they are used —
    /// "leaves" is "leaf" as a noun, "leave" as a verb — so pass it when there is one, and `range`
    /// (UTF-16, within `sentence`) when the capture knows exactly where the word is. Without a
    /// range, the sentence is used only if the word occurs in it exactly once as a whole word:
    /// which occurrence was meant is not guessed. A word the tagger has no lemma for is its own
    /// lemma; it is never dropped.
    public static func lemma(of word: String, in sentence: String?, at range: NSRange? = nil) -> Lemma {
        let term = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sentence, let span = occurrence(of: term, in: sentence, at: range),
           let lemma = lemmatize(span, of: sentence) {
            return lemma
        }
        // On its own, a phrase selected across a line break is still one phrase: tagged with the
        // break, its words read as separate paragraphs and get no lemma.
        let phrase = term.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return lemmatize(phrase.startIndex..<phrase.endIndex, of: phrase) ?? Lemma(text: canonical(phrase), basis: .surface)
    }

    /// Lowercased, NFC, with a curly apostrophe written straight, so the same word typed or copied
    /// differently is one ledger entry.
    public static func canonical(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'").lowercased().precomposedStringWithCanonicalMapping
    }

    // MARK: - Placing the word in its sentence

    /// Where `term` sits in `sentence`: at `range` when that holds the term on word boundaries,
    /// otherwise its one whole-word occurrence. Nil when it is absent, when it occurs only inside
    /// longer words ("he" in "When"), or when it is repeated.
    static func occurrence(of term: String, in sentence: String, at range: NSRange?) -> Range<String.Index>? {
        guard !term.isEmpty else { return nil }
        let words = wordRanges(in: sentence)
        let starts = Set(words.map(\.lowerBound))
        let ends = Set(words.map(\.upperBound))
        func onWordBoundaries(_ span: Range<String.Index>) -> Bool {
            starts.contains(span.lowerBound) && ends.contains(span.upperBound)
        }
        if let range, range.location >= 0, range.length > 0, range.length <= sentence.utf16.count,
           range.location <= sentence.utf16.count - range.length,
           let span = Range(range, in: sentence),
           sentence[span].lowercased() == term.lowercased(), onWordBoundaries(span) {
            return span
        }
        var found: [Range<String.Index>] = []
        var from = sentence.startIndex
        while from < sentence.endIndex,
              let span = sentence.range(of: term, options: .caseInsensitive, range: from..<sentence.endIndex) {
            if onWordBoundaries(span) { found.append(span) }
            from = sentence.index(after: span.lowerBound)
        }
        return found.count == 1 ? found[0] : nil
    }

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
    }

    // MARK: - Lemmatizing

    /// The lemma of the words in `span`, tagged in the context of all of `text`. Each word is
    /// replaced by its lemma, so "gave up" becomes "give up". Nil when the tagger's words do not
    /// line up with `span` — then slicing by them is not safe.
    private static func lemmatize(_ span: Range<String.Index>, of text: String) -> Lemma? {
        let tokens = tag(text)
        let inside = tokens.indices.filter { tokens[$0].range.overlaps(span) }
        guard !inside.isEmpty, inside.allSatisfy({
            span.lowerBound <= tokens[$0].range.lowerBound && tokens[$0].range.upperBound <= span.upperBound
        }) else { return nil }

        var lemma = ""
        var basis = Lemma.Basis.tagger
        for (position, index) in inside.enumerated() {
            if position > 0 {
                lemma += separator(text[tokens[inside[position - 1]].range.upperBound..<tokens[index].range.lowerBound])
            }
            let word = resolve(index, in: tokens)
            lemma += word.text
            basis = max(basis, word.basis)
        }
        return Lemma(text: canonical(lemma), basis: basis)
    }

    private static func tag(_ text: String) -> [LemmaToken] {
        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        tagger.string = text
        var tokens: [LemmaToken] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { lexicalClass, range in
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            tokens.append(LemmaToken(
                range: range, word: String(text[range]).lowercased(), lemma: lemma?.lowercased(),
                lexicalClass: lexicalClass))
            return true
        }
        return tokens
    }

    /// What joins two words of a phrase in its lemma. Punctuation with no space around it is part
    /// of the phrase and stays (rock-and-roll); a gap with any whitespace in it separates words,
    /// whatever punctuation it also holds, and becomes one space — so a phrase selected across a
    /// line break or a sentence end ("here. Second") is words, not "here.second"; nothing where
    /// the script uses no spaces (Chinese).
    private static func separator(_ gap: Substring) -> String {
        if gap.contains(where: \.isWhitespace) { return " " }
        return String(gap)
    }

    private static func resolve(_ index: Int, in tokens: [LemmaToken]) -> Lemma {
        let token = tokens[index]
        guard let tagged = token.lemma, !tagged.isEmpty else { return Lemma(text: token.word, basis: .surface) }
        guard tagged == token.word, token.lexicalClass == .verb, let form = AmbiguousPastForm.table[token.word] else {
            return Lemma(text: tagged, basis: .tagger)
        }
        return form.resolve(token.word, after: tokens[..<index])
    }
}

/// A word of the text being lemmatized, lowercased, with what NLTagger made of it.
private struct LemmaToken {
    let range: Range<String.Index>
    let word: String
    let lemma: String?
    let lexicalClass: NLTag?
}

/// Irregular past forms that are also the base form of another word. NLTagger returns them
/// unchanged, even when it tags them as verbs — measured on macOS 27, 2026-09-18 — so the grammar
/// around them has to choose. Not a replacement table: "will found a company" and "to lay the
/// table" keep their own verbs, and a form the grammar cannot settle is kept and reported as
/// ambiguous rather than guessed.
private struct AmbiguousPastForm {
    /// The verb it is the simple past of: saw → see.
    let pastOf: String
    /// The verb it is the past participle of, if it is one: found → find; but "seen", not "saw".
    let participleOf: String?
    /// Whether the past reading is the everyday one when the grammar is silent — "I saw it" is
    /// nearly always "see". False where both readings are common: "they lay down" / "they lay bricks".
    let pastUsuallyMeant: Bool

    static let table: [String: AmbiguousPastForm] = [
        "saw": .init(pastOf: "see", participleOf: nil, pastUsuallyMeant: true),
        "found": .init(pastOf: "find", participleOf: "find", pastUsuallyMeant: true),
        "felt": .init(pastOf: "feel", participleOf: "feel", pastUsuallyMeant: true),
        "fell": .init(pastOf: "fall", participleOf: nil, pastUsuallyMeant: true),
        "rose": .init(pastOf: "rise", participleOf: nil, pastUsuallyMeant: true),
        "lay": .init(pastOf: "lie", participleOf: nil, pastUsuallyMeant: false),
        "bore": .init(pastOf: "bear", participleOf: nil, pastUsuallyMeant: false),
        "wound": .init(pastOf: "wind", participleOf: "wind", pastUsuallyMeant: false),
    ]

    /// Before a base form: "will found", "to lay", "did lay".
    private static let baseFormMarkers: Set<String> = [
        "will", "would", "shall", "should", "can", "could", "may", "might", "must", "to", "do", "does", "did", "'ll",
    ]
    /// Before a participle: "had found", "was felt".
    private static let participleMarkers: Set<String> = [
        "have", "has", "had", "having", "'ve", "be", "been", "being", "am", "is", "are", "was", "were",
    ]
    /// A present tense after these would take -s ("he lays"), so the bare form is the past.
    private static let thirdPersonSingular: Set<String> = ["he", "she", "it"]
    private static let possessives: Set<String> = ["my", "your", "his", "her", "its", "our", "their"]
    private static let objectPronouns: Set<String> = ["me", "you", "him", "her", "it", "us", "them"]

    /// Decided by the nearest preceding word that is not an adverb: "she never saw" is "she saw".
    func resolve(_ surface: String, after preceding: ArraySlice<LemmaToken>) -> Lemma {
        if Self.endsNounPhrase(preceding) { return Lemma(text: surface, basis: .tagger) }
        if let previous = preceding.last(where: { $0.lexicalClass != .adverb }) {
            if Self.baseFormMarkers.contains(previous.word) { return Lemma(text: surface, basis: .tagger) }
            if Self.participleMarkers.contains(previous.word) {
                return participleOf.map { Lemma(text: $0, basis: .inferred) } ?? Lemma(text: surface, basis: .ambiguous)
            }
            if Self.thirdPersonSingular.contains(previous.word) { return Lemma(text: pastOf, basis: .inferred) }
        }
        return pastUsuallyMeant ? Lemma(text: pastOf, basis: .inferred) : Lemma(text: surface, basis: .ambiguous)
    }

    /// Whether the form is the last word of a noun phrase, where it is a noun however NLTagger tags
    /// it — and it tags "felt" in "she wore a felt hat" and "rose" in "she gave me a red rose" as
    /// verbs. Straight after a determiner or possessive ("a rose", "his wound"); or after one and
    /// its modifiers when the phrase is an object — after a verb, preposition or object pronoun.
    /// A phrase opening the sentence is left alone: "The sun rose" and "A red rose" have the same
    /// shape, and only the first is the usual reading of that shape.
    private static func endsNounPhrase(_ preceding: ArraySlice<LemmaToken>) -> Bool {
        var start = preceding.endIndex
        while start > preceding.startIndex,
              [NLTag.adjective, .noun].contains(preceding[start - 1].lexicalClass) {
            start -= 1
        }
        guard start > preceding.startIndex else { return false }
        let head = preceding[start - 1]
        guard head.lexicalClass == .determiner || possessives.contains(head.word) else { return false }
        if start == preceding.endIndex { return true }
        guard start - 1 > preceding.startIndex else { return false }
        let before = preceding[start - 2]
        return before.lexicalClass == .verb || before.lexicalClass == .preposition || objectPronouns.contains(before.word)
    }
}
