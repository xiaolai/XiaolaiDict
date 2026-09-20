@testable import DictionaryBridge
import Foundation
import XiaolaiDictCore
import Testing

/// One labelled case: a sentence the reader might be reading, and the sense of it NOAD actually
/// means. The keys are NOAD's own, read out of the live entries.
struct LabelledCase: Sendable {
    let word: String
    let sentence: String
    /// The correct sense key, or nil when the right answer is to abstain.
    let correct: String?
    let why: String
}

/// Rung 1 against the hard cases, scored on the three numbers the plan requires — **top-1
/// accuracy, abstention rate, and confidently-wrong rate**. The third is the one that decides
/// whether marking a sense is honest at all.
///
/// Note what the first two cases test: for *fine* and *hold* the correct sense lives in a
/// **different entry** from the one the old `.first` code showed at all, so this set cannot be
/// passed without Stage 0.
struct SenseSelectionAccuracyTests {
    static let hardCases: [LabelledCase] = [
        LabelledCase(
            word: "fine", sentence: "He was ordered to pay a heavy fine for speeding.",
            correct: "m_en_gbus0362760.005",
            why: "the penalty is homograph 2; homograph 1 owns “made or done very well”"),
        LabelledCase(
            word: "hold",
            sentence: "It was stowed forward in the ship's hold, where the rats had got at the biscuit.",
            correct: "m_en_gbus0472980.005",
            why: "the ship's hold is homograph 2, one sense against homograph 1's eleven"),
        LabelledCase(
            word: "sanction", sentence: "The committee sanctioned the plan after months of debate.",
            correct: "m_en_gbus0897260.018",
            why: "a contronym: the neighbouring verb sense is “impose a penalty on”"),
        LabelledCase(
            word: "table", sentence: "The committee voted to table the motion until the next session.",
            correct: "m_en_gbus1025140.042",
            why: "the neighbouring verb sense is its near-opposite"),
        LabelledCase(
            word: "rein", sentence: "The government kept a tight rein on public spending.",
            correct: "m_en_gbus0858530.009",
            why: "figurative, against a literal horse strap in the same block"),
        LabelledCase(
            word: "temper", sentence: "He tempered his criticism with praise.",
            correct: "m_en_gbus1038310.022",
            why: "the verb “moderate”, against “harden steel” and “tune a piano”"),
    ]

    /// Every sense NOAD has for `word`, across all of its entries — which is what the primary
    /// dictionary offers the selector.
    static func candidates(for word: String) throws -> [SenseCandidate] {
        let entries = try DictionaryBridge.entries(for: word).entries
            .filter { $0.dictionary.name.contains("New Oxford American") }
        try #require(!entries.isEmpty, "NOAD is not enabled in Dictionary.app on this Mac")
        return entries.flatMap { entry in
            entry.blocks.flatMap { block in
                block.senses.map {
                    SenseCandidate(
                        entryID: entry.entryID ?? "", key: $0.key ?? "", keyKind: $0.keyKind,
                        text: $0.text, partOfSpeech: block.partOfSpeech)
                }
            }
        }
    }

    /// The three numbers, for one selector, over the labelled set.
    /// **Four buckets, not three.** A sense shown under an *ambiguous* badge is not a confident
    /// answer and must not be scored as one: the whole point of that badge is that the card is
    /// telling the reader it does not know, with the alternatives already open in front of them.
    /// Folding those into `wrong` would make the number that decides honesty say something it
    /// does not mean; folding them into `right` would be worse.
    ///
    /// `abstained` now means *said nothing at all*. What used to live there — every `.tooClose`
    /// in this suite — is `ambiguous`, and the invariant that matters is unchanged: **`wrong`
    /// must not rise.** `ambiguous` is tracked beside it so a rung that buys accuracy by hedging
    /// shows up as hedging rather than as an improvement.
    struct Score: Equatable {
        var right = 0, wrong = 0, abstained = 0
        /// Shown with its uncertainty on the card. Split by whether the sense it led with was in
        /// fact the right one, because a hedge that is usually right and one that is usually
        /// wrong are different things to ship.
        var ambiguousRight = 0, ambiguousWrong = 0
        var report = ""

