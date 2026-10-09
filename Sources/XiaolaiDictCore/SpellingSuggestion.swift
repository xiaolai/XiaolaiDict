import DictionaryModel
import Foundation

/// **The operating system's spelling corrector, as a lookup asks it** — one confident correction of a word no
/// dictionary had, or none (plan-spelling-suggestion §2–§3).
///
/// Below the view layer, because the rules that decide whether to ask it and whether to believe it are not AppKit's:
/// they are tested without a window server, and the adapter in the app is the one file that names `NSSpellChecker`.
///
/// **One correction, never a list of guesses.** Measured 2026-10-09 on 28 words: the correction answered the twelve
/// common typos right every time and was silent for the OCR confusions, the known words and the nonsense, where the
/// guess list was wrong or noise. No suggestion beats a wrong one, so the guess list is never asked.
public protocol SpellingSuggesting: Sendable {
    /// The checker's one confident correction of `term`, or nil where it has none. `language` is the reader's English
    /// as a BCP 47 tag — `en-GB` — or nil for English with no variant.
    func suggestion(for term: String, language: String?) async -> String?
}

/// **A word the reader may have meant**, under a lookup no dictionary answered — a line they may tap, never a word
/// looked up in their place: mark, never jump.
public struct SpellingSuggestion: Sendable, Hashable {
    /// What the reader looked up, as they looked it up, and no dictionary had. The card compares it with its own term,
    /// so a suggestion can only ever be drawn under the lookup it was made for.
    public let term: String
    /// What the checker offered instead, in its own spelling — a word the reader's dictionaries were asked about and
    /// have (`SpellingCorrection.isVerified`).
    public let word: String
    /// What the word is to the term: the checker's correction of a typo, or the term's dictionary form — "ran" as
    /// "run", where the dictionaries had no entry for the inflection (plan-card-refinements WI-3).
    public let kind: Kind

    public enum Kind: String, Sendable, Hashable {
        case spelling
        case dictionaryForm
    }

    public init(term: String, word: String, kind: Kind = .spelling) {
        self.term = term
        self.word = word
        self.kind = kind
    }
}

/// **Whether a lookup may be offered a suggestion at all** — decided before the checker is asked, so a word that was
/// found, or a question the service never answered, costs nothing and is never second-guessed.
public enum SpellingEligibility: Equatable, Sendable {
    case eligible
    case refused(Refusal)

    /// Why a lookup is offered nothing. **The first reason that decided it**, the outcome before the word's shape — so a
    /// found phrase is "not a miss", and the instrument says so.
    ///
    /// **No refusal by the sentence's language**, measured rather than assumed (2026-10-09): `NLLanguageRecognizer`
    /// read "I saw teh cat." as Catalan and "Teh cat sat on teh mat." as Indonesian — the typo is what throws it — so a
    /// refusal by language refused the very sentences the feature is for.
    public enum Refusal: String, Sendable, CaseIterable {
        /// A dictionary answered, the public fallback answered in prose, or nothing has answered yet.
        case notAMiss
        /// A miss only because the dictionary service could not be asked. Not a spelling problem, and the card already
        /// says the answer may be incomplete: a suggestion under it would read as a confirmed absence.
        case serviceUnanswered
        /// A phrase, or nothing at all. "Did you mean" for a phrase is not this feature (§6).
        case notOneWord
        /// Not Latin letters alone: CJK, Hangul, a number, a symbol, a digit inside a word, punctuation at an edge.
        /// The study scripts are scripts (ADR-0001), and the checker is asked in English.
        case notLatinLetters
    }

    public static func of(term: String, outcome: LookupOutcome?) -> SpellingEligibility {
        switch outcome {
        case .notFound(serviceFailure: nil): break
        case .notFound: return .refused(.serviceUnanswered)
        case .entries, .plainText, nil: return .refused(.notAMiss)
        }
        if let refusal = refusal(byShapeOf: term) { return .refused(refusal) }
        return .eligible
    }

    /// What joins a word's letters where a word holds them — *o'clock*, *don’t*, *well-known* — and only inside it: at
    /// an edge it is punctuation the capture did not trim, and the term is not a word.
    private static let joiners: Set<Unicode.Scalar> = ["'", "\u{2019}", "-", "\u{2010}"]

