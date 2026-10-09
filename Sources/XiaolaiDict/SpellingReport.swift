import DictionaryModel
import Foundation
import XiaolaiDictBase
import XiaolaiDictCore

/// `--spelling-report TERM…`: **what each term's miss would be offered** — "Did you mean …?" — through the checker and
/// the dictionaries the card is offered it by, one JSON line a term (plan-spelling-suggestion §3).
///
/// Each term is looked up as `--lookup` looks it up, then asked of `SpellingSuggester` — the one the lookup runner asks
/// — so the instrument measures what the card is offered, not a second implementation of it. **What it prints is the
/// term, kinds, the checker's word and two durations**: never a definition, a headword or a dictionary's name, which
/// are licensed text a shell has no business printing.
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
        let client = DictionaryClient()
        return await run(terms: terms, lookUp: { term throws(CancellationError) in try await client.lookup(term) },
                         checker: SystemSpellChecker(), write: LookupCommand.writeLine)
#endif
    }

    /// The report for `terms`, through `lookUp` and `checker`, written through `write`. **`.failure` where the service
    /// could not answer a term**: that miss was not the dictionaries' answer, so what it was offered says nothing about
    /// them — the line is still written, and the exit says so.
    static func run(
        terms: [String], lookUp: @escaping SpellingSuggester.LookUp, checker: any SpellingSuggesting,
        language: @escaping @Sendable () -> String? = { SpellingLanguage.readers(Locale.preferredLanguages) },
        now: () -> ContinuousClock.Instant = { .now }, write: (String) -> Bool
    ) async -> CommandStatus {
        let suggester = SpellingSuggester(checker: checker, lookUp: lookUp, language: language)
        var status = CommandStatus.success
        for term in terms {
            let started = now()
            let outcome: LookupOutcome
            let offer: SpellingOffer
            do {
                outcome = try await lookUp(term)
                let looked = now()
                offer = try await suggester.offer(for: term, outcome: outcome)
                let line = SpellingReportLine(term: term, outcome: outcome, offer: offer, readersEnglish: language(),
                                              lookup: looked - started, suggestion: now() - looked)
                if let failed = LookupCommand.emit(line, through: write) { return failed }
            } catch {
                return .interrupted
            }
            if case .refused(.serviceUnanswered) = offer { status = .failure }
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
    /// The reader's English the checker was asked in, as they list it; absent where they list none (plain English).
    var readersEnglish: String?
    let lookupMilliseconds: Double
    let suggestionMilliseconds: Double

    init(term: String, outcome: LookupOutcome, offer: SpellingOffer, readersEnglish: String?,
         lookup: Duration, suggestion: Duration) {
        self.term = term
        switch outcome {
        case .entries: self.outcome = "entries"
        case .plainText: self.outcome = "plainText"
        case .notFound: self.outcome = "notFound"
        }
        switch offer {
        case .offered(let suggestion):
            self.offer = "offered"
            correction = suggestion.word
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
