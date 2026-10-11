import DictionaryModel
import Foundation
import Testing
import XiaolaiDictCore

/// **A form offered only by regular spelling is tentative, and it does not silence the checker** (the owner's delegate,
/// 2026-10-11 — ADR-0054 part B). What the dictionaries print reads as before; what is inferred from English spelling
/// alone says so on the card, and where the checker's verified correction is another word, the reader is offered both —
/// each a tap, neither looked up in their place.
///
/// The case that decided it: *cursting*. *curst* is an adjective in NOAD, so the conversion rule licenses *-ing*, and
/// nothing this rule reads prints *curst* as *curse*'s archaic past — the regular rule offered *curst* and displaced the
/// checker's verified *cursing*, which is likelier what the reader met.
struct TentativeDictionaryFormTests {
    typealias Checker = SpellingSuggesterTests.Checker
    typealias Dictionaries = SpellingSuggesterTests.Dictionaries
    typealias Headed = Dictionaries.Headed
    private static let miss = LookupOutcome.notFound(serviceFailure: nil)

    private static let lexicon: [String: [Headed]] = MeasuredDictionaries.lexicon.merging([
        "curst": [Headed("curst", ["adjective"])],
        "cursing": [Headed("cursing")],
    ]) { old, _ in old }

    private func offer(
        _ term: String, lemma form: String, checker: Checker,
        dictionaries: Dictionaries = Dictionaries(entries: Self.lexicon),
        printed: FormTable? = MeasuredDictionaries.noad
    ) async throws -> SpellingOffer {
        try await SpellingSuggester(
            checker: checker, lookUp: { term throws(CancellationError) in try dictionaries.lookUp(term) },
            language: { nil }, forms: { printed })
            .offer(for: term, outcome: Self.miss, lemma: Lemma(text: form, basis: .tagger))
    }

    /// **The regression**: *cursting* is offered *curst*, tentative, and the checker's verified *cursing* beside it.
    @Test func curstingIsOfferedCurstTentativelyBesideTheCheckersCorrection() async throws {
        let checker = Checker(["cursting": "cursing"]), dictionaries = Dictionaries(entries: Self.lexicon)
        let offered = try await offer("cursting", lemma: "curst", checker: checker, dictionaries: dictionaries)
        #expect(offered == .offered(
            SpellingSuggestion(term: "cursting", word: "curst", kind: .dictionaryForm, tentative: true),
            beside: SpellingSuggestion(term: "cursting", word: "cursing")))
        #expect(offered.suggestions.map(\.word) == ["curst", "cursing"], "the form first, the checker's word second")
        #expect(checker.questions == ["cursting"])
        #expect(dictionaries.questions == ["curst", "cursing"])
    }

    /// **A printed form is not tentative and the checker is not asked** — "a printed form outranks the checker" stands.
    @Test func aPrintedFormIsOfferedAloneAndNotTentative() async throws {
        for (term, form, wrong) in [("droughtier", "droughty", "doughtier"), ("glacises", "glacis", "glasses")] {
            let checker = Checker([term: wrong])
            let offered = try await offer(term, lemma: form, checker: checker)
            #expect(offered == .offered(SpellingSuggestion(term: term, word: form, kind: .dictionaryForm)), "\(term)")
            #expect(offered.suggestion?.isTentative == false, "\(term)")
            #expect(checker.questions.isEmpty, "\(term): the checker was asked")
        }
    }

    /// **A tentative form with no competing correction is offered alone** — no correction, one the dictionaries do not
    /// have, or the form itself again.
    @Test func aTentativeFormWithNoCompetingCorrectionIsOfferedAlone() async throws {
        let tentative = SpellingSuggestion(term: "cursting", word: "curst", kind: .dictionaryForm, tentative: true)
        for answers in [[:], ["cursting": "cursted"], ["cursting": "Curst"]] {
            let offered = try await offer("cursting", lemma: "curst", checker: Checker(answers))
            #expect(offered == .offered(tentative), "\(answers)")
        }
    }

    /// **The checker's word is never the first line**: a tentative form still comes first, and a typo with no form gets
    /// its correction alone, as before.
    @Test func aTypoWithNoFormIsOfferedItsCorrectionAlone() async throws {
        let offered = try await offer("recieve", lemma: "recieve", checker: Checker(["recieve": "receive"]))
        #expect(offered == .offered(SpellingSuggestion(term: "recieve", word: "receive")))
        #expect(offered.suggestion?.isTentative == false)
    }

    /// **Cancelled after the form is borne out, the competing correction is not looked up**: a superseded lookup costs
    /// the service nothing more.
    @Test func aCancelledOfferDoesNotLookUpTheCompetingCorrection() async throws {
        let dictionaries = Dictionaries(entries: Self.lexicon)
        let task = Task {
            try await offer("cursting", lemma: "curst",
                            checker: Checker(["cursting": "cursing"]) { withUnsafeCurrentTask { $0?.cancel() } },
                            dictionaries: dictionaries)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(dictionaries.questions == ["curst"])
    }
}
