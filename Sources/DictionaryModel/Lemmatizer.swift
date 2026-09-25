import Foundation
import NaturalLanguage

/// A dictionary form, and what it rests on.
public struct Lemma: Equatable, Sendable {
    /// From most to least certain. A phrase takes its least certain word's basis.
    public enum Basis: Int, Comparable, CaseIterable, Sendable {
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

        /// The name the ledger stores. Spelled out rather than taken from the raw value, which is
        /// an `Int` so that "less certain" can be compared — a stored ordinal would silently
        /// re-point every old row if a case were ever inserted in the middle.
        public var name: String {
            switch self {
            case .tagger: "tagger"
            case .inferred: "inferred"
            case .ambiguous: "ambiguous"
            case .surface: "surface"
            }
        }

        public init?(name: String) {
            guard let match = Basis.allCases.first(where: { $0.name == name }) else { return nil }
            self = match
        }
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
    /// The part of speech `word` is being used as, in the sentence around it. Nil when there is no
    /// sentence, or when the tagger will not commit — a guessed part of speech would rule out the
    /// right sense as confidently as it rules out the wrong ones.
    ///
    /// Reported in the dictionaries' own vocabulary — "noun", "verb", "adjective", "adverb" — so it
    /// can be compared against a part-of-speech block's `d:pos` without a mapping table.
    public static func partOfSpeech(of word: String, in sentence: String?, at range: NSRange?) -> String? {
        Pass().partOfSpeech(of: word, in: sentence, at: range)
    }

    /// One pass over many words, reusing the tagger they all need.
    ///
    /// `NLTagger` is expensive to build and the drawer asks for a part of speech once per card, so
    /// the one-shot call above is the wrong shape for a batch. Same answers, one tagger: the
    /// convenience form is this with a pass of its own.
    public struct Pass {
        private let tagger = NLTagger(tagSchemes: [.lexicalClass])

        public init() {}

        public func partOfSpeech(of word: String, in sentence: String?, at range: NSRange?) -> String? {
            Lemmatizer.partOfSpeech(of: word, in: sentence, at: range, using: tagger)
        }
    }

    private static func partOfSpeech(
        of word: String, in sentence: String?, at range: NSRange?, using tagger: NLTagger
    ) -> String? {
        // A word with no sentence around it is still a word. The ledger stores the selection
        // itself as the context where nothing surrounded it, and those rows still want an answer.
        let text = (sentence?.isEmpty == false ? sentence : nil) ?? word
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let sentence = text
        tagger.string = sentence
        // `occurrence(of:in:at:)`, not a second search written here. This had its own weaker
        // rules: it took any supplied range without checking it held the word, and fell back to a
        // bare substring search — so `art` matched inside `Start` and a repeated word silently took
        // its first occurrence, in both cases tagging a different word than the one looked up.
        // `occurrence` checks word boundaries, and answers nil where the sentence is ambiguous,
        // which is what this function's own comment already promised.
        guard let target = occurrence(of: word, in: sentence, at: range) else { return nil }
        let tag = tagger.tag(at: target.lowerBound, unit: .word, scheme: .lexicalClass).0
        switch tag {
        case .noun, .personalName, .placeName, .organizationName: return "noun"
        case .verb: return "verb"
        case .adjective: return "adjective"
        case .adverb: return "adverb"
        default: return nil
        }
    }

    /// The language of `word`, judged from the sentence around it where there is one — a single
    /// word is often too little to tell. A lemma alone collides across languages: *die*, *chat*,
    /// *pain*, *gift*, which is why the ledger keeps this beside it.
    ///
    /// Nil when the recognizer will not commit, which is honest: a guessed language would split one
    /// word into two study items or merge two into one.
    public static func language(of word: String, in sentence: String?) -> String? {
        let sample = (sentence?.isEmpty == false ? sentence : nil) ?? word
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }

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

