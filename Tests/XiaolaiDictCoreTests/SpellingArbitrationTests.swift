import CaptureModel
import DictionaryModel
import Foundation
import Testing
import XiaolaiDictCore

/// **One offer, chosen by evidence; silence where credible alternatives remain** — the owner's ruling of 2026-10-11
/// (ADR-0054 part B). A miss card that offered two competing words — a regular-spelling form and the checker's
/// correction side by side — was rejected: silence beats a wrong offer. Every case here goes through the real
/// `SpellingSuggester`, against a checker and dictionaries of the test's own, so what is asked is counted.
struct SpellingArbitrationTests {
    typealias Checker = SpellingSuggesterTests.Checker
    typealias Dictionaries = SpellingSuggesterTests.Dictionaries
    typealias Headed = Dictionaries.Headed
    private static let miss = LookupOutcome.notFound(serviceFailure: nil)

    /// The measured dictionaries, and the words the regression table's checker answers with — each verified, so only
    /// the rules can refuse them.
    static let lexicon: [String: [Headed]] = MeasuredDictionaries.lexicon.merging([
        "curst": [Headed("curst", ["adjective"])], "cursing": [Headed("cursing")],
        "gazebo": [Headed("gazebo", ["noun"])], "gazebos": [Headed("gazebos")], "gazebots": [Headed("gazebots")],
        "penetrate": [Headed("penetrate", ["transitive verb", "intransitive verb"])], "penetrated": [Headed("penetrated")],
        "prop": [Headed("prop", ["noun", "transitive verb"])], "proper": [Headed("proper", ["adjective"])],
        "mac": [Headed("mac", ["noun"])], "massing": [Headed("massing")],
        "whin": [Headed("whin", ["noun"])], "thinned": [Headed("thinned")], "winnowed": [Headed("winnowed")],
        "cat": [Headed("cat", ["noun"])],
    ]) { old, _ in old }

    private func decide(
        _ term: String, lemma: String?, basis: Lemma.Basis = .tagger, checker: Checker = Checker([:]),
        dictionaries: Dictionaries = Dictionaries(entries: Self.lexicon),
        printed: FormTable? = MeasuredDictionaries.noad, capture: CaptureQuality.Source? = nil
    ) async throws -> SpellingDecision {
        try await SpellingSuggester(
            checker: checker, lookUp: { term throws(CancellationError) in try dictionaries.lookUp(term) },
            language: { nil }, forms: { printed })
            .decide(for: term, outcome: Self.miss, lemma: lemma.map { Lemma(text: $0, basis: basis) }, capture: capture)
    }

    private static func offered(_ term: String, _ word: String, _ evidence: SpellingSuggestion.Evidence) -> SpellingOffer {
        .offered(SpellingSuggestion(term: term, word: word, evidence: evidence))
    }

    // MARK: - The regression table (the ruling's, each with a genuine miss and verified candidates)

    /// ***heavied***: printed (the development Mac's ODE) gives *heavy*; regular (the E2E Mac, where nothing prints it)
    /// competes with the checker's verified *heavier* — the same base, another slot — and gives nothing.
    @Test func heavied() async throws {
        let printed = try await decide("heavied", lemma: "heavy", checker: Checker(["heavied": "heavier"]),
                                       printed: MeasuredDictionaries.withODE)
        #expect(printed.offer == Self.offered("heavied", "heavy", .printed))
        let checker = Checker(["heavied": "heavier"]), dictionaries = Dictionaries(entries: Self.lexicon)
        let regular = try await decide("heavied", lemma: "heavy", checker: checker, dictionaries: dictionaries)
        #expect(regular.offer == .abstained(.conflict), "\(regular.offer)")
        #expect(regular.form?.supported == true && regular.correction?.verified == true && regular.correction?.edit.distance == 1)
        #expect(dictionaries.questions == ["heavy", "heavier"])
    }

