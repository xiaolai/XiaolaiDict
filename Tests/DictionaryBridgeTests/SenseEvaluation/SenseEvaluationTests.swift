import CaptureModel
import DictionaryModel
import Testing
@testable import XiaolaiDictCore

/// The evaluator's own rules, on synthetic fixtures — no dictionary, no embedding. The real run is
/// `SenseEvaluationRunTests`, and only where a case file exists; these hold the parts that decide a verdict to what
/// was declared, and show each gate can refuse.
struct SenseEvaluationTests {
    // MARK: The case file

    @Test func aCaseFileParses() throws {
        let cases = try SenseEvaluation.parse("""
            # a comment
            c1\tbank\tbank\tk.1\tShe sat on the bank of the river.\triver edge

            c2\tbank\tbanks\t-\tIt was the banks.\tdoes not settle
            """)
        #expect(cases.count == 2)
        #expect(cases[0] == .init(id: "c1", group: "bank", word: "bank", correct: "k.1",
                                  sentence: "She sat on the bank of the river.", note: "river edge"))
        #expect(cases[1].correct == nil, "a dash is an abstention case")
    }

    /// Strict: a line that does not parse names itself, and is never a case quietly skipped.
    @Test func aMalformedLineIsAnErrorNamingIt() {
        #expect(throws: SenseEvaluation.ParseError.malformed(line: 2, reason: "3 fields, not 6")) {
            try SenseEvaluation.parse("c1\tg\tw\tk\ts\tn\nc2\tg\tw")
        }
        #expect(throws: SenseEvaluation.ParseError.malformed(line: 1, reason: "an empty field")) {
            try SenseEvaluation.parse("c1\tg\t\tk\ts\tn")
        }
        #expect(throws: SenseEvaluation.ParseError.duplicateID("c1")) {
            try SenseEvaluation.parse("c1\tg\tw\tk\ts\tn\nc1\tg\tw\tk\ts\tn")
        }
    }

    // MARK: The split

    /// By headword, deterministic, and about one in three to development.
    @Test func theSplitIsByHeadwordAndStable() {
        let groups = (0 ..< 600).map { "headword\($0)" }
        let development = groups.filter { SenseEvaluation.split(of: $0) == .development }.count
        #expect((150 ... 250).contains(development), "\(development) of 600 went to development")
        // FNV-1a, not `Hasher`: the same answer for the same name, pinned so a seeded hash cannot slip in.
        #expect(SenseEvaluation.split(of: "bank") == SenseEvaluation.split(of: "bank"))
        #expect(groups.map { SenseEvaluation.split(of: $0) } == groups.map { SenseEvaluation.split(of: $0) })
    }

    // MARK: The paired interval

    /// No discordant pairs is not a zero-width interval: the adjustment keeps a small set from flattering an arm.
    @Test func noDiscordantPairsStillHasWidth() {
        let none = SenseEvaluation.PairedDifference(worse: 0, better: 0, cases: 400)
        #expect(none.difference == 0)
        #expect(none.upper > 0 && none.upper < SenseEvaluation.additionalErrorBound)
        #expect(none.lower < 0)
    }

    /// **The positive control for the error bound**: ten new wrong answers in 400 must fail the two-point bound, and
    /// ten fixed ones must clear it.
    @Test func tenNewErrorsInFourHundredFailTheBound() {
        let worse = SenseEvaluation.PairedDifference(worse: 10, better: 0, cases: 400)
        #expect(worse.upper >= SenseEvaluation.additionalErrorBound)
        let better = SenseEvaluation.PairedDifference(worse: 0, better: 10, cases: 400)
        #expect(better.upper < SenseEvaluation.additionalErrorBound)
        #expect(better.difference < 0)
    }

    // MARK: The comparator

    /// The retired narrowing, verbatim, is what the comparator runs — the deleted filter's own cases, held here now.
    @Test func theLegacyComparatorNarrowsAsTheRetiredFilterDid() {
        func kept(_ labels: [String?], _ tag: String?) -> [String?] {
            let field = labels.enumerated().map { index, label in
                SenseCandidate(entryID: "e", key: "\(index)", keyKind: .position, text: "s\(index)", partOfSpeech: label)
            }
            return LegacyPartOfSpeechNarrowing.narrow(field, to: tag).map(\.partOfSpeech)
        }
        #expect(kept(["noun", "plural noun", "transitive verb"], "noun") == ["noun", "plural noun"])
        #expect(kept(["verb", "transitive verb", "intransitive verb", "noun"], "verb")
            == ["verb", "transitive verb", "intransitive verb"])
        #expect(kept(["verb", "adverb", "adverb phrase"], "verb") == ["verb"])
        #expect(kept(["n.", "vt.", "vi."], "noun") == ["n.", "vt.", "vi."])
        #expect(kept(["noun", "verb"], nil) == ["noun", "verb"])
        #expect(kept(["noun", nil], "noun") == ["noun"])
        #expect(kept([nil, nil], "noun") == [nil, nil])
    }

    private static let hold = [
        SenseCandidate(entryID: "h1", key: "h.1", keyKind: .publisher, text: "grasp", partOfSpeech: "verb"),
        SenseCandidate(entryID: "h2", key: "h.2", keyKind: .publisher, text: "cargo space", partOfSpeech: "noun"),
    ]

    private static func labelled(tag: String?) -> SenseEvaluation.Labelled {
        .init(case: .init(id: "c", group: "hold", word: "hold", correct: "h.2", sentence: "The ship's hold was full.",
                          note: ""),
              candidates: hold, tag: tag)
    }

    /// **What the comparator measures, shown.** A wrong tag left the narrowing one sense and settled it unscored —
    /// confidently wrong; the bonus keeps both, and the sentence decides.
    @Test func aWrongTagSettlesTheComparatorAndNotTheBonus() {
        let ranked = [(Self.hold[1], 0.30), (Self.hold[0], 0.70)].map { (candidate: $0.0, distance: $0.1) }
        let wrong = Self.labelled(tag: "verb")
        #expect(SenseEvaluation.Variant.legacyNarrowing.answer(wrong, ranked: ranked)
            == .chose(key: "h.1", margin: .infinity, entryID: "h1"))
        #expect(SenseEvaluation.Variant.bonus(0.1).answer(wrong, ranked: ranked).key == "h.2")
        #expect(SenseEvaluation.Variant.bonus(0).answer(wrong, ranked: ranked).key == "h.2")
    }

    @Test func theKindsAreReadOffTheData() {
        #expect(Self.labelled(tag: "verb").kinds.contains(.tagDisagrees))
        #expect(Self.labelled(tag: "noun").kinds.contains(.tagAgrees))
        #expect(Self.labelled(tag: nil).kinds.contains(.untagged))
        #expect(Self.labelled(tag: "noun").kinds.contains(.crossPartOfSpeech))
        let abstain = SenseEvaluation.Labelled(
            case: .init(id: "a", group: "hold", word: "holds", correct: nil, sentence: "s", note: ""),
            candidates: Self.hold, tag: "noun")
        #expect(abstain.kinds == [.abstention])
    }

    // MARK: Choosing the weight, and the verdict

    private static func outcome(right: Int, wrong: Int, of total: Int, offset: Int = 0) -> SenseEvaluation.Outcomes {
        var outcome = SenseEvaluation.Outcomes()
        for index in 0 ..< total {
            let slot = (index + offset) % total
            outcome.buckets["c\(index)"] = slot < right ? .right : slot < right + wrong ? .wrong : .abstained
        }
        return outcome
    }

    private static func ids(_ total: Int) -> [String] { (0 ..< total).map { "c\($0)" } }

    /// The most right answers among the weights wrong no more often than either comparator; ties to the smaller.
    @Test func theWeightIsTheMostRightThatIsNotWrongMoreOften() {
        var arms: [SenseEvaluation.Variant: SenseEvaluation.Outcomes] = [
            .bonus(0): Self.outcome(right: 50, wrong: 30, of: 200),
            .legacyNarrowing: Self.outcome(right: 55, wrong: 25, of: 200),
            .bonus(0.05): Self.outcome(right: 60, wrong: 25, of: 200),
            .bonus(0.075): Self.outcome(right: 60, wrong: 20, of: 200),
            .bonus(0.2): Self.outcome(right: 80, wrong: 26, of: 200),
        ]
        // 0.2 is the most right and wrong once more than the legacy narrowing: refused. 0.05 and 0.075 tie: the smaller.
        #expect(SenseEvaluation.chooseWeight(arms, over: Self.ids(200)) == 0.05)
        // Nothing beats zero's right answers: zero.
        arms[.bonus(0.05)] = Self.outcome(right: 50, wrong: 20, of: 200)
        arms[.bonus(0.075)] = Self.outcome(right: 50, wrong: 20, of: 200)
        arms[.bonus(0.2)] = Self.outcome(right: 50, wrong: 20, of: 200)
        #expect(SenseEvaluation.chooseWeight(arms, over: Self.ids(200)) == 0)
    }

    /// **The positive controls for the verdict**: it enables on a clear, safe gain, and each condition can refuse.
    @Test func theVerdictEnablesOnlyWhatTheHeldOutSetShows() {
        let ids = Self.ids(400)
        let zero = Self.outcome(right: 100, wrong: 40, of: 400)
        // The narrowing: ten more right than zero, its forty wrong in the same places.
        var legacy = zero
        for index in 170 ..< 180 { legacy.buckets["c\(index)"] = .right }
        // Thirty more right, the same forty wrong in the same places.
        var clear = zero
        for index in 140 ..< 170 { clear.buckets["c\(index)"] = .right }
        #expect(SenseEvaluation.verdict(for: 0.05, [.bonus(0): zero, .legacyNarrowing: legacy, .bonus(0.05): clear],
                                        over: ids) == .enable(0.05))

        // One more confidently wrong than either comparator: refused, however much it gained.
        var oneWorse = clear
        oneWorse.buckets["c399"] = .wrong
        guard case .notShown(let reasons) = SenseEvaluation.verdict(
            for: 0.05, [.bonus(0): zero, .legacyNarrowing: legacy, .bonus(0.05): oneWorse], over: ids)
        else { Issue.record("one more wrong answer was enabled"); return }
        #expect(reasons.contains { $0.hasPrefix("more confidently wrong than w = 0") })

        // A gain of one is not measurable on 400.
        var tiny = zero
        tiny.buckets["c150"] = .right
        guard case .notShown(let small) = SenseEvaluation.verdict(
            for: 0.05, [.bonus(0): zero, .legacyNarrowing: legacy, .bonus(0.05): tiny], over: ids)
        else { Issue.record("a one-case gain was enabled"); return }
        #expect(small.contains { $0.hasPrefix("no measurable gain") })

        #expect(SenseEvaluation.verdict(for: 0, [:], over: ids) == .zeroChosen)
    }
}
