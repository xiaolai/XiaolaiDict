import DictionaryModel
import Testing
import XiaolaiDictBase
import XiaolaiDictCore

/// **"Look up “ran” as “run”?" — the dictionary form offered as a tap under a miss** (plan-card-refinements WI-3, the
/// owner's D3: offered, never substituted).
///
/// Measured first (§6): the dictionaries already answer most inflections, and of the forms that still miss, the app's
/// own lemma recovered 1,221 of 6,228, wrong in at most 2.69% of the inflected ones at 95% — too many to swap in
/// silently, and a line the reader may ignore. The spelling line comes first: the checker's correction is the better
/// answer for a typo, and a typo reaching the lemma path was the larger part of the wrong recoveries.
struct DictionaryFormOfferTests {
    private typealias Checker = SpellingSuggesterTests.Checker
    private typealias Dictionaries = SpellingSuggesterTests.Dictionaries
    private static let miss = LookupOutcome.notFound(serviceFailure: nil)

    private func suggester(_ checker: Checker, _ dictionaries: Dictionaries) -> SpellingSuggester {
        SpellingSuggester(checker: checker, lookUp: { term throws(CancellationError) in try dictionaries.lookUp(term) },
                          language: { nil })
    }

    @Test func aVerifiedDictionaryFormIsOfferedWhereTheCheckerHasNothing() async throws {
        let offer = try await suggester(Checker([:]), Dictionaries(["luncheon"]))
            .offer(for: "luncheoning", outcome: Self.miss, lemma: Lemma(text: "luncheon", basis: .tagger))
        #expect(offer == .offered(SpellingSuggestion(term: "luncheoning", word: "luncheon", kind: .dictionaryForm)))
    }

    /// **The spelling line outranks it**: a correction the dictionaries have is offered, and the lemma is not asked.
    @Test func aSpellingCorrectionComesFirst() async throws {
        let dictionaries = Dictionaries(["concrete", "concret"])
        let offer = try await suggester(Checker(["concreti": "concrete"]), dictionaries)
            .offer(for: "concreti", outcome: Self.miss, lemma: Lemma(text: "concret", basis: .tagger))
        #expect(offer == .offered(SpellingSuggestion(term: "concreti", word: "concrete")))
        #expect(dictionaries.questions == ["concrete"], "the lemma was asked after a correction was offered")
    }

    /// **Never a guess the lemmatiser itself does not stand by, the word again, or a form the dictionaries lack.**
    @Test func nothingIsOfferedForAnUnsureOrUnverifiedOrSameLemma() async throws {
        let cases: [(Lemma, Set<String>)] = [
            (Lemma(text: "lie", basis: .ambiguous), ["lie"]),
            (Lemma(text: "zork", basis: .surface), ["zork"]),
            (Lemma(text: "Zorks", basis: .tagger), ["Zorks"]),
            (Lemma(text: "zork", basis: .tagger), []),
        ]
        for (lemma, words) in cases {
            let offer = try await suggester(Checker([:]), Dictionaries(words))
                .offer(for: "zorks", outcome: Self.miss, lemma: lemma)
            #expect(offer.suggestion == nil, "\(lemma) was offered")
        }
    }

    /// The likely reading of an irregular — `saw` as `see` — is offered: it is a tap, and the usual reading is the
    /// useful one.
    @Test func aLikelyLemmaIsOffered() async throws {
        let offer = try await suggester(Checker([:]), Dictionaries(["see"]))
            .offer(for: "sawz", outcome: Self.miss, lemma: Lemma(text: "see", basis: .likely))
        #expect(offer.suggestion?.kind == .dictionaryForm)
    }

    /// **Only under the service's own miss of one Latin word** — the same eligibility as the spelling line, so a found
    /// word, a service failure or a phrase is never second-guessed.
    @Test func theSameEligibilityHolds() async throws {
        let dictionaries = Dictionaries(["run"])
        let lemma = Lemma(text: "run", basis: .tagger)
        for (term, outcome) in [("ran", LookupOutcome.notFound(serviceFailure: "crashed")), ("ran away", Self.miss)] {
            let offer = try await suggester(Checker([:]), dictionaries).offer(for: term, outcome: outcome, lemma: lemma)
            #expect(offer.suggestion == nil)
        }
        #expect(dictionaries.questions.isEmpty)
    }

    /// **A found or unreadable answer never changes**: whatever the lemma, an answer is not second-guessed and the
    /// dictionaries are asked nothing more.
    @Test func aFoundOrUnreadableAnswerIsNeverSecondGuessed() async throws {
        let entry = DictionaryEntry(dictionary: DictionaryIdentity(name: "NOAD", identifier: "noad"),
                                    headword: "ran", lookedUp: "ran", html: "<p/>", document: nil)
        let answers: [LookupOutcome] = [
            .entries(NonEmpty([entry])!, unreadable: []), .entries(NonEmpty([entry])!, unreadable: ["NOAD"]),
            .plainText("prose", serviceFailure: "crashed"),
        ]
        for outcome in answers {
            let dictionaries = Dictionaries(["run"])
            let offer = try await suggester(Checker(["ran": "run"]), dictionaries)
                .offer(for: "ran", outcome: outcome, lemma: Lemma(text: "run", basis: .inferred))
            #expect(offer == .refused(.notAMiss))
            #expect(dictionaries.questions.isEmpty)
        }
    }

    @Test func aSpellingSuggestionIsItsOwnKindByDefault() {
        #expect(SpellingSuggestion(term: "teh", word: "the").kind == .spelling)
    }
}
