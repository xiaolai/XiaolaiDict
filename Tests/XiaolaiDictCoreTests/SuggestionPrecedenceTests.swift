import DictionaryModel
import Foundation
import Testing
import XiaolaiDictCore

/// **A defensible dictionary form outranks the spell checker** (plan-card-refinements §6: the owner's decision of
/// 2026-10-09, narrowed by D1 of 2026-10-10 — ADR-0054).
///
/// Measured on the E2E Mac after WI-3: the checker turned real inflections the dictionaries know into other words —
/// *dalesmen* into *salesmen*, *droughtier* into *doughtier*, *heavied* into *heavier*, *glacises* into *glasses* — and
/// each of those words verified, so each miss was offered "Did you mean" a word the reader never read. Where the term
/// has a dictionary form (`DictionaryForm.candidate`), it is tried first.
///
/// **What the broad rule cost, and why it is guarded** (D1): of the WI-3 spike's 1,221 recoveries, 53 had a verified
/// correction from the checker that a bare lemma displaced, and 55 of the labelled ones were wrong — *prideed* as
/// *pride*, *Frances* as *france*. A lemma the dictionaries have is not a relationship to the term, so the form is
/// offered only where the term is printed as its inflection or is its regular inflection by English spelling, licensed
/// by the form's own entry (`DictionaryFormGuardTests`).
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

/// **The dictionaries the decision was measured against**, as the suggester sees them: each word with its entries'
/// headwords and parts of speech, and what the dictionaries print as inflections (`FormTable`). Measured 2026-10-10 on
/// the development Mac through the dictionary service; NOAD's printed inflections are the E2E Mac's whole form table
/// (NOAD and the Writer's Thesaurus, which prints none of these).
enum MeasuredDictionaries {
    typealias Headed = SpellingSuggesterTests.Dictionaries.Headed

    /// NOAD, the Writer's Thesaurus and the two Oxford bilinguals, for the four words and the checker's four.
    static let lexicon: [String: [Headed]] = [
        "heavy": [Headed("heavy", ["adjective", "noun", "adverb"]), Headed("heavy", ["adjective"])],
        "droughty": [Headed("droughty", ["adjective"])],
        "glacis": [Headed("glacis", ["noun"])],
        "dalesman": [Headed("dalesman", ["noun"])],
        "pride": [Headed("pride", ["noun", "verb"]), Headed("pride", ["noun", "reflexive verb"])],
        "france": [Headed("France", ["proper noun"]), Headed("France", [""])],
        "receive": [Headed("receive", ["verb"])],
        "prided": [Headed("prided")],
        "heavier": [Headed("heavier")], "doughtier": [Headed("doughtier")],
        "glasses": [Headed("glasses")], "salesmen": [Headed("salesmen")],
    ]

    /// **What NOAD prints** under the four words' forms (`class="inf"`), read off its entries on 2026-10-10: it prints
    /// *droughtier* and *glacises*, and neither *heavied* nor *dalesmen*.
    static let noad = FormTable(sources: [], forms: [
        "heavier": [.init(lemma: "heavy", partOfSpeech: "adjective")],
        "heaviest": [.init(lemma: "heavy", partOfSpeech: "adjective")],
        "heavies": [.init(lemma: "heavy", partOfSpeech: "noun")],
        "droughtier": [.init(lemma: "droughty", partOfSpeech: "adjective")],
        "droughtiest": [.init(lemma: "droughty", partOfSpeech: "adjective")],
        "glacises": [.init(lemma: "glacis", partOfSpeech: "noun")],
    ], ownHeadwords: [])

    /// The development Mac's table, which also reads the *Oxford Dictionary of English*: it prints *dalesmen* and
    /// *heavied* (the 2026-10-09 record).
    static let withODE = FormTable(sources: [], forms: [
        "dalesmen": [.init(lemma: "dalesman", partOfSpeech: "noun")],
        "heavied": [.init(lemma: "heavy", partOfSpeech: "verb")],
        "droughtier": [.init(lemma: "droughty", partOfSpeech: "adjective")],
        "glacises": [.init(lemma: "glacis", partOfSpeech: "noun")],
    ], ownHeadwords: [])
}

/// **The same decision, through the one path to a suggestion** — `SpellingSuggester`, which the lookup runner and
/// `--spelling-report` both ask.
struct DictionaryFormPrecedenceTests {
    private typealias Checker = SpellingSuggesterTests.Checker
    private typealias Dictionaries = SpellingSuggesterTests.Dictionaries
    private static let miss = LookupOutcome.notFound(serviceFailure: nil)

    private func suggester(_ checker: Checker, _ dictionaries: Dictionaries, printed: FormTable?) -> SpellingSuggester {
        SpellingSuggester(checker: checker, lookUp: { term throws(CancellationError) in try dictionaries.lookUp(term) },
                          language: { nil }, forms: { printed })
    }

    /// **On the development Mac's dictionaries each of the four is offered its dictionary form, and the checker's word
    /// is neither offered nor asked about** — the dictionaries have both words, so only the order decides.
    @Test func eachOfTheFourIsOfferedItsDictionaryFormNotTheCheckersWord() async throws {
        for (term, form, wrong) in SuggestionPrecedenceTests.measured {
            let checker = Checker([term: wrong]), dictionaries = Dictionaries(entries: MeasuredDictionaries.lexicon)
            let offer = try await suggester(checker, dictionaries, printed: MeasuredDictionaries.withODE)
                .offer(for: term, outcome: Self.miss, lemma: Lemma(text: form, basis: .inferred))
            #expect(offer == .offered(SpellingSuggestion(term: term, word: form, kind: .dictionaryForm)))
            #expect(dictionaries.questions == [form], "\(term): the checker's word was looked up")
            #expect(checker.questions.isEmpty, "\(term): the checker was asked once the dictionary form had answered")
        }
    }

