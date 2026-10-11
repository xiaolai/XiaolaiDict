import CaptureModel
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

/// **A word the reader may have meant**, under a lookup no dictionary answered — one button they may press, never a
/// word looked up in their place: mark, never jump.
public struct SpellingSuggestion: Sendable, Hashable {
    /// What the reader looked up, as they looked it up, and no dictionary had. The card compares it with its own term,
    /// so a suggestion can only ever be drawn under the lookup it was made for.
    public let term: String
    /// The word offered — one the reader's dictionaries were asked about and bear out.
    public let word: String
    /// **Why it is offered**, kept as typed data for the instrument and the log. The card draws every kind the same
    /// way, "Look up “X”" (the owner's ruling of 2026-10-11): a label naming the evidence was rejected.
    public let evidence: Evidence

    public enum Evidence: Sendable, Hashable {
        /// The reader's form table prints the term under the word (rule 1).
        case printed
        /// The term is the word's regular inflection in this slot, licensed by its entry, with no credible rival
        /// (rule 5).
        case regular(InflectionSlot)
        /// The regular inflection and the checker agree: the same word, or the same base in the same slot (rule 2).
        case agreement(InflectionSlot)
        /// The checker's verified correction, one edit away, with no morphological rival (rule 5).
        case correction(SpellingEdit.Operation)

        /// The rule's name, as `--spelling-report` prints it.
        public var rule: String {
            switch self {
            case .printed: "printed"
            case .regular: "regular"
            case .agreement: "agreement"
            case .correction: "correction"
            }
        }
    }