    /// **Letterhood is asked of Unicode and the script of `ProbeScript`**, never inferred from a block, and the term is
    /// compatibility-normalised first — the two rules the hover filter learned, so fullwidth `ｔｅｈ` is Latin and `ｔｅｈ水`
    /// is not.
    private static func refusal(byShapeOf term: String) -> Refusal? {
        let word = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !word.contains(where: \.isWhitespace) else { return .notOneWord }
        let scalars = Array(word.precomposedStringWithCompatibilityMapping.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            if scalar.properties.isAlphabetic {
                guard ProbeScript.of(String(scalar)) == .latin else { return .notLatinLetters }
            } else if !joiners.contains(scalar) || index == scalars.startIndex || index == scalars.endIndex - 1 {
                return .notLatinLetters
            }
        }
        return nil
    }
}

/// What asking for a suggestion came to — **the one offer, and every way there was none, kept apart**, so the lookup
/// path can draw the first and an instrument can say which of the others it was.
public enum SpellingOffer: Equatable, Sendable {
    /// A correction the reader's dictionaries have: drawn as a line under the miss.
    case offered(SpellingSuggestion)
    /// Not asked at all, and why (`SpellingEligibility`).
    case refused(SpellingEligibility.Refusal)
    /// The checker had no confident correction, or only the term again up to case.
    case noCorrection
    /// The checker's word, which no dictionary of the reader's has. Never offered.
    case unverified(String)

    /// The suggestion to draw, where there is one.
    public var suggestion: SpellingSuggestion? {
        guard case .offered(let suggestion) = self else { return nil }
        return suggestion
    }
}

/// **Miss → correction → verified → offered**, the one path to a suggestion (§3). The lookup runner asks it beside the
/// sense and the memory strip, and `--spelling-report` asks it from the command line — one implementation, so the
/// instrument measures what the card is offered.
///
/// No dictionary text leaves the Mac and no model is asked: the checker is the operating system's, and the
/// verification is an ordinary lookup through the same client as the reader's own.
public struct SpellingSuggester: Sendable {
    /// One lookup of a word through the dictionary service — `DictionaryClient.lookup(_:)`'s shape, which throws only
    /// when the caller was cancelled.
    public typealias LookUp = @Sendable (String) async throws(CancellationError) -> LookupOutcome

    private let checker: any SpellingSuggesting
    private let lookUp: LookUp
    private let language: @Sendable () -> String?

    /// `language` is the reader's English, asked each time so a reader who changes their languages is asked in the new
    /// one; by default the first English in their own list (`SpellingLanguage.readers`).
    public init(checker: any SpellingSuggesting, lookUp: @escaping LookUp,
                language: @escaping @Sendable () -> String? = { SpellingLanguage.readers(Locale.preferredLanguages) }) {
        self.checker = checker
        self.lookUp = lookUp
        self.language = language
    }

    /// What `term`'s lookup is offered. Throws only when the caller is cancelled — a newer lookup — and then **after the
    /// checker and before the dictionaries**: the checker cannot be stopped mid-word, the verification lookup can, and a
    /// lookup nobody will see must not cost the service one.
    ///
    /// **And where the checker has nothing the dictionaries have, the term's dictionary form** — `lemma`, the one the
    /// lookup already worked out — offered the same way, verified the same way (plan-card-refinements WI-3). Second,
    /// because a typo's correction is the better answer, and a typo reaching the lemma path was most of the wrong
    /// recoveries measured; and only a lemma the lemmatiser stands by — never `ambiguous`, never the word again.
    public func offer(
        for term: String, outcome: LookupOutcome?, lemma: Lemma? = nil
    ) async throws(CancellationError) -> SpellingOffer {
        if case .refused(let refusal) = SpellingEligibility.of(term: term, outcome: outcome) {
            return .refused(refusal)
        }
        let asked = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = await checker.suggestion(for: asked, language: language())
        let spelling: SpellingOffer
        if let word = SpellingCorrection.candidate(corrected, for: asked) {
            if Task.isCancelled { throw CancellationError() }
            guard !SpellingCorrection.isVerified(try await lookUp(word)) else {
                return .offered(SpellingSuggestion(term: term, word: word))
            }
            spelling = .unverified(word)
        } else {
            spelling = .noCorrection
        }
        guard let form = DictionaryForm.candidate(lemma, for: asked) else { return spelling }
        if Task.isCancelled { throw CancellationError() }
        guard SpellingCorrection.isVerified(try await lookUp(form)) else { return spelling }
        return .offered(SpellingSuggestion(term: term, word: form, kind: .dictionaryForm))
    }
}