    /// **The positive control: a typo with no dictionary form is still offered the checker's correction.**
    @Test func aTypoIsStillOfferedTheCheckersCorrection() async throws {
        let checker = Checker(["recieve": "receive"]), dictionaries = Dictionaries(entries: MeasuredDictionaries.lexicon)
        let offer = try await suggester(checker, dictionaries, printed: MeasuredDictionaries.noad)
            .offer(for: "recieve", outcome: Self.miss, lemma: Lemma(text: "recieve", basis: .surface))
        #expect(offer == .offered(SpellingSuggestion(term: "recieve", word: "receive")))
        #expect(checker.questions == ["recieve"])
        #expect(dictionaries.questions == ["receive"])
    }

    /// **A dictionary form the dictionaries cannot verify gives way to the checker**, and is not asked about twice.
    @Test func anUnverifiedDictionaryFormFallsBackToTheChecker() async throws {
        let checker = Checker(["dalesmen": "salesmen"]), dictionaries = Dictionaries(["salesmen"])
        let offer = try await suggester(checker, dictionaries, printed: MeasuredDictionaries.withODE)
            .offer(for: "dalesmen", outcome: Self.miss, lemma: Lemma(text: "dalesman", basis: .inferred))
        #expect(offer == .offered(SpellingSuggestion(term: "dalesmen", word: "salesmen")))
        #expect(dictionaries.questions == ["dalesman", "salesmen"])
    }

    /// Neither verified: the checker's word is what the instrument names, as before.
    @Test func neitherVerifiedNamesTheCheckersWord() async throws {
        let checker = Checker(["dalesmen": "salesmen"]), dictionaries = Dictionaries([])
        let offer = try await suggester(checker, dictionaries, printed: MeasuredDictionaries.withODE)
            .offer(for: "dalesmen", outcome: Self.miss, lemma: Lemma(text: "dalesman", basis: .inferred))
        #expect(offer == .unverified("salesmen"))
        #expect(dictionaries.questions == ["dalesman", "salesmen"])
    }

    /// **Cancelled before the first lookup, nothing is asked of the dictionaries** — the dictionary form's lookup is
    /// the first, so the rule that a superseded lookup costs the service nothing holds in this order too.
    @Test func aCancelledOfferAsksTheDictionariesNothing() async throws {
        let dictionaries = Dictionaries(entries: MeasuredDictionaries.lexicon)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await suggester(Checker([:]), dictionaries, printed: MeasuredDictionaries.withODE)
                .offer(for: "dalesmen", outcome: Self.miss, lemma: Lemma(text: "dalesman", basis: .inferred))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(dictionaries.questions.isEmpty)
    }
}

/// **D1 (2026-10-10, ADR-0054): a dictionary form is offered first only where its relationship to the missed word is
/// defensible**, and otherwise the checker's verified correction is — through the real suggester, never automatically.
///
/// Defensible is one of two things, decided without a model: the reader's dictionaries **print** the term as the
/// form's inflection, or the term is the form's **regular** inflection by English spelling, the form prints nothing in
/// that slot to contradict it, the term is written in lowercase, and an entry headed by the form in lowercase has a
/// part of speech that inflects so (a noun or verb takes *-s*; a verb, noun or adjective *-ed* and *-ing*, since
/// English converts freely — *heavied*; an adjective or adverb *-er* and *-est*).
struct DictionaryFormGuardTests {
    typealias Checker = SpellingSuggesterTests.Checker
    typealias Dictionaries = SpellingSuggesterTests.Dictionaries
    typealias Headed = Dictionaries.Headed
    private static let miss = LookupOutcome.notFound(serviceFailure: nil)

    private func offer(
        _ term: String, lemma form: String, checker: Checker = Checker([:]),
        dictionaries: Dictionaries = Dictionaries(entries: MeasuredDictionaries.lexicon),
        printed: FormTable? = MeasuredDictionaries.noad
    ) async throws -> SpellingOffer {
        try await SpellingSuggester(
            checker: checker, lookUp: { term throws(CancellationError) in try dictionaries.lookUp(term) },
            language: { nil }, forms: { printed })
            .offer(for: term, outcome: Self.miss, lemma: Lemma(text: form, basis: .tagger))
    }

    // MARK: - The recoveries the decision keeps

    /// **On the E2E Mac's dictionaries** — NOAD alone prints its inflections there: *droughtier* and *glacises* are
    /// printed, and *heavied* is not, so it is kept as *heavy*'s regular past (an adjective, converted).
    @Test func theThreeRecoveriesAreKeptOnTheE2EMacsDictionaries() async throws {
        for (term, form, wrong) in [("heavied", "heavy", "heavier"), ("droughtier", "droughty", "doughtier"),
                                    ("glacises", "glacis", "glasses")] {
            let checker = Checker([term: wrong])
            let offered = try await offer(term, lemma: form, checker: checker)
            #expect(offered == .offered(SpellingSuggestion(term: term, word: form, kind: .dictionaryForm)), "\(term)")
            #expect(checker.questions.isEmpty, "\(term): the checker was asked")
        }
    }