    /// ***gazeboes***: printed gives *gazebo*; regular gives *gazebo* only where the checker's *gazebos* is the same
    /// noun's plural — and nothing where its word is another family's.
    @Test func gazeboes() async throws {
        let table = FormTable(sources: [], forms: ["gazeboes": [.init(lemma: "gazebo", partOfSpeech: "noun")]], ownHeadwords: [])
        #expect(try await decide("gazeboes", lemma: "gazebo", checker: Checker(["gazeboes": "gazebots"]), printed: table).offer
            == Self.offered("gazeboes", "gazebo", .printed))
        #expect(try await decide("gazeboes", lemma: "gazebo", checker: Checker(["gazeboes": "gazebos"]), printed: nil).offer
            == Self.offered("gazeboes", "gazebo", .agreement(.s)))
        #expect(try await decide("gazeboes", lemma: "gazebo", checker: Checker(["gazeboes": "gazebots"]), printed: nil).offer
            == .abstained(.conflict))
    }

    /// ***cursting***: *curst* is a regular *-ing* of an adjective by conversion, and the checker's *cursing* is one
    /// edit away and verified — two credible readings, so nothing.
    @Test func cursting() async throws {
        let decided = try await decide("cursting", lemma: "curst", checker: Checker(["cursting": "cursing"]))
        #expect(decided.offer == .abstained(.conflict))
        #expect(decided.rule == "conflict")
    }

    /// ***droughtier*** and ***glacises***: printed, so the checker's *doughtier* and *glasses* are never asked.
    @Test func droughtierAndGlacisesArePrinted() async throws {
        for (term, form, wrong) in [("droughtier", "droughty", "doughtier"), ("glacises", "glacis", "glasses")] {
            let checker = Checker([term: wrong])
            #expect(try await decide(term, lemma: form, checker: checker).offer == Self.offered(term, form, .printed))
            #expect(checker.questions.isEmpty, "\(term): the checker was asked")
        }
    }

    /// ***dalesmen***: printed gives *dalesman*; unprinted, the *-men* plural of a noun the dictionaries have blocks the
    /// checker's *salesmen* and offers nothing in its place.
    @Test func dalesmen() async throws {
        #expect(try await decide("dalesmen", lemma: "dalesman", checker: Checker(["dalesmen": "salesmen"]),
                                 printed: MeasuredDictionaries.withODE).offer
            == Self.offered("dalesmen", "dalesman", .printed))
        let dictionaries = Dictionaries(entries: Self.lexicon)
        let unprinted = try await decide("dalesmen", lemma: "dalesman", checker: Checker(["dalesmen": "salesmen"]),
                                         dictionaries: dictionaries)
        #expect(unprinted.offer == .abstained(.irregularPattern))
        #expect(dictionaries.questions == ["salesmen", "dalesman"])
        // With no lemma at all the pattern still reads it.
        #expect(try await decide("dalesmen", lemma: nil, checker: Checker(["dalesmen": "salesmen"])).offer
            == .abstained(.irregularPattern))
    }

    /// ***recieve***, ***penetrateed***, ***prideed***: the checker's word at one edit — a transposition, a deletion —
    /// inside the proposed base's own family where there is one.
    @Test func oneEditTypos() async throws {
        #expect(try await decide("recieve", lemma: "recieve", basis: .surface, checker: Checker(["recieve": "receive"])).offer
            == Self.offered("recieve", "receive", .correction(.transposition)))
        #expect(try await decide("penetrateed", lemma: "penetrate", checker: Checker(["penetrateed": "penetrated"])).offer
            == Self.offered("penetrateed", "penetrated", .correction(.deletion)))
        #expect(try await decide("prideed", lemma: "pride", checker: Checker(["prideed": "prided"])).offer
            == Self.offered("prideed", "prided", .correction(.deletion)))
    }

    /// ***Frances***: no *france* is inferred from a capitalised word, and the measured checker has nothing for it.
    @Test func frances() async throws {
        let dictionaries = Dictionaries(entries: Self.lexicon)
        let decided = try await decide("Frances", lemma: "france", dictionaries: dictionaries)
        #expect(decided.offer == .abstained(.noCandidate))
        #expect(decided.form == nil)
        #expect(dictionaries.questions.isEmpty)
    }

    // MARK: - The rules, one at a time

    /// **Agreement on the same word is one offer** — the checker naming the form itself.
    @Test func theCheckerNamingTheFormItselfIsAgreement() async throws {
        let dictionaries = Dictionaries(entries: Self.lexicon)
        let decided = try await decide("cats", lemma: "cat", checker: Checker(["cats": "cat"]), dictionaries: dictionaries)
        #expect(decided.offer == Self.offered("cats", "cat", .agreement(.s)))
        #expect(dictionaries.questions == ["cat"], "the same word was looked up twice")
    }

    /// **A rival that is not credible does not silence a regular form**: one the dictionaries lack, or one more than an
    /// edit away. The positive control is the credible one, which does.
    @Test func onlyACredibleRivalSilencesARegularForm() async throws {
        for (correction, expected) in [("whinnied", Self.offered("whinned", "whin", .regular(.ed))),
                                       ("winnowed", Self.offered("whinned", "whin", .regular(.ed))),
                                       ("thinned", SpellingOffer.abstained(.conflict))] {
            let decided = try await decide("whinned", lemma: "whin", checker: Checker(["whinned": correction]))
            #expect(decided.offer == expected, "\(correction): \(decided.offer)")
        }
    }

    /// **A checker's word alone is offered at one edit and never further** — whatever the capture.
    @Test func aCorrectionMoreThanOneEditAwayIsNotOffered() async throws {
        let decided = try await decide("maccing", lemma: "mac", checker: Checker(["maccing": "massing"]))
        #expect(decided.offer == .abstained(.tooFar))
        #expect(decided.correction == .init(word: "massing", verified: true, edit: SpellingEdit.between("maccing", "massing")))
        #expect(decided.correction?.edit.distance == 2)
    }

    /// **The term one edit from a form printed under its base, and the checker's word another family's: nothing** —
    /// *proped* reads as a slip of *propped* as much as of *proper*. Without the printed neighbour the correction stands,
    /// and a correction inside the base's own family passes the guard.
    @Test func aPrintedNeighbourBlocksAnotherFamilysCorrection() async throws {
        let table = FormTable(sources: [], forms: [
            "propped": [.init(lemma: "prop", partOfSpeech: "verb")], "props": [.init(lemma: "prop", partOfSpeech: "verb")],
        ], ownHeadwords: [])
        #expect(try await decide("proped", lemma: "prop", checker: Checker(["proped": "proper"]), printed: table).offer
            == .abstained(.printedNeighbour))
        #expect(try await decide("proped", lemma: "prop", checker: Checker(["proped": "proper"]), printed: nil).offer
            == Self.offered("proped", "proper", .correction(.substitution)))
        let inFamily = Dictionaries(entries: ["prop": [Headed("prop", ["verb"])], "propped": [Headed("propped")]])
        #expect(try await decide("proped", lemma: "prop", checker: Checker(["proped": "propped"]), dictionaries: inFamily,
                                 printed: table).offer
            == Self.offered("proped", "propped", .correction(.insertion)))
    }

    /// **The *-men* pattern guards where the dictionaries support it — the compound, or its first element as a noun**
    /// (measured 2026-10-11 on the E2E Mac, whose dictionaries have no *dalesman*: its *dales* is *dale*'s plural, a noun,
    /// so *salesmen* is still blocked). A base and an element they do not have, or have only as a name or another class,
    /// support nothing, and the checker's word stands.
    @Test func aCompoundsFirstElementSupportsThePattern() async throws {
        var entries = Self.lexicon
        entries["dalesman"] = []
        entries["dales"] = [Headed("dale", ["noun"])]
        let dictionaries = Dictionaries(entries: entries)
        let decided = try await decide("dalesmen", lemma: nil, checker: Checker(["dalesmen": "salesmen"]),
                                       dictionaries: dictionaries)
        #expect(decided.offer == .abstained(.irregularPattern))
        #expect(dictionaries.questions == ["salesmen", "dalesman", "dales"])
        for element in [[Headed("Dale", ["noun"])], [Headed("dale", ["verb"])]] {
            entries["dales"] = element
            #expect(try await decide("dalesmen", lemma: nil, checker: Checker(["dalesmen": "salesmen"]),
                                     dictionaries: Dictionaries(entries: entries)).offer
                == Self.offered("dalesmen", "salesmen", .correction(.substitution)), "\(element.map(\.headword))")
        }
    }

    @Test func anUnsupportedIrregularPatternGuardsNothing() async throws {
        for base in [[], [Headed("Dalesman", ["noun"])], [Headed("dalesman", ["adjective"])]] {
            var entries = Self.lexicon
            entries["dalesman"] = base
            let decided = try await decide("dalesmen", lemma: nil, checker: Checker(["dalesmen": "salesmen"]),
                                           dictionaries: Dictionaries(entries: entries))
            #expect(decided.offer == Self.offered("dalesmen", "salesmen", .correction(.substitution)), "\(base.map(\.headword))")
        }
    }

    /// **Printed under several bases, the lookup's lemma chooses or nothing is offered** — and nothing is asked.
    @Test func printedUnderSeveralBasesNeedsTheLemmaToChoose() async throws {
        let table = FormTable(sources: [], forms: [
            "axes": [.init(lemma: "axe", partOfSpeech: "noun"), .init(lemma: "axis", partOfSpeech: "noun")],
        ], ownHeadwords: [])
        let lexicon: [String: [Headed]] = ["axe": [Headed("axe", ["noun"])], "axis": [Headed("axis", ["noun"])]]
        let unresolved = Dictionaries(entries: lexicon)
        #expect(try await decide("axes", lemma: nil, checker: Checker(["axes": "axe"]), dictionaries: unresolved,
                                 printed: table).offer == .abstained(.printedAmbiguous))
        #expect(unresolved.questions.isEmpty)
        #expect(try await decide("axes", lemma: "axis", dictionaries: Dictionaries(entries: lexicon), printed: table).offer
            == Self.offered("axes", "axis", .printed))
    }

    /// **A printed base the dictionaries do not have is offered nothing, and the checker is not asked in its place** —
    /// the print is the explanation, and *salesmen* is not *dalesmen*'s.
    @Test func aPrintedBaseTheDictionariesLackLeavesNothing() async throws {
        let checker = Checker(["dalesmen": "salesmen"]), dictionaries = Dictionaries(["salesmen"])
        let decided = try await decide("dalesmen", lemma: "dalesman", checker: checker, dictionaries: dictionaries,
                                       printed: MeasuredDictionaries.withODE)
        #expect(decided.offer == .abstained(.printedUnverified))
        #expect(dictionaries.questions == ["dalesman"])
        #expect(checker.questions.isEmpty)
    }

    /// **The same thresholds for every capture source**: recorded on the decision, never weighed — recognised text gets
    /// no larger edit budget.
    @Test func theCaptureSourceIsRecordedAndNeverWeighed() async throws {
        for source in [nil] + CaptureQuality.Source.allCases.map(Optional.some) {
            let far = try await decide("maccing", lemma: "mac", checker: Checker(["maccing": "massing"]), capture: source)
            #expect(far.offer == .abstained(.tooFar), "\(String(describing: source))")
            #expect(far.capture == source)
            let near = try await decide("recieve", lemma: nil, checker: Checker(["recieve": "receive"]), capture: source)
            #expect(near.offer == Self.offered("recieve", "receive", .correction(.transposition)))
        }
    }

    /// **Cancelled while the checker answers, the competing word is never looked up** — a superseded lookup costs the
    /// service nothing more than the form it had already asked.
    @Test func aCancelledDecisionDoesNotLookUpTheCompetingCorrection() async throws {
        let dictionaries = Dictionaries(entries: Self.lexicon)
        let task = Task {
            try await decide("cursting", lemma: "curst",
                             checker: Checker(["cursting": "cursing"]) { withUnsafeCurrentTask { $0?.cancel() } },
                             dictionaries: dictionaries)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(dictionaries.questions == ["curst"])
    }

    /// **Codex's conflicts, as the checker measured them** (the narrow build's report, 2026-10-10): eight regular forms,
    /// seven labelled right, each against a verified correction one edit away — each now offered nothing.
    @Test func theMeasuredConflictsAreOfferedNothing() async throws {
        let conflicts: [(term: String, form: String, partOfSpeech: String, correction: String)] = [
            ("santing", "sant", "noun", "wanting"), ("inducteed", "inductee", "noun", "inducted"),
            ("folated", "folate", "noun", "floated"), ("whinned", "whin", "noun", "thinned"),
            ("confrering", "confrere", "noun", "conferring"), ("cursting", "curst", "adjective", "cursing"),
            ("jaliing", "jali", "noun", "jailing"), ("curtesying", "curtesy", "noun", "curtsying"),
        ]
        for (term, form, partOfSpeech, correction) in conflicts {
            let dictionaries = Dictionaries(entries: [form: [Headed(form, [partOfSpeech])], correction: [Headed(correction)]])
            let decided = try await decide(term, lemma: form, checker: Checker([term: correction]), dictionaries: dictionaries,
                                           printed: nil)
            #expect(decided.offer == .abstained(.conflict), "\(term): \(decided.offer)")
            #expect(decided.correction?.edit.distance == 1, "\(term)")
        }
    }
}

/// **How far a correction is, and by what one change** — the edit the checker's word is held to.
struct SpellingEditTests {
    @Test func eachSingleEditIsNamed() {
        let cases: [(String, String, SpellingEdit.Operation)] = [
            ("recieve", "receive", .transposition), ("penetrateed", "penetrated", .deletion),
            ("recive", "receive", .insertion), ("proped", "proper", .substitution), ("teh", "the", .transposition),
        ]
        for (term, word, operation) in cases {
            #expect(SpellingEdit.between(term, word) == SpellingEdit(distance: 1, operation: operation), "\(term) → \(word)")
        }
    }

    @Test func twoEditsNameNoOperation() {
        #expect(SpellingEdit.between("maccing", "massing") == SpellingEdit(distance: 2, operation: nil))
        #expect(SpellingEdit.between("chromatees", "chromate").distance == 2)
        #expect(SpellingEdit.between("heavied", "heavy").distance == 3)
    }

    /// Case is the checker's, not an edit.
    @Test func caseIsNotAnEdit() {
        #expect(SpellingEdit.between("Recieve", "receive").distance == 1)
        #expect(SpellingEdit.between("teh", "TEH").distance == 0)
    }
}