        var ambiguous: Int { ambiguousRight + ambiguousWrong }
    }

    static func score(_ selector: some SenseSelecting, named: String) async throws -> Score {
        var score = Score()
        score.report = "\n\(named) — on \(hardCases.count) hard cases\n"
        for labelled in hardCases {
            let candidates = try candidates(for: labelled.word)
            let partOfSpeech = Lemmatizer.partOfSpeech(
                of: labelled.word, in: labelled.sentence, at: nil)
            let choice = await selector.choose(
                from: candidates, reading: labelled.sentence, context: .complete, partOfSpeech: partOfSpeech)
            switch choice {
            case .chose(let key, let margin, _):
                let right = key == labelled.correct
                right ? (score.right += 1) : (score.wrong += 1)
                let text = candidates.first { $0.key == key }?.text.prefix(46) ?? ""
                score.report += "  \(right ? "✓" : "✗") \(labelled.word.padded(10))"
                    + " [\(partOfSpeech ?? "?")] \(key)  margin \(String(format: "%.4f", margin))  \(text)\n"
            case .abstained(let why, let nearest):
                if let nearest {
                    // It declined to choose and kept a favourite. The card shows that favourite
                    // under an ambiguous badge, so the score has to grade what the reader sees.
                    let right = nearest.key == labelled.correct
                    right ? (score.ambiguousRight += 1) : (score.ambiguousWrong += 1)
                    let text = candidates.first { $0.key == nearest.key }?.text.prefix(40) ?? ""
                    score.report += "  ? \(labelled.word.padded(10))"
                        + " [\(partOfSpeech ?? "?")] \(right ? "led right" : "led wrong")"
                        + "  margin \(String(format: "%.4f", nearest.margin))  \(text)\n"
                } else {
                    score.abstained += 1
                    score.report += "  — \(labelled.word.padded(10)) [\(partOfSpeech ?? "?")] said nothing: \(why.rawValue)\n"
                }
            }
            // Whatever it says, it can only say one of the things it was given.
            if let key = choice.key { #expect(candidates.map(\.key).contains(key)) }
        }
        let total = Double(hardCases.count)
        score.report += """
              top-1 accuracy       \(String(format: "%.0f%%", Double(score.right) / total * 100))  (\(score.right)/\(hardCases.count))
              ambiguous            \(String(format: "%.0f%%", Double(score.ambiguous) / total * 100))  (\(score.ambiguous)/\(hardCases.count)) — led right \(score.ambiguousRight), led wrong \(score.ambiguousWrong)
              said nothing         \(String(format: "%.0f%%", Double(score.abstained) / total * 100))  (\(score.abstained)/\(hardCases.count))
              confidently wrong    \(String(format: "%.0f%%", Double(score.wrong) / total * 100))  (\(score.wrong)/\(hardCases.count))

            """
        return score
    }

    /// The labels must name senses that exist, or the score would be measuring the labels.
    @Test func everyLabelNamesASenseThatExists() throws {
        for labelled in Self.hardCases {
            let keys = try Self.candidates(for: labelled.word).map(\.key)
            #expect(keys.contains(labelled.correct!), "\(labelled.word): \(labelled.correct!) is not among \(keys)")
        }
    }

    /// The set is only hard if the answer is not the first sense anyway — a selector that always
    /// said "sense 1" must not score well on it.
    @Test func theSetIsNotPassedByAlwaysPickingTheFirstSense() throws {
        var wouldBeRight = 0
        for labelled in Self.hardCases {
            let first = try Self.candidates(for: labelled.word).first?.key
            if first == labelled.correct { wouldBeRight += 1 }
        }
        #expect(wouldBeRight == 0, "\(wouldBeRight) of the hard cases are answered by picking sense 1")
    }

    /// Rung 1 exactly as pre-registered: `NLEmbedding` cosine distance and nothing else.
    ///
    /// The numbers are **pinned, not hoped for**. They were 2 right, 2 wrong, 2 abstained when
    /// measured on 2026-09-19, and a change in any of them is a finding — an Apple dictionary
    /// content update, or a change in this code — rather than a test to relax.
    @Test func rungOneIsMeasuredOnTheLabelledSet() async throws {
        let score = try await Self.score(
            EmbeddingSenseSelector(matchesPartOfSpeech: false), named: "rung 1 — NLEmbedding alone")
        print(score.report)
        try? score.report.write(toFile: "/tmp/xiaolaidict-probe/rung1.txt", atomically: true, encoding: .utf8)
        #expect(
            score.right + score.wrong + score.abstained + score.ambiguous == Self.hardCases.count,
            "a case was not scored")
        #expect(score.right == 2, "top-1 accuracy moved")
        #expect(score.wrong == 2, "the confidently-wrong rate moved — the number that decides honesty")
        // Both of its abstentions kept a favourite, so both are now shown under an ambiguous
        // badge rather than as silence. **Neither favourite was the right sense.**
        #expect(score.abstained == 0, "it said nothing at all, which it did not used to do")
        #expect(score.ambiguousRight == 0, "the hedge started leading right")
        #expect(score.ambiguousWrong == 2, "the hedge stopped leading wrong")
    }