    /// **And with nothing printed at all** — a reader whose form table is not read yet: each is still the regular
    /// inflection of a word whose entry licenses it.
    @Test func theThreeRecoveriesNeedNoPrintedForm() async throws {
        for (term, form) in [("heavied", "heavy"), ("droughtier", "droughty"), ("glacises", "glacis")] {
            let offered = try await offer(term, lemma: form, printed: nil)
            #expect(offered == .offered(SpellingSuggestion(term: term, word: form, kind: .dictionaryForm)), "\(term)")
        }
    }

    /// **A printed irregular is offered; an unprinted one is not** — *dalesmen* is no regular inflection of anything,
    /// so where the dictionaries do not print it (the E2E Mac) the checker's word stands, as it did there.
    @Test func anIrregularFormIsOfferedOnlyWherePrinted() async throws {
        let printed = try await offer("dalesmen", lemma: "dalesman", printed: MeasuredDictionaries.withODE)
        #expect(printed == .offered(SpellingSuggestion(term: "dalesmen", word: "dalesman", kind: .dictionaryForm)))
        let checker = Checker(["dalesmen": "salesmen"]), dictionaries = Dictionaries(entries: MeasuredDictionaries.lexicon)
        let unprinted = try await offer("dalesmen", lemma: "dalesman", checker: checker, dictionaries: dictionaries)
        #expect(unprinted == .offered(SpellingSuggestion(term: "dalesmen", word: "salesmen")))
        #expect(dictionaries.questions == ["salesmen"], "an indefensible form was looked up")
    }

    // MARK: - The rejections

    /// ***prideed* is not *pride*'s past** — *pride* takes *-d* — so the checker's verified *prided* is offered, and
    /// *pride* is never looked up.
    @Test func prideedIsNotOfferedPride() async throws {
        let checker = Checker(["prideed": "prided"]), dictionaries = Dictionaries(entries: MeasuredDictionaries.lexicon)
        let offered = try await offer("prideed", lemma: "pride", checker: checker, dictionaries: dictionaries)
        #expect(offered == .offered(SpellingSuggestion(term: "prideed", word: "prided")))
        #expect(dictionaries.questions == ["prided"])
    }

    /// ***Frances* is a name, not *France*'s plural** — a capitalised term is never read as a regular inflection, and
    /// *France* is a proper noun whose entry licenses none.
    @Test func francesIsNotOfferedFrance() async throws {
        let dictionaries = Dictionaries(entries: MeasuredDictionaries.lexicon)
        let offered = try await offer("Frances", lemma: "france", dictionaries: dictionaries)
        #expect(offered == .noCorrection)
        #expect(dictionaries.questions.isEmpty)
        // **The entry refuses it too**, written in lowercase: *France* heads no entry a plural could belong to.
        let lowercase = try await offer("frances", lemma: "france", dictionaries: dictionaries)
        #expect(lowercase == .noCorrection)
        #expect(dictionaries.questions == ["france"])
    }

    /// **Every unsafe class the decision names**, each refused with the checker's verified correction offered instead
    /// where it has one: a suffix spelled against English, a consonant doubled or not against the base, an *-ie* noun
    /// read as a *-y* adjective, and a name or abbreviation read as an inflection.
    @Test func everyUnsafeClassFallsBackToTheChecker() async throws {
        let cases: [(term: String, form: String, entries: [Headed], correction: String?)] = [
            ("gobes", "gob", [Headed("gob", ["noun", "intransitive verb"])], "goes"),
            ("tengees", "tenge", [Headed("tenge", ["noun"])], nil),
            ("propoundded", "propound", [Headed("propound", ["verb"])], "propounded"),
            ("tiped", "tip", [Headed("tip", ["noun", "verb"])], "tired"),
            ("hedgiest", "hedgie", [Headed("hedgie", ["noun"])], nil),
            ("preemiees", "preemie", [Headed("preemie", ["noun"])], nil),
            ("Hans", "han", [Headed("Han", ["noun"])], nil),
            ("Jos", "jo", [Headed("jo", ["noun"])], nil),
            ("hrses", "hrs", [Headed("hrs", ["abbreviation"])], "horses"),
        ]
        for (term, form, entries, correction) in cases {
            var lexicon: [String: [Headed]] = [form: entries]
            if let correction { lexicon[correction] = [Headed(correction)] }
            let checker = Checker(correction.map { [term: $0] } ?? [:])
            let offered = try await offer(term, lemma: form, checker: checker,
                                          dictionaries: Dictionaries(entries: lexicon), printed: nil)
            #expect(offered.suggestion?.kind != .dictionaryForm, "\(term) was offered \(form)")
            if let correction {
                #expect(offered == .offered(SpellingSuggestion(term: term, word: correction)), "\(term)")
            }
        }
    }