    /// **Every part of the looked-up term inside the sentence it was read in** — plural, because a
    /// lemma can be a phrase.
    ///
    /// Two problems, one answer. The captured range covers the surface as it was found, which is
    /// not always a whole word: *temper* captured in "Justice tempered with mercy" is a range over
    /// `temper`, and emphasising exactly that draws **temper**ed — the word broken in half, the
    /// shape the eye is worst at reading. And a phrasal verb is not contiguous: *take over* read in
    /// "He took it over" is two pieces with a word between them, which one range can only either
    /// clip or swallow the pronoun to cover.
    ///
    /// Word boundaries come from `NLTokenizer`, the same source `occurrence(of:in:at:)` uses. A
    /// walk outward through `Character.isLetter` was written first and was wrong for Chinese: Han
    /// characters are all letters and the script has no spaces, so it grew from 屹立 across
    /// 他屹立在山顶上 and stopped only at the full stop.
    ///
    /// The rest of a phrase is matched on the token's own text, not on its lemma. A phrasal verb's
    /// particle — *over*, *up*, *off* — does not inflect, so this is right for the cases that exist
    /// and costs no tagger. Where it fails it marks the anchor and stops: a partly marked phrase is
    /// honest, a wrongly marked one is not.
    ///
    /// **The case it gives up on**, named so nobody has to rediscover it: a lemma whose later words
    /// inflect. Lemma *prepare mind* read as "prepared minds" marks `prepared` and leaves `minds`,
    /// because `mind` and `minds` are different spellings. Lemmatising each candidate token would
    /// catch it, at a tagger per card for a shape English phrasal verbs do not have.
    public static func parts(
        of lemma: String, surface: String, in sentence: String, at range: NSRange?
    ) -> [NSRange] {
        guard let range, let captured = Range(range, in: sentence) else { return [] }
        let tokens = wordRanges(in: sentence)
        guard let anchor = tokens.firstIndex(where: { $0.overlaps(captured) }) else {
            // No word boundary to grow to — punctuation, or a script the tokenizer declined. The
            // captured range is still the truth about what was looked up.
            return [range]
        }

        var marked = [tokens[anchor]]
        var searchFrom = anchor + 1
        for part in words(of: lemma, or: surface).dropFirst() {
            let window = tokens[searchFrom...].prefix(phraseLookahead)
            guard let hit = window.firstIndex(where: {
                sentence[$0].compare(part, options: .caseInsensitive) == .orderedSame
            }) else { break }
            marked.append(tokens[hit])
            searchFrom = hit + 1
        }
        return marked.map { NSRange($0, in: sentence) }
    }

    /// How far past the anchor the rest of a phrase may sit. "He took the whole thing over" is
    /// four; beyond that a matching word is more likely to be a different word that happens to
    /// spell the same.
    private static let phraseLookahead = 4

    /// The words a looked-up term is made of. The lemma is the canonical form — *take over* — and
    /// the surface is what was on screen, which for a selection may be the longer of the two.
    static func words(of lemma: String, or surface: String) -> [String] {
        let fromLemma = lemma.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fromLemma.count > 1 else {
            let fromSurface = surface.split(whereSeparator: \.isWhitespace).map(String.init)
            return fromSurface.count > 1 ? fromSurface : fromLemma
        }
        return fromLemma
    }