    public init(term: String, word: String, evidence: Evidence) {
        self.term = term
        self.word = word
        self.evidence = evidence
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

/// What asking for a suggestion came to — **one offer, or why there is none**, so the lookup path draws the first and
/// an instrument can say which of the others it was.
public enum SpellingOffer: Equatable, Sendable {
    /// The one word the card offers, as a button under the miss.
    case offered(SpellingSuggestion)
    /// Not asked at all, and why (`SpellingEligibility`).
    case refused(SpellingEligibility.Refusal)
    /// Asked, and nothing survived the rules: silence, which beats a wrong offer.
    case abstained(Abstention)

    /// The suggestion to draw, where there is one.
    public var suggestion: SpellingSuggestion? {
        guard case .offered(let suggestion) = self else { return nil }
        return suggestion
    }

    /// **Why a miss is offered nothing**, by the rule that decided it (`SpellingSuggester.decide`).
    public enum Abstention: String, Sendable, CaseIterable {
        /// No dictionary form and no correction from the checker — or only ones that are the term again.
        case noCandidate
        /// The checker's word, which no dictionary of the reader's has.
        case unverified
        /// The table prints the term under several bases and nothing in the lookup says which (rule 1).
        case printedAmbiguous
        /// The table prints the term under a base the dictionaries do not answer (rule 1).
        case printedUnverified
        /// A regular inflection and a credible checker correction name different words (rule 3).
        case conflict
        /// The term is one edit from a form printed under its base, and the checker's word is another family's (rule 4).
        case printedNeighbour
        /// A supported irregular pattern reads the term as another family's form than the checker's word (rule 4).
        case irregularPattern
        /// The checker's word is more than one edit away (rule 5).
        case tooFar
    }
}

/// **Miss → candidates → evidence → one offer or none**, the one path to a suggestion (ADR-0054 part B, the owner's
/// ruling of 2026-10-11). The lookup runner asks it beside the sense and the memory strip, and `--spelling-report` asks
/// it from the command line — one implementation, so the instrument measures what the card is offered.
///
/// No dictionary text leaves the Mac and no model is asked: the checker is the operating system's, and every
/// verification is an ordinary lookup through the same client as the reader's own.
public struct SpellingSuggester: Sendable {
    /// One lookup of a word through the dictionary service — `DictionaryClient.lookup(_:)`'s shape, which throws only
    /// when the caller was cancelled.
    public typealias LookUp = @Sendable (String) async throws(CancellationError) -> LookupOutcome

    private let checker: any SpellingSuggesting
    private let lookUp: LookUp
    private let language: @Sendable () -> String?
    private let forms: @Sendable () -> FormTable?

    /// `language` is the reader's English, asked each time so a reader who changes their languages is asked in the new
    /// one; by default the first English in their own list (`SpellingLanguage.readers`). `forms` is what the reader's
    /// dictionaries print as inflections, asked each time too: the table in force (`FormAuthority`) by default, which a
    /// process that never read one — every test — does not have.
    public init(checker: any SpellingSuggesting, lookUp: @escaping LookUp,
                language: @escaping @Sendable () -> String? = { SpellingLanguage.readers(Locale.preferredLanguages) },
                forms: @escaping @Sendable () -> FormTable? = { FormAuthority.shared.table }) {
        self.checker = checker
        self.lookUp = lookUp
        self.language = language
        self.forms = forms
    }

    /// What `term`'s lookup is offered — `decide`'s offer alone.
    public func offer(
        for term: String, outcome: LookupOutcome?, lemma: Lemma? = nil, capture: CaptureQuality.Source? = nil
    ) async throws(CancellationError) -> SpellingOffer {
        try await decide(for: term, outcome: outcome, lemma: lemma, capture: capture).offer
    }

    /// **One offer chosen by evidence, and silence where credible alternatives remain** — the owner's ruling of
    /// 2026-10-11, in this order, after the eligibility guards:
    ///
    /// 1. **A unique printed relationship wins.** The form table prints the term under one base (or under several, of
    ///    which the lookup's lemma names one): that base is offered if the dictionaries have it, and neither the
    ///    spelling rules nor the checker are asked. Printed under several the lemma cannot choose between: nothing.
    /// 2. **Agreement is one offer.** The term's regular dictionary form, licensed by its entry, and the checker's word
    ///    the same word — or the same base in the same slot (*gazebos* for *gazeboes*): the base. Sharing a base alone
    ///    is not agreement (*heavier* is not *heavied*'s slot).
    /// 3. **A regular form against a credible correction is nothing.** Credible: verified and one edit away, as the
    ///    checker's word must be to be offered alone. Distance never chooses between the two.
    /// 4. **A checker's word alone faces the term's morphological explanations first**: the base the lemmatiser proposed,
    ///    kept even where no rule made it a form, and a supported productive irregular (*-men*). The term one edit from a
    ///    form printed under that base, or read by the pattern, and the checker's word another family's: nothing.
    /// 5. **Otherwise the checker's verified word at one edit**, and a regular form with no credible rival.
    ///
    /// The same thresholds for every capture source; `capture` is recorded, never weighed. Throws only when the caller
    /// is cancelled — a newer lookup — and then **before a dictionary is asked**: the checker cannot be stopped mid-word,
    /// a verification lookup can, and a lookup nobody will see must not cost the service one.
    public func decide(
        for term: String, outcome: LookupOutcome?, lemma: Lemma? = nil, capture: CaptureQuality.Source? = nil
    ) async throws(CancellationError) -> SpellingDecision {
        var trial = Trial(term: term, capture: capture)
        if case .refused(let refusal) = SpellingEligibility.of(term: term, outcome: outcome) {
            return trial.decided(.refused(refusal))
        }
        let asked = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let table = forms()

        // 1. What the dictionaries print.
        switch PrintedEvidence.of(asked, lemma: lemma, in: table) {
        case .unique(let base)?:
            let verified = SpellingCorrection.isVerified(try await ask(base))
            trial.form = .init(word: base, evidence: .printed, supported: verified, edit: .between(asked, base))
            return trial.decided(verified ? trial.offered(base, .printed) : .abstained(.printedUnverified))
        case .ambiguous?:
            return trial.decided(.abstained(.printedAmbiguous))
        case nil:
            break
        }

        // The regular form, looked up first: what the checker's word is weighed against.
        trial.proposedBase = DictionaryForm.proposedBase(lemma, for: asked)
        let regular = DictionaryForm.regular(lemma, for: asked, printed: table)
        if let regular {
            let supported = regular.isSupported(by: try await ask(regular.word))
            trial.form = .init(word: regular.word, evidence: regular.evidence, supported: supported,
                               edit: .between(asked, regular.word))
        }
        let corrected = SpellingCorrection.candidate(await checker.suggestion(for: asked, language: language()), for: asked)

        if let regular, case .regular(let slot) = regular.evidence, trial.form?.supported == true {
            guard let corrected else { return trial.decided(trial.offered(regular.word, .regular(slot))) }
            // 2. The same word, or the same base in the same slot: one offer, the base.
            if Lemmatizer.canonical(corrected) == Lemmatizer.canonical(regular.word) {
                trial.correction = .init(word: corrected, verified: true, edit: .between(asked, corrected))
                return trial.decided(trial.offered(regular.word, .agreement(slot)))
            }
            let verified = SpellingCorrection.isVerified(try await ask(corrected))
            trial.correction = .init(word: corrected, verified: verified, edit: .between(asked, corrected))
            if Self.fills(slot, of: regular.word, with: corrected, table: table) {
                return trial.decided(trial.offered(regular.word, .agreement(slot)))
            }
            // 3. A credible rival leaves nothing; an unverified or distant one is no rival.
            guard verified, trial.correction?.edit.distance == 1 else {
                return trial.decided(trial.offered(regular.word, .regular(slot)))
            }
            return trial.decided(.abstained(.conflict))
        }

        // The checker's word alone.
        guard let corrected else { return trial.decided(.abstained(.noCandidate)) }
        let verified = SpellingCorrection.isVerified(try await ask(corrected))
        let edit = SpellingEdit.between(asked, corrected)
        trial.correction = .init(word: corrected, verified: verified, edit: edit)
        guard verified else { return trial.decided(.abstained(.unverified)) }
        // 4. A morphological explanation the checker's word is outside of.
        if let base = trial.proposedBase {
            let family = MorphologicalFamily(base: base, table: table)
            if !family.contains(corrected), family.hasPrintedNeighbour(of: asked) {
                return trial.decided(.abstained(.printedNeighbour))
            }
        }
        for pattern in IrregularPattern.all {
            guard let base = pattern.base(of: asked),
                  !MorphologicalFamily(base: base, table: table).contains(corrected) else { continue }
            if pattern.isSupported(base, by: try await ask(base)) {
                return trial.decided(.abstained(.irregularPattern))
            }
        }
        // 5. One edit, or nothing.
        guard edit.distance == 1, let operation = edit.operation else { return trial.decided(.abstained(.tooFar)) }
        return trial.decided(trial.offered(corrected, .correction(operation)))
    }

    /// **The checker's word fills the same slot of the same base** — *gazebos* is *gazebo*'s plural as *gazeboes* is — by
    /// the table's print or English's regular spelling, either doubling.
    private static func fills(_ slot: InflectionSlot, of base: String, with word: String, table: FormTable?) -> Bool {
        let written = Lemmatizer.canonical(word)
        let printed = (table?.printed(under: base) ?? []).contains {
            Lemmatizer.canonical($0.form) == written && RegularSpelling.slots(ofPrinted: $0.form, as: $0.partOfSpeech) == [slot]
        }
        return printed || ([true, false, nil] as [Bool?]).contains {
            RegularSpelling.forms(of: base, doubling: $0)[slot]?.contains(written) == true
        }
    }

    /// One verification lookup — never sent once the caller has been cancelled.
    private func ask(_ word: String) async throws(CancellationError) -> LookupOutcome {
        if Task.isCancelled { throw CancellationError() }
        return try await lookUp(word)
    }

    /// The decision being assembled.
    private struct Trial {
        let term: String
        let capture: CaptureQuality.Source?
        var form: SpellingDecision.FormTrial?
        var proposedBase: String?
        var correction: SpellingDecision.CorrectionTrial?

        init(term: String, capture: CaptureQuality.Source?) {
            self.term = term
            self.capture = capture
        }

        func offered(_ word: String, _ evidence: SpellingSuggestion.Evidence) -> SpellingOffer {
            .offered(SpellingSuggestion(term: term, word: word, evidence: evidence))
        }

        func decided(_ offer: SpellingOffer) -> SpellingDecision {
            SpellingDecision(term: term, capture: capture, offer: offer, form: form, proposedBase: proposedBase,
                             correction: correction)
        }
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