    /// **A form the dictionaries print a different way is refused** — *tip* prints *tipped*, so *tiped* is not its —
    /// and so is a lemma the table prints the term under no reading of: *judies* is printed under *judy*.
    @Test func whatTheDictionaryPrintsOutranksTheSpellingRules() async throws {
        let printed = FormTable(sources: [], forms: [
            "tipped": [.init(lemma: "tip", partOfSpeech: "verb")],
            "judies": [.init(lemma: "judy", partOfSpeech: "noun")],
        ], ownHeadwords: [])
        let dictionaries = Dictionaries(entries: ["tip": [Headed("tip", ["verb"])], "judie": [Headed("judie", ["noun"])]])
        #expect(try await offer("tiped", lemma: "tip", dictionaries: dictionaries, printed: printed).suggestion == nil)
        #expect(try await offer("judies", lemma: "judie", dictionaries: dictionaries, printed: printed).suggestion == nil)
        #expect(dictionaries.questions.isEmpty)
    }

    /// **A comparative and a superlative are different slots, and evidence for neither in particular is evidence
    /// against both** (audit of 2026-10-10). *many* prints *more* and *most* — irregular, no ending to tell them apart —
    /// and both were read as comparatives, so *maniest* stayed eligible as *many*'s regular superlative, against what
    /// the dictionary prints. A printed form whose slot cannot be told now blocks every slot it could be.
    @Test func anIrregularComparisonBlocksBothSlotsItCouldBe() async throws {
        let printed = FormTable(sources: [], forms: [
            "more": [.init(lemma: "many", partOfSpeech: "adjective")],
            "most": [.init(lemma: "many", partOfSpeech: "adjective")],
        ], ownHeadwords: [])
        let dictionaries = Dictionaries(entries: ["many": [Headed("many", ["determiner, pronoun, & adjective"])]])
        for term in ["maniest", "manier"] {
            let offered = try await offer(term, lemma: "many", dictionaries: dictionaries, printed: printed)
            #expect(offered.suggestion?.kind != .dictionaryForm, "\(term) was offered many")
        }
        #expect(dictionaries.questions.isEmpty, "a form the dictionary contradicts was looked up")
    }

    /// **The positive control: a printed form whose ending names its slot blocks that slot alone** — *red* prints
    /// *redder*, so *redderer* is nothing, and *reddest* is still *red*'s regular superlative.
    @Test func aPrintedComparativeLeavesTheSuperlativeOpen() async throws {
        let printed = FormTable(sources: [], forms: ["redder": [.init(lemma: "red", partOfSpeech: "adjective")]],
                                ownHeadwords: [])
        let dictionaries = Dictionaries(entries: ["red": [Headed("red", ["adjective", "noun"])]])
        let offered = try await offer("reddest", lemma: "red", dictionaries: dictionaries, printed: printed)
        #expect(offered == .offered(SpellingSuggestion(term: "reddest", word: "red", kind: .dictionaryForm)))
    }