/// **The term's dictionary form worth asking the dictionaries about**, or nil (plan-card-refinements WI-3).
public enum DictionaryForm {
    /// A lemma the lemmatiser stands by — the tagger's, a rule's or the usual reading of an irregular, never one it
    /// called `ambiguous` or none at all — that is not the term again up to case.
    public static func candidate(_ lemma: Lemma?, for term: String) -> String? {
        guard let lemma, lemma.basis <= .likely else { return nil }
        let form = lemma.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !form.isEmpty, form.compare(term, options: .caseInsensitive) != .orderedSame else { return nil }
        return form
    }
}

/// **Which English the checker is asked in** (§2, conclusion 3): `modernisation` is a typo to an American checker and a
/// word to a British one, so the reader's own English decides where it is known.
public enum SpellingLanguage {
    /// The first English in the reader's own list of languages, as they list it — `en-GB` — or nil where they list
    /// none, which asks plain English. A Chinese reader who reads British English is asked in British English.
    public static func readers(_ preferred: [String]) -> String? {
        preferred.first { Locale(identifier: $0).language.languageCode == .english }
    }

    /// The checker language `requested` is asked in, among the checker's own (`en_GB`, its underscore spelling): the
    /// variant where the checker has it, plain `en` where it does not, the one variant it has where it has no plain
    /// English — and nil where it has no English at all, which is a checker not to ask. A request that is not English
    /// asks English: the checker is asked in English or not at all.
    ///
    /// **American English is plain `en`, never `en_US`.** Measured 2026-10-09 on the E2E Mac: inside the running app the
    /// checker listed `en_US` and, asked in it, answered nothing for every typo, while every process that listed no
    /// `en_US` asked `en` and was answered; `en` is the checker's American English, and `en_GB` in the app answered.
    public static func checker(for requested: String?, available: [String]) -> String? {
        if let requested, Locale(identifier: requested).language.languageCode == .english,
           let region = Locale(identifier: requested).region?.identifier, region != "US" || !available.contains("en"),
           available.contains("en_\(region)") {
            return "en_\(region)"
        }
        if available.contains("en") { return "en" }
        return available.first { $0.hasPrefix("en_") }
    }
}

/// **What the checker said, and what the dictionaries said about it** — the two filters between a correction and a
/// line on the card.
public enum SpellingCorrection {
    /// The checker's word worth asking the dictionaries about, or nil: no answer, a blank one, or the term again up to
    /// case (§3). **Case only**: an accent the reader left out is a correction, and the checker's capitalisation is kept.
    public static func candidate(_ correction: String?, for term: String) -> String? {
        guard let word = correction?.trimmingCharacters(in: .whitespacesAndNewlines), !word.isEmpty else { return nil }
        let asked = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return word.compare(asked, options: .caseInsensitive) == .orderedSame ? nil : word
    }

    /// **Whether the reader's dictionaries have the word**: an entry headed by it, or by its dictionary form — the
    /// filter Apple's card lacks (§2, conclusion 2), since the checker knowing a word says nothing about the
    /// dictionaries. Another headword is a near match and not the word; a dictionary that did not say which headword it
    /// answered with has said nothing about this one; prose from the public fallback means the service could not be
    /// asked; and a miss is a miss.
    public static func isVerified(_ outcome: LookupOutcome) -> Bool {
        guard case .entries(let entries, _) = outcome else { return false }
        return entries.contains { $0.match == .exact || $0.match == .dictionaryForm }
    }
}