    /// Word boundaries, from the one place that draws them.
    ///
    /// **`TextSegmenter.wordRanges` rather than a copy here**, which is what this was: the same
    /// three lines around the same `NLTokenizer`, minus the trimming and the empty-token filter. So
    /// the hover and OCR paths agreed about where a word ends and the lemma path did not, and
    /// `parts(of:surface:in:at:)` is what marks the reader's own sentence in the drawer.
    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        TextSegmenter.wordRanges(in: text)
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
        // **Before the nil guard, because "no lemma" is one of the answers being corrected.** Four
        // of the 189 forms probed answer nothing at all — `swore`, `sprang`, `leant`, `learnt` —
        // and landing on `surface` is honest but useless: a study item keyed to *swore* never joins
        // the one keyed to *swear*, which is the whole job of a lemma. Consulted after the guard,
        // the correction could never see them.
        if token.lexicalClass == .verb, let corrected = TaggerCorrection.table[token.word] {
            return Lemma(text: corrected, basis: .inferred)
        }
        guard let tagged = token.lemma, !tagged.isEmpty else { return Lemma(text: token.word, basis: .surface) }
        // **A lemma the tagger got wrong, which the table above cannot reach.** `AmbiguousPastForm`
        // is consulted only where the tagger returned the word *unchanged* — a form it declined to
        // resolve. This is the other failure: a form it resolved, to the wrong verb. Measured on
        // macOS 27, 2026-09-24: `broke` lemmatises to `brake` in every sentence tried, tagged Verb,
        // so it arrived as a confident dictionary form for a word the reader never read. Kept as a
        // separate table because the two are different facts about the tagger, and because this one
        // needs no grammar: "broke" is the past of "break" and of nothing else.
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

/// Forms NLTagger resolves to the **wrong** word, corrected by surface form.
///
/// Distinct from `AmbiguousPastForm`, which is about forms the tagger leaves alone. Here it commits,
/// confidently, to a different verb — so nothing downstream can tell the answer is wrong, and the
/// basis recorded would be `tagger`, the strongest there is. `inferred` instead: this project knows
/// better than the tagger, and the row should say the lemma came from a rule rather than from it.
///
/// **Kept short and measured.** An entry earns its place by being probed, not by being remembered:
/// every one here was reproduced across several sentences on macOS 27, 2026-09-24. A correction
/// added on a hunch would be this project overriding Apple's model on no evidence.
private enum TaggerCorrection {
    static let table: [String: String] = [
        // "brake" in all five sentences probed, tagged Verb each time. The past of "brake" is
        // "braked", so "broke" has no reading that leads there.
        "broke": "break",
        // The same defect in the participle: `broken` also answers `brake`, so it never looks
        // unchanged and the ambiguous table can never see it.
        "broken": "break",
        // These four answer `nil` rather than a wrong word — the other way the tagger fails. Each
        // is unambiguous: no other verb has them as a form, so no grammar is needed to choose.
        // `leant` and `learnt` are the British spellings, which a reader of British text meets.
        "swore": "swear",
        "sprang": "spring",
        "leant": "lean",
        "learnt": "learn",
    ]
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
        // **Measured, not guessed at.** Probed on macOS 27 across 63 irregular English forms on
        // 2026-09-24: ten came back from NLTagger unchanged, and those ten are exactly the forms
        // that are also words in their own right — which is the criterion this table was built on,
        // confirmed by the tagger's own behaviour. Eight of the ten were here. These are the two
        // that were not, and being absent was worse than being unhandled: `resolve` falls through
        // to `Lemma(text: tagged, basis: .tagger)`, so "they ground the coffee" recorded a study
        // item for the earth under the reader's feet, under the most confident basis there is.
        "ground": .init(pastOf: "grind", participleOf: "grind", pastUsuallyMeant: true),
        // `false`, unlike `ground`: bare "bound" as a verb is *not* usually bind. "bound for
        // London" and "bound to happen" are both tagged Verb by NLTagger and neither is binding,
        // so where the grammar is silent this stays the surface form and is reported ambiguous —
        // which is the table's whole discipline, and the reason it is not a replacement list.
        "bound": .init(pastOf: "bind", participleOf: "bind", pastUsuallyMeant: false),
        // **The participle-only forms.** Probed across 189 irregular forms, 2026-09-24: nineteen
        // come back from the tagger unchanged, not the ten a 63-form sample had suggested. These
        // five are the ones this mechanism can reach. `pastUsuallyMeant: false` where the form is
        // never a simple past — "driven", "spoken", "sworn" — so with no participle marker in front
        // they stay as they are and are reported ambiguous: "a driven man" is an adjective a reader
        // may well be looking up, and guessing "drive" there would be a confident wrong answer of
        // exactly the kind this table exists to prevent.
        "driven": .init(pastOf: "drive", participleOf: "drive", pastUsuallyMeant: false),
        "spoken": .init(pastOf: "speak", participleOf: "speak", pastUsuallyMeant: false),
        "sworn": .init(pastOf: "swear", participleOf: "swear", pastUsuallyMeant: false),
        // Both a past and a participle, and the adjective reading ("burnt toast") is tagged
        // adjective, where this table never fires — so the past reading can be taken where the
        // grammar is silent.
        "burnt": .init(pastOf: "burn", participleOf: "burn", pastUsuallyMeant: true),
        // Past of spit. The noun ("a spat about it") is tagged noun and so never reaches here.
        "spat": .init(pastOf: "spit", participleOf: "spit", pastUsuallyMeant: true),
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