    /// **Evidence that names no class and no ending is evidence against every slot** (second audit of 2026-10-10): the
    /// same *more* and *most* under *many*, printed under no part of speech, blocked nothing, and *manier* and *maniest*
    /// were offered *many*.
    @Test func anIrregularPrintedUnderNoClassBlocksEverySlot() async throws {
        let printed = FormTable(sources: [], forms: [
            "more": [.init(lemma: "many", partOfSpeech: "")],
            "most": [.init(lemma: "many", partOfSpeech: "")],
        ], ownHeadwords: [])
        let dictionaries = Dictionaries(entries: ["many": [Headed("many", ["determiner, pronoun, & adjective"])]])
        for term in ["maniest", "manier"] {
            let offered = try await offer(term, lemma: "many", dictionaries: dictionaries, printed: printed)
            #expect(offered.suggestion?.kind != .dictionaryForm, "\(term) was offered many")
        }
        #expect(dictionaries.questions.isEmpty)
        // A printed form whose ending names its slot still blocks that slot alone, whatever its class says.
        let named = FormTable(sources: [], forms: ["redder": [.init(lemma: "red", partOfSpeech: "")]], ownHeadwords: [])
        #expect(try await offer("reddest", lemma: "red", dictionaries: Dictionaries(entries: ["red": [Headed("red", ["adjective"])]]),
                                printed: named) == .offered(SpellingSuggestion(term: "reddest", word: "red", kind: .dictionaryForm)))
    }

    /// **Whether a longer word doubles its last consonant is a matter of stress, which spelling does not show** (second
    /// audit of 2026-10-10): *commit* is *committed*, *holler* is *hollered*. The rule spelled every such word undoubled, so
    /// with no form table *commited* qualified as *commit*'s past and outranked the checker's *committed*. Without
    /// printed evidence the rule now abstains; a form the dictionary prints in another slot decides it for the rest.
    @Test func aLongerWordsDoublingIsDecidedOnlyByWhatTheDictionaryPrints() async throws {
        let lexicon: [String: [Headed]] = [
            "commit": [Headed("commit", ["verb"])], "committed": [Headed("committed")], "committing": [Headed("committing")],
            "holler": [Headed("holler", ["verb", "noun"])],
        ]
        // No table: the checker's correction, and never the base.
        for (term, correction) in [("commited", "committed"), ("commiting", "committing")] {
            let dictionaries = Dictionaries(entries: lexicon)
            let offered = try await offer(term, lemma: "commit", checker: Checker([term: correction]),
                                          dictionaries: dictionaries, printed: nil)
            #expect(offered == .offered(SpellingSuggestion(term: term, word: correction)), "\(term): \(offered)")
            #expect(dictionaries.questions == [correction], "\(term): a stress-dependent form was looked up")
        }
        #expect(try await offer("hollering", lemma: "holler", dictionaries: Dictionaries(entries: lexicon), printed: nil)
            .suggestion?.kind != .dictionaryForm)
        // A form printed in one slot decides the others: *committed* says *commit* doubles, *hollered* that *holler* does
        // not — so *committing* and *hollering* are regular, and *commiting* is not.
        let printed = FormTable(sources: [], forms: [
            "committed": [.init(lemma: "commit", partOfSpeech: "verb")],
            "hollered": [.init(lemma: "holler", partOfSpeech: "verb")],
        ], ownHeadwords: [])
        #expect(try await offer("committing", lemma: "commit", dictionaries: Dictionaries(entries: lexicon), printed: printed)
            == .offered(SpellingSuggestion(term: "committing", word: "commit", kind: .dictionaryForm)))
        #expect(try await offer("hollering", lemma: "holler", dictionaries: Dictionaries(entries: lexicon), printed: printed)
            == .offered(SpellingSuggestion(term: "hollering", word: "holler", kind: .dictionaryForm)))
        #expect(try await offer("commiting", lemma: "commit", dictionaries: Dictionaries(entries: lexicon), printed: printed)
            .suggestion?.kind != .dictionaryForm)
        // A word of one syllable doubles by spelling alone, as before.
        #expect(try await offer("tipped", lemma: "tip", dictionaries: Dictionaries(entries: ["tip": [Headed("tip", ["verb"])]]),
                                printed: nil) == .offered(SpellingSuggestion(term: "tipped", word: "tip", kind: .dictionaryForm)))
    }

    /// **A word in *-c* takes *k* before *-ed* and *-ing***: *panicked*, *mimicking* (audit of 2026-10-10). The rule took
    /// *paniced* and *panicing* too, so with no form table read, *panic*'s verb entry licensed both. The few words that
    /// keep a bare *c* — *arced*, *disced*, *synced* — are offered only where the dictionaries print them.
    @Test func aWordInCTakesKBeforeItsEndingsUnlessTheDictionaryPrintsOtherwise() async throws {
        let lexicon: [String: [Headed]] = ["panic": [Headed("panic", ["noun", "verb"])], "arc": [Headed("arc", ["noun", "verb"])],
                                           "panicked": [Headed("panicked")]]
        for term in ["paniced", "panicing"] {
            let checker = Checker(term == "paniced" ? [term: "panicked"] : [:])
            let offered = try await offer(term, lemma: "panic", checker: checker, dictionaries: Dictionaries(entries: lexicon),
                                          printed: nil)
            #expect(offered.suggestion?.kind != .dictionaryForm, "\(term) was offered panic")
            if term == "paniced" { #expect(offered == .offered(SpellingSuggestion(term: term, word: "panicked"))) }
        }
        for term in ["panicked", "panicking"] {
            let offered = try await offer(term, lemma: "panic", dictionaries: Dictionaries(entries: lexicon), printed: nil)
            #expect(offered == .offered(SpellingSuggestion(term: term, word: "panic", kind: .dictionaryForm)), "\(term)")
        }
        // A bare *c* where the dictionary prints it, and only there.
        #expect(try await offer("arced", lemma: "arc", dictionaries: Dictionaries(entries: lexicon), printed: nil)
            .suggestion?.kind != .dictionaryForm)
        let printed = FormTable(sources: [], forms: ["arced": [.init(lemma: "arc", partOfSpeech: "verb")]], ownHeadwords: [])
        #expect(try await offer("arced", lemma: "arc", dictionaries: Dictionaries(entries: lexicon), printed: printed)
            == .offered(SpellingSuggestion(term: "arced", word: "arc", kind: .dictionaryForm)))
    }

    /// **The same class: a single *z* after one vowel doubles in a word of one syllable** — *quizzes*, *whizzed* —
    /// where the rule took *quizes* as well. A single *s* may or may not (*buses*, *busses*): both stand.
    @Test func aWordInOneVowelAndZDoublesIt() async throws {
        let lexicon: [String: [Headed]] = ["quiz": [Headed("quiz", ["noun", "verb"])], "bus": [Headed("bus", ["noun", "verb"])]]
        for (term, form, offered) in [("quizes", "quiz", false), ("quized", "quiz", false), ("quizzes", "quiz", true),
                                      ("quizzed", "quiz", true), ("buses", "bus", true), ("busses", "bus", true)] {
            let answer = try await offer(term, lemma: form, dictionaries: Dictionaries(entries: lexicon), printed: nil)
            #expect((answer.suggestion?.kind == .dictionaryForm) == offered, "\(term): \(answer)")
        }
    }

    // MARK: - The regression table

    enum Verdict { case right, wrong, unclear }

    /// One labelled recovery of the WI-3 spike: Codex's verdict on the 72 rows the two panel labels disagreed on
    /// (recorded in the plan, local only), and the 8 both labels called wrong. `entries` is what the
    /// form's lookup answers with on the development Mac (`headword:part|part`, `-` for a block naming none, no `:`
    /// for an entry with no sense structure); `printed` is what the form table prints under the form, `termPrinted`
    /// what it prints the term under.
    struct Row: Sendable, CustomStringConvertible {
        let id: Int
        let term: String
        let form: String
        let verdict: Verdict
        let entries: String
        let printed: String
        let termPrinted: String
        init(_ id: Int, _ term: String, _ form: String, _ verdict: Verdict, _ entries: String,
             printed: String, termPrinted: String) {
            (self.id, self.term, self.form, self.verdict) = (id, term, form, verdict)
            (self.entries, self.printed, self.termPrinted) = (entries, printed, termPrinted)
        }
        var description: String { "\(id) \(term) → \(form)" }

        var headed: [Headed] {
            entries.split(separator: ";").map { part in
                let fields = part.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
                let parts = fields.count > 1 ? fields[1].split(separator: "|").map { $0 == "-" ? "" : String($0) } : []
                return Headed(String(fields[0]), parts)
            }
        }
    }

    static let rows: [Row] = [
        Row(17066, "fides", "fid", .wrong, "fid:noun", printed: "", termPrinted: ""),
        Row(19237, "ceed", "ce", .wrong, "CE:abbreviation; Ce:noun; Ce:symbol", printed: "", termPrinted: ""),
        Row(19339, "aded", "ad", .wrong, "AD:abbreviation; ad:noun; AD:noun", printed: "", termPrinted: ""),
        Row(19684, "daed", "da", .right, "DA:abbreviation; DA:noun; da:abbreviation; da:determiner; da:noun", printed: "", termPrinted: ""),
        Row(20201, "summated", "summat", .wrong, "summat", printed: "", termPrinted: ""),
        Row(21011, "moued", "moue", .right, "moue:noun", printed: "", termPrinted: ""),
        Row(21855, "roofied", "roofie", .right, "roofie", printed: "", termPrinted: ""),
        Row(22363, "duckier", "ducky", .right, "ducky:noun; ducky:noun|adjective", printed: "duckies:noun", termPrinted: ""),
        Row(22517, "verier", "very", .right, "very:adverb|adjective|adverb phrase|pronoun phrase; very:adverb|adjective; very:adverb", printed: "", termPrinted: ""),
        Row(23074, "untiling", "until", .wrong, "until:preposition|conjunction", printed: "", termPrinted: ""),
        Row(23507, "mouing", "moue", .right, "moue:noun", printed: "", termPrinted: ""),
        Row(24702, "summating", "summat", .wrong, "summat", printed: "", termPrinted: ""),
        Row(25177, "howdying", "howdy", .right, "howdy:exclamation", printed: "", termPrinted: ""),
        Row(26339, "kiddying", "kiddie", .unclear, "kiddie:noun", printed: "kiddies:noun", termPrinted: ""),
        Row(26918, "hedgiest", "hedgie", .wrong, "hedgie:noun", printed: "", termPrinted: ""),
        Row(26948, "wedgiest", "wedgie", .wrong, "wedgie:noun", printed: "", termPrinted: ""),
        Row(27039, "brickiest", "brickie", .wrong, "brickie:noun", printed: "brickies:noun", termPrinted: ""),
        Row(27237, "duckiest", "ducky", .right, "ducky:noun; ducky:noun|adjective", printed: "duckies:noun", termPrinted: ""),
        Row(28001, "Frances", "france", .wrong, "France:proper noun; France:-", printed: "", termPrinted: ""),
        Row(28055, "Hans", "han", .wrong, "Han:noun; Han:-", printed: "", termPrinted: ""),
        Row(28204, "Jos", "jo", .wrong, "jo:noun", printed: "joes:noun", termPrinted: ""),
        Row(29327, "preemiees", "preemie", .wrong, "preemie:noun", printed: "preemies:noun", termPrinted: ""),
        Row(29429, "penetrateed", "penetrate", .wrong, "penetrate:transitive verb|intransitive verb; penetrate:verb; penetrate:transitive verb", printed: "", termPrinted: ""),
        Row(29501, "malies", "mali", .wrong, "Mali:proper noun; Mali:-", printed: "malis:noun", termPrinted: ""),
        Row(29509, "proped", "prop", .wrong, "prop:noun|transitive verb; prop:noun; prop:noun|verb", printed: "propped:verb propping:verb props:verb", termPrinted: ""),
        Row(29562, "hollerring", "holler", .wrong, "holler:intransitive verb|transitive verb|noun; holler:verb|noun; holler:noun; holler:transitive verb|intransitive verb", printed: "", termPrinted: ""),
        Row(29573, "prideed", "pride", .wrong, "pride:noun|reflexive verb; pride:noun|verb; pride:noun", printed: "", termPrinted: ""),
        Row(29635, "ouses", "ouse", .right, "Ouse:-", printed: "", termPrinted: ""),
        Row(29733, "sbbed", "sb", .wrong, "Sb:noun; sb:abbreviation; Sb:symbol; SB:abbreviation", printed: "", termPrinted: ""),
        Row(29743, "santing", "sant", .right, "sant:noun", printed: "", termPrinted: ""),
        Row(29754, "unziping", "unzip", .wrong, "unzip:transitive verb|intransitive verb; unzip:verb; unzip:transitive verb", printed: "unzipped:verb unzipping:verb unzips:verb", termPrinted: ""),
        Row(29824, "tunicatees", "tunicate", .wrong, "tunicate:noun|adjective", printed: "", termPrinted: ""),
        Row(29901, "readaptting", "readapt", .wrong, "readapt:verb", printed: "", termPrinted: ""),
        Row(29903, "maccing", "mac", .right, "mac:noun; Mac:noun", printed: "", termPrinted: ""),
        Row(29931, "polaries", "polari", .wrong, "Polari:noun", printed: "", termPrinted: ""),
        Row(29948, "caried", "cary", .right, "Cary:-", printed: "", termPrinted: ""),
        Row(29992, "parrotfishs", "parrotfish", .wrong, "parrotfish:noun", printed: "parrotfishes:noun", termPrinted: ""),
        Row(30082, "tengees", "tenge", .wrong, "tenge:noun", printed: "tenges:noun", termPrinted: ""),
        Row(30086, "hrses", "hrs", .unclear, "hrs:abbreviation", printed: "", termPrinted: ""),
        Row(30207, "chffing", "chf", .wrong, "CHF:abbreviation", printed: "", termPrinted: ""),
        Row(30221, "tiped", "tip", .wrong, "tip:noun|transitive verb; tip:transitive verb|intransitive verb|noun; tip:noun|verb; tip:verb|noun; tip:verb", printed: "tipped:verb tipping:verb tips:verb", termPrinted: ""),
        Row(30370, "tning", "tn", .unclear, "TN:abbreviation; tn:noun; tn:abbreviation; tn:noun|adverb", printed: "", termPrinted: ""),
        Row(30420, "stationes", "station", .wrong, "station:noun|transitive verb|reflexive verb; station:noun|verb; station:noun", printed: "", termPrinted: ""),
        Row(30518, "depriveed", "deprive", .wrong, "deprive:transitive verb; deprive:verb", printed: "", termPrinted: ""),
        Row(30642, "gobes", "gob", .wrong, "gob:noun|intransitive verb; gob:noun", printed: "gobbed:verb gobbing:verb gobs:verb", termPrinted: ""),
        Row(30697, "inducteed", "inductee", .right, "inductee:noun", printed: "", termPrinted: ""),
        Row(30856, "odorizees", "odorize", .wrong, "odorize:verb", printed: "", termPrinted: ""),
        Row(30885, "craterring", "crater", .wrong, "crater:noun; crater:noun|verb; Crater:-|adjective", printed: "", termPrinted: ""),
        Row(30902, "folated", "folate", .right, "folate:noun", printed: "", termPrinted: ""),
        Row(31024, "propoundded", "propound", .wrong, "propound:transitive verb; propound:verb", printed: "", termPrinted: ""),
        Row(31116, "enrichhed", "enrich", .wrong, "enrich:transitive verb; enrich:verb", printed: "", termPrinted: ""),
        Row(31135, "whinned", "whin", .right, "whin:noun", printed: "", termPrinted: ""),
        Row(31146, "superheatted", "superheat", .wrong, "superheat:verb|noun", printed: "", termPrinted: ""),
        Row(31190, "relaxxing", "relax", .wrong, "relax:transitive verb|intransitive verb; relax:verb", printed: "", termPrinted: ""),
        Row(31200, "confrering", "confrere", .right, "confrere:noun", printed: "", termPrinted: ""),
        Row(31227, "sadis", "sadi", .right, "Sadi:-", printed: "", termPrinted: ""),
        Row(31295, "pouchs", "pouch", .wrong, "pouch:noun; pouch:noun|verb", printed: "", termPrinted: ""),
        Row(31316, "bankruptting", "bankrupt", .wrong, "bankrupt:adjective|transitive verb|noun; bankrupt:adjective|noun|verb; bankrupt:adjective", printed: "", termPrinted: ""),
        Row(31360, "cursting", "curst", .wrong, "curst:adjective", printed: "", termPrinted: ""),
        Row(31373, "presageed", "presage", .wrong, "presage:transitive verb,; presage:verb|noun; presage:transitive verb|noun", printed: "", termPrinted: ""),
        Row(31430, "inspaning", "inspan", .wrong, "inspan:verb", printed: "inspanned:verb inspanning:verb inspans:verb", termPrinted: ""),
        Row(31461, "rhymees", "rhyme", .wrong, "rhyme:noun|transitive verb|intransitive verb; rhyme:noun|verb; rhyme:noun; rhyme:noun|intransitive verb", printed: "", termPrinted: ""),
        Row(31540, "gujarats", "gujarat", .right, "Gujarat:proper noun; Gujarat:-", printed: "", termPrinted: ""),
        Row(31541, "balis", "bali", .right, "Bali:-; Bali:proper noun", printed: "", termPrinted: ""),
        Row(31586, "bogglees", "boggle", .wrong, "boggle:intransitive verb|transitive verb; boggle:verb", printed: "", termPrinted: ""),
        Row(31636, "pervadeed", "pervade", .wrong, "pervade:transitive verb; pervade:verb", printed: "", termPrinted: ""),
        Row(31667, "jaliing", "jali", .right, "jali:noun", printed: "", termPrinted: ""),
        Row(31816, "groging", "grog", .wrong, "grog:noun", printed: "", termPrinted: ""),
        Row(31867, "chromatees", "chromate", .wrong, "chromate:noun", printed: "", termPrinted: ""),
        Row(32013, "curtesying", "curtesy", .right, "curtesy:noun", printed: "curtesies:noun", termPrinted: ""),
        Row(32080, "metallizeed", "metallize", .wrong, "metallize:verb", printed: "", termPrinted: ""),
        Row(32161, "pretzelled", "pretzel", .right, "pretzel:noun; pretzel:noun|verb", printed: "pretzeled:verb pretzeling:verb pretzels:verb", termPrinted: ""),
        // The spike's dictionaries answered *judie*; the development Mac's no longer do. Kept answering, so the only
        // thing that can refuse it is what the table prints the term under.
        Row(6184, "judies", "judie", .wrong, "judie:noun", printed: "", termPrinted: "noun:judy"),
        Row(9336, "proddies", "proddie", .wrong, "Proddie", printed: "", termPrinted: "noun:proddy"),
        Row(9618, "quos", "quo", .wrong, "quo", printed: "", termPrinted: "noun:quid pro quo"),
        Row(25674, "zincking", "zinc", .wrong, "zinc:noun; zinc:noun|verb", printed: "", termPrinted: ""),
        Row(29374, "scking", "sc", .wrong, "SC:abbreviation; Sc:noun; sc:abbreviation; Sc:symbol", printed: "", termPrinted: ""),
        Row(30623, "concreti", "concrete", .wrong, "concrete:noun|adjective; concrete:adjective|noun|verb; concrete:adjective; concrete:noun", printed: "", termPrinted: ""),
        Row(31681, "sequele", "sequela", .wrong, "sequela:noun", printed: "sequelae:noun", termPrinted: ""),
        Row(32135, "seives", "seif", .wrong, "seif:noun", printed: "", termPrinted: ""),
    ]

    /// **Labelled wrong and still offered — the residue, named.** *cursting*: *curst* is an adjective in NOAD, and an
    /// adjective takes *-ing* by conversion (*heavied* is kept by the same rule); that it is itself *curse*'s archaic
    /// past is printed nowhere this rule can read. *zincking*: the label's error, not the rule's — the spike generated it
    /// from a stem *zincke*, but *zinc* → *zincking* is the regular *-cking* of a *c* verb, and NOAD's *zinc* is one.
    static let offeredThoughWrong: Set<Int> = [31360, 25674]

    /// **Labelled right and not offered — what the guards cost**, each for a reason the rule can state: an entry with
    /// no part of speech (*roofie*), an exclamation (*howdy*), a proper noun's entry (*Ouse*, *Cary*, *Sadi*, *Gujarat*,
    /// *Bali*), a *c* doubled where English writes *ck* (*maccing*), and a form printed another way (*pretzel* prints
    /// *pretzeled*). The checker's verified correction is offered in their place.
    static let refusedThoughRight: Set<Int> = [21855, 25177, 29635, 29948, 31227, 31540, 31541, 29903, 32161]

    /// **Refused once the form was looked up** — its entry licenses no such inflection — rather than before: the
    /// spelling, a capital, a form with no vowel, or what the dictionaries print refuse without a lookup. *summated*,
    /// *summating* and *untiling* left this list on 2026-10-10 (the second audit): *summat* and *until* end in one vowel
    /// and a consonant in more than one syllable, where doubling turns on stress, and with nothing printed the rule now
    /// abstains before any lookup.
    static let refusedByTheEntry: Set<Int> = [21855, 25177, 26918, 26948, 27039,
                                               29635, 29948, 31227, 31540, 31541]

    static var table: FormTable {
        var forms: [String: Set<FormTable.Reading>] = [:]
        for row in rows {
            for printed in row.printed.split(separator: " ") {
                let fields = printed.split(separator: ":", maxSplits: 1).map(String.init)
                forms[fields[0], default: []].insert(.init(lemma: row.form, partOfSpeech: fields[1]))
            }
            if !row.termPrinted.isEmpty {
                let fields = row.termPrinted.split(separator: ":", maxSplits: 1).map(String.init)
                forms[row.term.lowercased(), default: []].insert(.init(lemma: fields[1], partOfSpeech: fields[0]))
            }
        }
        return FormTable(sources: [], forms: forms, ownHeadwords: [])
    }

    /// **All 80, through the real suggester**: a wrong one is never offered but for the residue named above, a right
    /// one is offered but for the cost named above, the three Codex called unclear are not offered — and a refusal is
    /// made before the lookup wherever it can be, so an indefensible form costs the service nothing.
    @Test(arguments: rows)
    func theLabelledRecoveries(_ row: Row) async throws {
        let dictionaries = Dictionaries(entries: [row.form: row.headed])
        let offered = try await offer(row.term, lemma: row.form, dictionaries: dictionaries, printed: Self.table)
        let expected = switch row.verdict {
        case .right: !Self.refusedThoughRight.contains(row.id)
        case .wrong: Self.offeredThoughWrong.contains(row.id)
        case .unclear: false
        }
        if expected {
            #expect(offered == .offered(SpellingSuggestion(term: row.term, word: row.form, kind: .dictionaryForm)))
        } else {
            #expect(offered == .noCorrection)
        }
        let asked = expected || Self.refusedByTheEntry.contains(row.id)
        #expect(dictionaries.questions == (asked ? [row.form] : []), "asked \(dictionaries.questions)")
    }

    /// The table is what the decision handed over: 72 judged rows and the 8 both labels called wrong.
    @Test func theTableIsTheEightyLabelledRows() {
        #expect(Self.rows.count == 80)
        #expect(Set(Self.rows.map(\.id)).count == 80)
        #expect(Self.rows.filter { $0.verdict == .wrong }.count == 55)
        #expect(Self.rows.filter { $0.verdict == .right }.count == 22)
        #expect(Self.offeredThoughWrong.isSubset(of: Set(Self.rows.filter { $0.verdict == .wrong }.map(\.id))))
        #expect(Self.refusedThoughRight.isSubset(of: Set(Self.rows.filter { $0.verdict == .right }.map(\.id))))
    }
}
