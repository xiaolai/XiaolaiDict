import CaptureModel
import DictionaryModel
import Foundation
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictUI

/// `--spelling-report TERM…`: **what each term's miss would be offered** — "Look up “X”" or nothing — through the checker
/// and the dictionaries the card is offered it by, one JSON line a term (plan-spelling-suggestion §3).
///
/// Each term is looked up as `--lookup` looks it up, then asked of `SpellingSuggester` — the one the lookup runner asks
/// — so the instrument measures what the card is offered, not a second implementation of it. **What it prints is the
/// term, both candidates — the term's dictionary form and the checker's word — with whether the dictionaries bore each
/// out and how far each is from the term, the rule that decided, and two durations**, even where nothing is offered
/// (the owner's ruling of 2026-10-11): never a definition, a headword or a dictionary's name, which are licensed text a
/// shell has no business printing.
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
        // decided with it (plan-card-refinements WI-3), and without it a term alone has only the tagger's lemma. Waited
        // for where the service is still building it, and said where it never came (`awaitFormTable`).
        let client = DictionaryClient()
        let store = FormTableStore()
        let table = await awaitFormTable(read: { store.read() }, startService: { _ = try? await client.lookup("the") },
                                         within: .seconds(120), every: .seconds(1))
        if table == nil {
            LookupCommand.writeError("spelling-report: no form table after 120 s, so each term has the tagger's lemma alone")
        }
        FormAuthority.shared.use(store)
        return await run(terms: terms, lookUp: { term throws(CancellationError) in try await client.lookup(term) },
                         checker: SystemSpellChecker(), write: LookupCommand.writeLine)
#endif
    }

    /// **The reader's form table, waited for where the service is still building it** (2026-10-10). A new table format
    /// refuses the stored one, and the dictionary service rebuilds it in the background once a lookup starts it — about
    /// 30 s on the Macs measured — so a report made straight after installing such a build measured the offers with no
    /// table, and the lookup stage read the guards as having lost *heavy* for *heavied*. Read; where there is none, the
    /// service started once and the store read again until it answers or `within` runs out. Nil at the deadline.
    static func awaitFormTable(read: () -> FormTable?, startService: () async -> Void, within: Duration,
                               every interval: Duration) async -> FormTable? {
        if let table = read() { return table }
        await startService()
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: interval)
            if let table = read() { return table }
        }
        return nil
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
            do {
                outcome = try await lookUp(term)
                let looked = now()
                // The term's dictionary form as the card's lookup would work it out — alone, as a term on the command
                // line has no sentence, and with the table the suggester is given — so the instrument measures the
                // offer the card is made. **Typed, so no capture source**: the same thresholds hold for every source.
                let lemma = Lemmatizer.lemma(of: term, in: nil, at: nil, using: forms())
                let decision = try await suggester.decide(for: term, outcome: outcome, lemma: lemma, capture: nil)
                let line = SpellingReportLine(outcome: outcome, decision: decision, readersEnglish: language(),
                                              lookup: looked - started, suggestion: now() - looked)
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
    /// How the term was captured — `CaptureQuality.Source`'s name — or `typed` for one named rather than captured, as
    /// every term on the command line is. Recorded, never weighed.
    let captureSource: String
    /// `offered` | `refused` | `abstained` — `SpellingOffer`'s cases.
    let offer: String
    /// **The rule that decided** (`SpellingDecision.rule`): the offered evidence — `printed`, `regular`, `agreement`,
    /// `correction` — `refused`, or the abstention's name.
    let rule: String
    /// Why nothing was asked, where nothing was: `SpellingEligibility.Refusal`'s name.
    var refusal: String?
    /// The one word offered, where one was.
    var suggestion: String?
    /// The term's dictionary form a rule proposed, offered or not: `dictionaryFormEvidence` says which rule —
    /// `printed` | `regular` — and the slot where regular.
    var dictionaryForm: String?
    var dictionaryFormEvidence: String?
    var dictionaryFormSlot: String?
    /// Whether the form's lookup bore it out; absent where it was never looked up.
    var dictionaryFormSupported: Bool?
    var dictionaryFormDistance: Int?
    /// The base the lemmatiser proposed, kept for the ambiguity guards whether or not a rule made it a form.
    var proposedBase: String?
    /// The checker's word, offered or not, with whether the dictionaries have it, its distance and its one edit.
    var correction: String?
    var correctionVerified: Bool?
    var correctionDistance: Int?
    var correctionEdit: String?
    /// The reader's English the checker was asked in, as they list it; absent where they list none (plain English).
    var readersEnglish: String?
    let lookupMilliseconds: Double
    let suggestionMilliseconds: Double

    init(outcome: LookupOutcome, decision: SpellingDecision, readersEnglish: String?, lookup: Duration,
         suggestion duration: Duration) {
        term = decision.term
        switch outcome {
        case .entries: self.outcome = "entries"
        case .plainText: self.outcome = "plainText"
        case .notFound: self.outcome = "notFound"
        }
        captureSource = decision.capture?.rawValue ?? "typed"
        rule = decision.rule
        switch decision.offer {
        case .offered(let offered):
            offer = "offered"
            suggestion = offered.word
        case .refused(let why):
            offer = "refused"
            refusal = why.rawValue
        case .abstained:
            offer = "abstained"
        }
        if let form = decision.form {
            dictionaryForm = form.word
            switch form.evidence {
            case .printed: dictionaryFormEvidence = "printed"
            case .regular(let slot):
                dictionaryFormEvidence = "regular"
                dictionaryFormSlot = slot.rawValue
            }
            dictionaryFormSupported = form.supported
            dictionaryFormDistance = form.edit.distance
        }
        proposedBase = decision.proposedBase
        if let checked = decision.correction {
            correction = checked.word
            correctionVerified = checked.verified
            correctionDistance = checked.edit.distance
            correctionEdit = checked.edit.operation?.rawValue
        }
        self.readersEnglish = readersEnglish
        lookupMilliseconds = lookup.milliseconds.rounded()
        suggestionMilliseconds = duration.milliseconds.rounded()
    }
}