    /// Rung 1 with the part-of-speech constraint the entries already carry.
    ///
    /// Not a tuned threshold: every sense sits in an `x_xd0` block labelled with `d:pos`, and
    /// `NLTagger` — already linked for lemmas — says how the word is being used. A word used as a
    /// noun cannot mean a verb sense. This was added because of *how* rung 1 failed, not to make a
    /// number go up: it chose the verb "to hold something back" for the noun in "kept a tight
    /// rein on public spending", getting the meaning right and the grammar wrong.
    @Test func thePartOfSpeechConstraintIsMeasuredToo() async throws {
        let score = try await Self.score(
            EmbeddingSenseSelector(), named: "rung 1b — NLEmbedding + part of speech")
        print(score.report)
        try? score.report.write(toFile: "/tmp/xiaolaidict-probe/rung1b.txt", atomically: true, encoding: .utf8)
        #expect(
            score.right + score.wrong + score.abstained + score.ambiguous == Self.hardCases.count,
            "a case was not scored")
        // Pinned as measured, in the same spirit as rung 1's. It fixed *rein* — the case that
        // prompted it — and it no longer costs *sanction*.
        //
        // **Re-measured 2026-09-20, and the trade got better.** `Lemmatizer.partOfSpeech` used to
        // run its own word search: any supplied range taken on trust, and a bare substring
        // fallback that matched inside longer words and silently took the first of a repeated
        // word. It now asks `occurrence(of:in:at:)`, which checks word boundaries and answers nil
        // where the sentence is ambiguous — which is what this function's own contract already
        // promised. *sanction* tags as `[?]` under it and abstains, where the loose match had
        // given it a part of speech confident enough to be wrong with.
        //
        // Confidently wrong 2 → 1 (33% → 17%) at unchanged accuracy. The abstention it buys that
        // back with is the cheap half of the trade: this project's rule is that a wrong mark is
        // worse than no mark.
        #expect(score.right == 3, "top-1 accuracy moved")
        #expect(score.wrong == 1, "the confidently-wrong rate moved")
        #expect(score.abstained == 0, "it said nothing at all, which it did not used to do")
        // **The finding that matters about leading with a near miss.** Both of this rung's
        // abstentions kept a favourite, and both favourites were the wrong sense — at margins of
        // 0.0103 and 0.0015, which is noise rather than a preference. Showing them is defensible
        // only because the card badges them and opens the alternatives; on this evidence the
        // favourite itself carries no signal, and that is pinned here so it is impossible to
        // believe otherwise without re-measuring.
        #expect(score.ambiguousRight == 0, "the hedge started leading right — re-read the trade")
        #expect(score.ambiguousWrong == 2, "the hedge stopped leading wrong")
    }

    /// The D6 comparison itself, run rather than asserted in prose: a rung ships only if it gains
    /// **≥ 10 points of top-1 accuracy** and its **confidently-wrong rate is no higher**. Both
    /// halves are checked, because a rung that buys accuracy by being wrong more often has bought
    /// nothing worth having.
    @Test func theHigherRungClearsTheMarginSetBeforeMeasuring() async throws {
        let base = try await Self.score(
            EmbeddingSenseSelector(matchesPartOfSpeech: false), named: "rung 1")
        let withPartOfSpeech = try await Self.score(EmbeddingSenseSelector(), named: "rung 1b")
        let total = Double(Self.hardCases.count)
        let gain = (Double(withPartOfSpeech.right) - Double(base.right)) / total * 100
        #expect(gain >= 10, "gained only \(gain) points, under the 10 fixed before measuring")
        #expect(withPartOfSpeech.wrong <= base.wrong, "it bought accuracy by being wrong more often")
    }

    /// The margin does **not** separate right answers from wrong ones on this set, so it cannot be
    /// used as a confidence gate — and raising it to make the numbers look better would be fitting
    /// the threshold to six cases, which is exactly what D6 forbids.
    @Test func theMarginDoesNotSeparateRightFromWrong() async throws {
        let selector = EmbeddingSenseSelector()
        var rightMargins: [Double] = [], wrongMargins: [Double] = []
        for labelled in Self.hardCases {
            let candidates = try Self.candidates(for: labelled.word)
            let partOfSpeech = Lemmatizer.partOfSpeech(of: labelled.word, in: labelled.sentence, at: nil)
            guard case .chose(let key, let margin, _) = await selector.choose(
                from: candidates, reading: labelled.sentence, context: .complete, partOfSpeech: partOfSpeech)
            else { continue }
            if key == labelled.correct { rightMargins.append(margin) } else { wrongMargins.append(margin) }
        }
        let worstRight = rightMargins.min() ?? 0
        let bestWrong = wrongMargins.max() ?? 0
        #expect(bestWrong > worstRight, """
            a wrong answer's margin (\(bestWrong)) no longer overlaps a right one's (\(worstRight)) — \
            re-check whether the margin has become a usable confidence gate
            """)
    }

    /// The canonical case from the plan, checked on its own so a regression names itself.
    @Test func theShipsHoldIsChosenOverTheElevenSensesOfTheOtherEntry() async throws {
        let candidates = try Self.candidates(for: "hold")
        #expect(candidates.count >= 12, "both entries' senses should be on offer, got \(candidates.count)")
        let choice = await EmbeddingSenseSelector().choose(
            from: candidates,
            reading: "It was stowed forward in the ship's hold, where the rats had got at the biscuit.",
            context: .complete)
        #expect(choice.key == "m_en_gbus0472980.005", "chose \(String(describing: choice))")
    }

    /// The three abstention cases, against real candidates rather than synthetic ones.
    @Test func theAbstentionCasesAbstain() async throws {
        let selector = EmbeddingSenseSelector()
        let fine = try Self.candidates(for: "fine")

        #expect(await selector.choose(from: fine, reading: nil, context: .missing).abstention == .noContext)
        #expect(await selector.choose(
            from: fine, reading: "He was ordered to pay a heavy", context: .mayBeCut).abstention == .noContext)

        // A dictionary that marks senses with nothing a parser can key to.
        let collins = try DictionaryBridge.entries(for: "fine").entries
            .filter { $0.dictionary.name.contains("Collins COBUILD") }
        try #require(!collins.isEmpty, "Collins COBUILD is not enabled on this Mac")
        let unkeyable = collins.flatMap { entry in
            entry.senses.map { SenseCandidate(entryID: entry.entryID ?? "", key: $0.key ?? "", keyKind: $0.keyKind, text: $0.text) }
        }
        #expect(await selector.choose(
            from: unkeyable, reading: "He paid the fine.", context: .complete).abstention == .noCandidates)
    }
}

private extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

/// Rung 2 — Apple's on-device model — measured against the same labelled set and the same candidate
/// sets as rung 1, so the comparison D6 turns on is like for like.
///
/// It runs only where Apple Intelligence is available: `deviceNotEligible` on the development Mac
/// and `available` on the E2E machine, both measured. Where it is not available the selector
/// abstains, which is the behaviour that ships on every Mac without it — and in mainland China,
/// a core audience, where it is unavailable outright.
struct FoundationModelsRungTests {
    @Test func rungTwoIsMeasuredWhereItCanRun() async throws {
        let selector = FoundationModelsSenseSelector()
        // Does it run here at all? One probe, so an unavailable machine reports that rather than
        // reporting six abstentions as if they were a score.
        let probe = await selector.choose(
            from: try SenseSelectionAccuracyTests.candidates(for: "hold"),
            reading: "It was stowed forward in the ship's hold.", context: .complete, partOfSpeech: "noun")
        guard probe.abstention != .unavailable else {
            print("\nrung 2 — Apple on-device model: UNAVAILABLE on this Mac, not measured\n")
            return
        }
        let bare = try await SenseSelectionAccuracyTests.score(
            FoundationModelsSenseSelector(matchesPartOfSpeech: false),
            named: "rung 2 — Apple on-device model")
        let narrowed = try await SenseSelectionAccuracyTests.score(
            selector, named: "rung 2b — Apple on-device model + part of speech")
        print(bare.report + narrowed.report)
        try? (bare.report + narrowed.report).write(
            toFile: "/tmp/xiaolaidict-probe/rung2.txt", atomically: true, encoding: .utf8)
        for score in [bare, narrowed] {
            #expect(score.right + score.wrong + score.abstained == SenseSelectionAccuracyTests.hardCases.count)
        }
        // The D6 bar, fixed before any of this was run: ≥ 10 points of top-1 over rung 1, and a
        // confidently-wrong rate no higher.
        let rungOne = try await SenseSelectionAccuracyTests.score(
            EmbeddingSenseSelector(matchesPartOfSpeech: false), named: "rung 1")
        let total = Double(SenseSelectionAccuracyTests.hardCases.count)
        let gain = (Double(narrowed.right) - Double(rungOne.right)) / total * 100
        #expect(gain >= 10, "rung 2 gained only \(gain) points over rung 1")
        #expect(narrowed.wrong <= rungOne.wrong, "rung 2 bought accuracy by being wrong more often")
        // A floor rather than a pin: the model is not deterministic, so an exact score would be a
        // flaky test. It scored 6/6 with 0 wrong on 2026-09-19; below this it has regressed.
        #expect(narrowed.right >= 4, "rung 2 fell to \(narrowed.right)/6")
        #expect(narrowed.wrong <= 1, "rung 2 is confidently wrong \(narrowed.wrong) times in 6")
    }

    /// Whatever it answers is one of the senses it was given. The model returns a *number*, checked
    /// against the list mechanically, so it cannot name a sense that does not exist.
    @Test func itCannotInventASense() async throws {
        let candidates = try SenseSelectionAccuracyTests.candidates(for: "fine")
        let choice = await FoundationModelsSenseSelector().choose(
            from: candidates, reading: "He was ordered to pay a heavy fine for speeding.",
            context: .complete, partOfSpeech: "noun")
        if let key = choice.key { #expect(candidates.map(\.key).contains(key)) }
    }

    /// The contract holds identically whether or not the model is there: no sentence, no choice.
    @Test func itAbstainsWithoutAWholeSentence() async throws {
        let candidates = try SenseSelectionAccuracyTests.candidates(for: "fine")
        let selector = FoundationModelsSenseSelector()
        #expect(await selector.choose(
            from: candidates, reading: nil, context: .missing, partOfSpeech: nil).abstention == .noContext)
        #expect(await selector.choose(
            from: candidates, reading: "He paid the", context: .mayBeCut, partOfSpeech: nil).abstention == .noContext)
    }
}
