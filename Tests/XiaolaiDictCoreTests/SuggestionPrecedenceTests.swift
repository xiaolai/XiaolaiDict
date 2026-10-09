import DictionaryModel
import Testing
import XiaolaiDictCore

/// **A verified dictionary form outranks the spell checker** (plan-card-refinements §6, the owner's decision of
/// 2026-10-09).
///
/// Measured on the E2E Mac after WI-3: the checker turned real inflections the dictionaries know into other words —
/// *dalesmen* into *salesmen*, *droughtier* into *doughtier*, *heavied* into *heavier*, *glacises* into *glasses* — and
/// each of those words verified, so each miss was offered "Did you mean" a word the reader never read. Where the
/// term's dictionary form exists (WI-3's candidate) and the dictionaries verify it, it is offered and the checker is
/// not.
///
/// **What it costs, measured**: of the WI-3 spike's 1,221 recoveries, 53 had a verified correction from the checker
/// that this order no longer offers, 49 of them OCR-typo controls (`penetrateed` is now "as *penetrate*", not "did you
/// mean *penetrated*"). The owner's rule, taken knowingly; a typo with no dictionary form still gets its correction.
struct SuggestionPrecedenceTests {
    /// The four, as measured, with the form each inflects and what the E2E Mac's checker made of it.
    static let measured: [(term: String, form: String, checker: String)] = [
        ("dalesmen", "dalesman", "salesmen"),
        ("droughtier", "droughty", "doughtier"),
        ("heavied", "heavy", "heavier"),
        ("glacises", "glacis", "glasses"),
    ]

    @Test func aDictionaryFormComesFirst() {
        for (_, form, _) in Self.measured {
            #expect(SuggestionPrecedence.of(dictionaryForm: form) == .dictionaryFormFirst, "\(form)")
        }
    }

    /// **The positive control: with no dictionary form, the checker comes first** — `recieve` has none.
    @Test func withNoDictionaryFormTheCheckerComesFirst() {
        #expect(SuggestionPrecedence.of(dictionaryForm: nil) == .spellingFirst)
    }

    @Test func theOrderIsTheDecision() {
        #expect(SuggestionPrecedence.dictionaryFormFirst.order == [.dictionaryForm, .spelling])
        #expect(SuggestionPrecedence.spellingFirst.order == [.spelling, .dictionaryForm])
    }
}

/// **The same decision, through the one path to a suggestion** — `SpellingSuggester`, which the lookup runner and
/// `--spelling-report` both ask.
struct DictionaryFormPrecedenceTests {
    private typealias Checker = SpellingSuggesterTests.Checker
    private typealias Dictionaries = SpellingSuggesterTests.Dictionaries
    private static let miss = LookupOutcome.notFound(serviceFailure: nil)

    private func suggester(_ checker: Checker, _ dictionaries: Dictionaries) -> SpellingSuggester {
        SpellingSuggester(checker: checker, lookUp: { term throws(CancellationError) in try dictionaries.lookUp(term) },
                          language: { nil })
    }

    /// **Each of the four is offered its dictionary form, and the checker's word is neither offered nor asked about**
    /// — the dictionaries have both words, as they did on the E2E Mac, so only the order decides.
    @Test func eachOfTheFourIsOfferedItsDictionaryFormNotTheCheckersWord() async throws {
        for (term, form, wrong) in SuggestionPrecedenceTests.measured {
            let checker = Checker([term: wrong]), dictionaries = Dictionaries([form, wrong])
            let offer = try await suggester(checker, dictionaries)
                .offer(for: term, outcome: Self.miss, lemma: Lemma(text: form, basis: .inferred))
            #expect(offer == .offered(SpellingSuggestion(term: term, word: form, kind: .dictionaryForm)))
            #expect(dictionaries.questions == [form], "\(term): the checker's word was looked up")
            #expect(checker.questions.isEmpty, "\(term): the checker was asked once the dictionary form had answered")
        }
    }

    /// **The positive control: a typo with no dictionary form is still offered the checker's correction.**
    @Test func aTypoIsStillOfferedTheCheckersCorrection() async throws {
        let checker = Checker(["recieve": "receive"]), dictionaries = Dictionaries(["receive"])
        let offer = try await suggester(checker, dictionaries)
            .offer(for: "recieve", outcome: Self.miss, lemma: Lemma(text: "recieve", basis: .surface))
        #expect(offer == .offered(SpellingSuggestion(term: "recieve", word: "receive")))
        #expect(checker.questions == ["recieve"])
        #expect(dictionaries.questions == ["receive"])
    }

    /// **A dictionary form the dictionaries cannot verify gives way to the checker**, and is not asked about twice.
    @Test func anUnverifiedDictionaryFormFallsBackToTheChecker() async throws {
        let checker = Checker(["dalesmen": "salesmen"]), dictionaries = Dictionaries(["salesmen"])
        let offer = try await suggester(checker, dictionaries)
            .offer(for: "dalesmen", outcome: Self.miss, lemma: Lemma(text: "dalesman", basis: .inferred))
        #expect(offer == .offered(SpellingSuggestion(term: "dalesmen", word: "salesmen")))
        #expect(dictionaries.questions == ["dalesman", "salesmen"])
    }

    /// Neither verified: the checker's word is what the instrument names, as before.
    @Test func neitherVerifiedNamesTheCheckersWord() async throws {
        let checker = Checker(["dalesmen": "salesmen"]), dictionaries = Dictionaries([])
        let offer = try await suggester(checker, dictionaries)
            .offer(for: "dalesmen", outcome: Self.miss, lemma: Lemma(text: "dalesman", basis: .inferred))
        #expect(offer == .unverified("salesmen"))
        #expect(dictionaries.questions == ["dalesman", "salesmen"])
    }

    /// **Cancelled before the first lookup, nothing is asked of the dictionaries** — the dictionary form's lookup is
    /// the first, so the rule that a superseded lookup costs the service nothing holds in this order too.
    @Test func aCancelledOfferAsksTheDictionariesNothing() async throws {
        let dictionaries = Dictionaries(["dalesman"])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await suggester(Checker([:]), dictionaries)
                .offer(for: "dalesmen", outcome: Self.miss, lemma: Lemma(text: "dalesman", basis: .inferred))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(dictionaries.questions.isEmpty)
    }
}
