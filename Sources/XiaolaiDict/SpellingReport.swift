import DictionaryModel
import Foundation
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictUI

/// `--spelling-report TERM…`: **what each term's miss would be offered** — "Did you mean …?" — through the checker and
/// the dictionaries the card is offered it by, one JSON line a term (plan-spelling-suggestion §3).
///
/// Each term is looked up as `--lookup` looks it up, then asked of `SpellingSuggester` — the one the lookup runner asks
/// — so the instrument measures what the card is offered, not a second implementation of it. **What it prints is the
/// term, kinds, the checker's word, the term's dictionary form and two durations**: never a definition, a headword or a
/// dictionary's name, which are licensed text a shell has no business printing.
///
/// **Compiled out of a release**, as `--reminder-report` and `--provider-status` are: a reader has the line on the card,
/// and nothing in a reader's copy needs a command that asks the spell checker on demand. `verify_bundle` checks both
/// directions, by this file's two sentences.
@MainActor
enum SpellingReport {
    static func run(terms: [String]) async -> CommandStatus {
#if !XIAOLAIDICT_CAPTURE_INSTRUMENTS
        LookupCommand.writeError("--spelling-report is a development instrument and is not built into a release")
        return .usage
#else
        // The witness `verify_bundle` looks for in a development bundle: a sentence only this branch has.
        LookupCommand.writeError("spelling-report: asking the spell checker about each term the dictionaries miss")
        // **The reader's own form table, as the app reads it at launch** — the dictionary form the card is offered is
        // decided with it (plan-card-refinements WI-3), and without it a term alone has only the tagger's lemma.
        FormAuthority.shared.use(FormTableStore())
        let client = DictionaryClient()
        return await run(terms: terms, lookUp: { term throws(CancellationError) in try await client.lookup(term) },
                         checker: SystemSpellChecker(), write: LookupCommand.writeLine)
#endif
    }

    /// The report for `terms`, through `lookUp` and `checker`, written through `write`. **`.failure` where the service
    /// could not answer a term** — a miss it could not answer, or prose from the public fallback: neither was the
    /// dictionaries' answer, so what it was offered says nothing about them. The line is still written, and the exit
    /// says so. Judged from the outcome by the rule the card's caveat uses (`PanelCaveats.serviceUnanswered`), never
    /// from the offer, which calls the fallback's prose "not a miss" (audit round 2, 2026-10-09).
    static func run(
        terms: [String], lookUp: @escaping SpellingSuggester.LookUp, checker: any SpellingSuggesting,
        language: @escaping @Sendable () -> String? = { SpellingLanguage.readers(Locale.preferredLanguages) },
        forms: @escaping @Sendable () -> FormTable? = { FormAuthority.shared.table },
        now: () -> ContinuousClock.Instant = { .now }, write: (String) -> Bool,
        writeError: (String) -> Void = LookupCommand.writeError
    ) async -> CommandStatus {
        let suggester = SpellingSuggester(checker: checker, lookUp: lookUp, language: language, forms: forms)
        var status = CommandStatus.success
        for term in terms {
            let started = now()
            let outcome: LookupOutcome
            let offer: SpellingOffer
            do {
                outcome = try await lookUp(term)
                let looked = now()
                // The term's dictionary form as the card's lookup would work it out — alone, as a term on the command
                // line has no sentence, and with the table the suggester is given — so the instrument measures the
                // offer the card is made.
                let table = forms()
                let lemma = Lemmatizer.lemma(of: term, in: nil, at: nil, using: table)
                offer = try await suggester.offer(for: term, outcome: outcome, lemma: lemma)
                // **The form the suggester tried, where it tried one** — none for a word it was not asked about.
                let tried: DictionaryForm? = if case .refused = offer { nil } else {
                    DictionaryForm.candidate(lemma, for: term, printed: table)
                }
                let line = SpellingReportLine(term: term, outcome: outcome, offer: offer, dictionaryForm: tried,
                                              readersEnglish: language(), lookup: looked - started,
                                              suggestion: now() - looked)
                if let failed = LookupCommand.emit(line, through: write, writeError: writeError) { return failed }
            } catch {
                return .interrupted
            }
            if PanelCaveats.serviceUnanswered(outcome) { status = .failure }
        }
        return status
    }
}

/// One term, as `--spelling-report` reports it. Fields that do not apply are left out.
struct SpellingReportLine: Encodable, Equatable {
    let term: String
    /// The term's own lookup, in `--lookup`'s words: `entries` | `plainText` | `notFound`.
    let outcome: String
    /// `offered` | `refused` | `noCorrection` | `unverified` — `SpellingOffer`'s cases.
    let offer: String
    /// Why nothing was asked, where nothing was: `SpellingEligibility.Refusal`'s name.
    var refusal: String?
    /// The checker's word: the one offered, or the one no dictionary of the reader's has.
    var correction: String?
    /// What an offered word is to the term: `spelling` | `dictionaryForm` (plan-card-refinements WI-3).
    var correctionKind: String?
    /// The term's dictionary form the suggester tried first, offered or not — absent where it had none. What tells "this
    /// Mac's dictionaries give the term no form" from "the form could not be verified" (the owner's order, 2026-10-09).
    var dictionaryForm: String?
    /// What makes that form the term's: `printed` | `regular` (`DictionaryForm.Evidence`, D1 of 2026-10-10) — the
    /// provenance of a dictionary-form offer, which the card does not draw and a measurement of the guards needs.
    var dictionaryFormEvidence: String?
    /// The reader's English the checker was asked in, as they list it; absent where they list none (plain English).
    var readersEnglish: String?
    let lookupMilliseconds: Double
    let suggestionMilliseconds: Double

    init(term: String, outcome: LookupOutcome, offer: SpellingOffer, dictionaryForm: DictionaryForm? = nil,
         readersEnglish: String?, lookup: Duration, suggestion: Duration) {
        self.term = term
        self.dictionaryForm = dictionaryForm?.word
        dictionaryFormEvidence = switch dictionaryForm?.evidence {
        case .printed?: "printed"
        case .regular?: "regular"
        case nil: nil
        }
        switch outcome {
        case .entries: self.outcome = "entries"
        case .plainText: self.outcome = "plainText"
        case .notFound: self.outcome = "notFound"
        }
        switch offer {
        case .offered(let suggestion):
            self.offer = "offered"
            correction = suggestion.word
            correctionKind = suggestion.kind.rawValue
        case .refused(let why):
            self.offer = "refused"
            refusal = why.rawValue
        case .noCorrection:
            self.offer = "noCorrection"
        case .unverified(let word):
            self.offer = "unverified"
            correction = word
        }
        self.readersEnglish = readersEnglish
        lookupMilliseconds = lookup.milliseconds.rounded()
        suggestionMilliseconds = suggestion.milliseconds.rounded()
    }
}
