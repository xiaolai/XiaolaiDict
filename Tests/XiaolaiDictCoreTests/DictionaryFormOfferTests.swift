import DictionaryModel
import Testing
import XiaolaiDictBase
import XiaolaiDictCore

/// **"Look up “run”" — the dictionary form offered as a tap under a miss** (plan-card-refinements WI-3, the
/// owner's D3: offered, never substituted).
///
/// Measured first (§6): the dictionaries already answer most inflections, and of the forms that still miss, the app's
/// own lemma recovered 1,221 of 6,228, wrong in at most 2.69% of the inflected ones at 95% — too many to swap in
/// silently, and a line the reader may ignore. WI-3 put the spelling line first; the owner reversed that on
/// 2026-10-09, after the checker's word for four real inflections was wrong on the E2E Mac, and the ruling of
/// 2026-10-11 made it one offer chosen by evidence — see `SpellingArbitrationTests`.
struct DictionaryFormOfferTests {
    private typealias Checker = SpellingSuggesterTests.Checker
    private typealias Dictionaries = SpellingSuggesterTests.Dictionaries
    private static let miss = LookupOutcome.notFound(serviceFailure: nil)

    private typealias Headed = Dictionaries.Headed

    /// **No form table**, as a test process has (`FormAuthority` is never installed in one), unless a test names one.
    private func suggester(_ checker: Checker, _ dictionaries: Dictionaries, printed: FormTable? = nil) -> SpellingSuggester {
        SpellingSuggester(checker: checker, lookUp: { term throws(CancellationError) in try dictionaries.lookUp(term) },
                          language: { nil }, forms: { printed })
    }

    @Test func aVerifiedDictionaryFormIsOfferedWhereTheCheckerHasNothing() async throws {
        let offer = try await suggester(Checker([:]), Dictionaries(entries: ["luncheon": [Headed("luncheon", ["noun"])]]))
            .offer(for: "luncheoning", outcome: Self.miss, lemma: Lemma(text: "luncheon", basis: .tagger))
        #expect(offer == .offered(SpellingSuggestion(term: "luncheoning", word: "luncheon", evidence: .regular(.ing))))
    }

    /// **A regular form and the checker's word for the same slot of the same base are one offer** (the owner's ruling of
    /// 2026-10-11): *gazeboes* is printed nowhere here, the checker says *gazebos*, and both are *gazebo*'s plural — so
    /// *gazebo* is offered, once.
    @Test func aRegularFormAndTheCheckersPluralOfItAgree() async throws {
        let dictionaries = Dictionaries(entries: ["gazebo": [Headed("gazebo", ["noun"])], "gazebos": [Headed("gazebos")]])
        let checker = Checker(["gazeboes": "gazebos"])
        let offer = try await suggester(checker, dictionaries)
            .offer(for: "gazeboes", outcome: Self.miss, lemma: Lemma(text: "gazebo", basis: .tagger))
        #expect(offer == .offered(SpellingSuggestion(term: "gazeboes", word: "gazebo", evidence: .agreement(.s))))
        #expect(dictionaries.questions == ["gazebo", "gazebos"])
        #expect(checker.questions == ["gazeboes"])
    }

    /// **A lemma the term is no inflection of gives way to the checker** (D1, 2026-10-10): *concreti* is an OCR typo,
    /// not *concret* or *concrete* inflected, so the checker's verified *concrete* is offered and the lemma is never
    /// looked up. It was the broad rule's offer, and one of the spike's eight that both labels called wrong.
    @Test func aLemmaTheTermIsNoInflectionOfGivesWayToTheChecker() async throws {
        let dictionaries = Dictionaries(entries: ["concrete": [Headed("concrete", ["noun", "adjective", "verb"])],
                                                  "concret": [Headed("concret", ["noun"])]])
        let checker = Checker(["concreti": "concrete"])
        let offer = try await suggester(checker, dictionaries)
            .offer(for: "concreti", outcome: Self.miss, lemma: Lemma(text: "concret", basis: .tagger))
        #expect(offer == .offered(SpellingSuggestion(term: "concreti", word: "concrete", evidence: .correction(.substitution))))
        #expect(dictionaries.questions == ["concrete"])
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
    /// useful one. **An irregular only where the dictionaries print it** (D1): it is no regular inflection.
    @Test func aLikelyLemmaIsOffered() async throws {
        let printed = FormTable(sources: [], forms: ["sawz": [.init(lemma: "see", partOfSpeech: "verb")]], ownHeadwords: [])
        let dictionaries = Dictionaries(entries: ["see": [Headed("see", ["verb"])]])
        let offer = try await suggester(Checker([:]), dictionaries, printed: printed)
            .offer(for: "sawz", outcome: Self.miss, lemma: Lemma(text: "see", basis: .likely))
        #expect(offer == .offered(SpellingSuggestion(term: "sawz", word: "see", evidence: .printed)))
        let unprinted = try await suggester(Checker([:]), dictionaries)
            .offer(for: "sawz", outcome: Self.miss, lemma: Lemma(text: "see", basis: .likely))
        #expect(unprinted.suggestion == nil)
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
}
