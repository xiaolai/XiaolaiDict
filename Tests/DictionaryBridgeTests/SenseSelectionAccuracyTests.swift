@testable import DictionaryBridge
import DictionaryModel
import Foundation
import Synchronization
@testable import XiaolaiDictCore
import Testing

/// Rung 1 against the hard cases, scored on the three numbers the plan requires — **top-1
/// accuracy, abstention rate, and confidently-wrong rate**. The third is the one that decides
/// whether marking a sense is honest at all.
///
/// Note what the first two cases test: for *fine* and *hold* the correct sense lives in a
/// **different entry** from the one the old `.first` code showed at all, so this set cannot be
/// passed without Stage 0.
struct SenseSelectionAccuracyTests {
    /// In `XiaolaiDictCore`, because `--sense-report` scores the same six inside the signed bundle —
    /// the only place the local model's rung runs through the real path.
    static let hardCases = LabelledSenses.hardCases

    /// Every sense NOAD has for `word`, across all of its entries — which is what the primary
    /// dictionary offers the selector.
    static func candidates(for word: String) throws -> [SenseCandidate] {
        // By identifier, never by display name: a name is localized, and a Chinese interface would
        // have this suite report NOAD as disabled on a Mac where it is enabled.
        let entries = try DictionaryBridge.entries(for: word).entries
            .filter { $0.dictionary.identifier == DictionaryIdentity.noad }
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
            let bucket = LabelledSenses.bucket(choice, correct: labelled.correct)
            switch choice {
            case .chose(let key, let margin, _):
                let right = bucket == .right
                right ? (score.right += 1) : (score.wrong += 1)
                let text = candidates.first { $0.key == key }?.text.prefix(46) ?? ""
                score.report += "  \(right ? "✓" : "✗") \(labelled.word.padded(10))"
                    + " [\(partOfSpeech ?? "?")] \(key)  margin "
                    + (margin.map { String(format: "%.4f", $0) } ?? "—") + "  \(text)\n"
            case .abstained(let why, let nearest):
                if let nearest {
                    // It declined to choose and kept a favourite. The card shows that favourite
                    // under an ambiguous badge, so the score has to grade what the reader sees.
                    let right = bucket == .ambiguousRight
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
            // The embedding rung is the one with a margin; a rung that reports none is not scored
            // on a gap it never measured.
            guard let margin else { continue }
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

    /// **The ceiling on any cascade**, measured before one is built.
    ///
    /// A shortlist hands the model the top K and nothing else, so a sense the shortlist dropped can
    /// never be recovered — the arrangement's accuracy is capped by this number. If recall@5 does
    /// not clear what the model scores unaided, a cascade is a way of making the good instrument
    /// worse, and the right move is not to build it.
    ///
    /// Reported, **not pinned**: six cases cannot carry a pinned expectation for a new
    /// measurement. One number here is worth reading closely though — `recall@all` below 6/6 means
    /// the part-of-speech filter dropped the labelled sense before anything was ranked, which
    /// would be a finding about the filter rather than about the ranking.
    @Test func theEmbeddingsRecallAtKIsMeasured() async throws {
        let selector = EmbeddingSenseSelector()
        var report = "\nembedding recall@K — on \(Self.hardCases.count) hard cases\n"
        for narrowing in [false, true] {
            var placings: [(word: String, place: Int?, among: Int)] = []
            for labelled in Self.hardCases {
                let partOfSpeech = narrowing
                    ? Lemmatizer.partOfSpeech(of: labelled.word, in: labelled.sentence, at: nil)
                    : nil
                let considered = SenseCandidates.considered(
                    try Self.candidates(for: labelled.word), matching: partOfSpeech)
                let ranked = selector.rank(considered, reading: labelled.sentence)
                let place = ranked.firstIndex { $0.candidate.key == labelled.correct }.map { $0 + 1 }
                placings.append((labelled.word, place, ranked.count))
            }
            report += "  \(narrowing ? "with" : "without") the part-of-speech filter\n"
            for placing in placings {
                let where_ = placing.place.map { "rank \($0)" } ?? "NOT RANKED"
                report += "    \(placing.word.padded(10)) \(where_.padded(12)) of \(placing.among)\n"
            }
            for k in [1, 3, 5, 10] {
                let hit = placings.filter { ($0.place ?? .max) <= k }.count
                report += "    \("recall@\(k)".padded(12)) \(hit)/\(placings.count)\n"
            }
            report += "    \("recall@all".padded(12)) \(placings.filter { $0.place != nil }.count)/\(placings.count)\n"
        }
        print(report)
        try? report.write(toFile: "/tmp/xiaolaidict-probe/recall.txt", atomically: true, encoding: .utf8)
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


/// **The three arrangements, measured against each other on one machine.**
///
/// 1 · the on-device model alone · 2 · `NLEmbedding` alone · 3 · the embedding shortlists and the
/// model decides among the shortlist.
///
/// Runs only where Apple Intelligence is available — `deviceNotEligible` on the development Mac,
/// `available` on the E2E machine — so on the build Mac this reports that it did not happen rather
/// than reporting a row of abstentions as a score.
///
/// **What this set can and cannot settle.** Configuration 1 already scores 6/6 on it, so the set is
/// saturated: no arrangement can win on accuracy here, and the only accuracy claim available is
/// *did 3 hold what 1 had*. One case is 17 points, so nothing smaller than a case is a difference.
/// The candidate sets are also small — 4 to 13 senses — while a shortlist is meant for a big
/// entry; NOAD's *run* is 27 keyable senses, 13 once narrowed to the verb, which is what
/// `thePromptShrinksOnAnEntryBigEnoughToShowIt` measures instead.
///
/// **`.serialized` because both tests here time the same on-device model.** Run in parallel they
/// contend for it and each reports the other's load: measured, configuration 1 came back at
/// ~1,020 ms beside a second model test and ~450 ms alone — a 2× error produced entirely by the
/// runner. This project's rules already say a wall-clock number measures how many other tests
/// are executing; that applies to a number *reported* as much as to one asserted.
@Suite(.serialized)
struct SelectorConfigurationTests {
    /// Wraps a selector and keeps how long each call took, so latency is measured around the thing
    /// under test rather than around the harness.
    private final class Timed: SenseSelecting, @unchecked Sendable {
        let inner: any SenseSelecting
        let calls = Mutex<[Duration]>([])
        init(_ inner: any SenseSelecting) { self.inner = inner }

        func choose(
            from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
            partOfSpeech: String?
        ) async -> SenseSelection {
            let started = ContinuousClock.now
            let answer = await inner.choose(
                from: candidates, reading: sentence, context: context, partOfSpeech: partOfSpeech)
            calls.withLock { $0.append(ContinuousClock.now - started) }
            return answer
        }

        /// Median and worst, in milliseconds. A mean would be led by one cold first call.
        var summary: String {
            let sorted = calls.withLock { $0 }.sorted()
            guard !sorted.isEmpty else { return "not called" }
            let ms = { (d: Duration) in Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
            return String(format: "median %.0f ms, worst %.0f ms", ms(sorted[sorted.count / 2]), ms(sorted[sorted.count - 1]))
        }
    }

    /// One probe, so an unavailable machine says so instead of scoring six abstentions.
    private static func modelRunsHere() async throws -> Bool {
        let probe = await FoundationModelsSenseSelector().choose(
            from: try SenseSelectionAccuracyTests.candidates(for: "hold"),
            reading: "It was stowed forward in the ship's hold.", context: .complete, partOfSpeech: "noun")
        return probe.abstention != .unavailable
    }

    @Test func theThreeConfigurationsAreMeasuredWhereTheModelCanRun() async throws {
        guard try await Self.modelRunsHere() else {
            print("\nselector configurations: Apple Intelligence UNAVAILABLE on this Mac, not measured\n")
            return
        }
        var report = "\nselector configurations — on \(SenseSelectionAccuracyTests.hardCases.count) hard cases\n"
        let model = FoundationModelsSenseSelector()
        let configurations: [(String, any SenseSelecting)] = [
            ("1 · model alone", model),
            ("2 · embedding alone", EmbeddingSenseSelector()),
            ("3 · shortlist 3 → model", ShortlistSenseSelector(shortlist: 3, decider: model)),
            ("3 · shortlist 5 → model", ShortlistSenseSelector(shortlist: 5, decider: model)),
        ]
        let warmUp = try SenseSelectionAccuracyTests.candidates(for: "hold")
        for (name, selector) in configurations {
            // **Discarded.** The first call against a cold model pays to load it: measured 1230 ms
            // on the first arrangement of a session against 446 ms once warm, which made whichever
            // configuration happened to run first look 3× slower than the rest. That is a fact
            // about the machine, not about the arrangement — the same trap this project already
            // records for the first screen capture after boot.
            _ = await selector.choose(
                from: warmUp, reading: "It was stowed forward in the ship's hold.",
                context: .complete, partOfSpeech: "noun")
            let timed = Timed(selector)
            let score = try await SenseSelectionAccuracyTests.score(timed, named: name)
            report += score.report + "      latency             \(timed.summary)\n"
        }
        print(report)
        try? report.write(
            toFile: "/tmp/xiaolaidict-probe/configurations.txt", atomically: true, encoding: .utf8)
    }

    /// The labelled set's entries are too small to show what a shortlist is *for*, so this measures
    /// the prompt on one that is not: *run* is the 73-sense case the shortlist exists for.
    ///
    /// No labels and no accuracy claim — it reports prompt size and latency, which is the whole
    /// argument for configuration 3.
    @Test func thePromptShrinksOnAnEntryBigEnoughToShowIt() async throws {
        let sentence = "She decided to run for office in the spring election."
        let partOfSpeech = Lemmatizer.partOfSpeech(of: "run", in: sentence, at: nil)
        let considered = SenseCandidates.considered(
            try SenseSelectionAccuracyTests.candidates(for: "run"), matching: partOfSpeech)
        let shortlisted = EmbeddingSenseSelector()
            .rank(considered, reading: sentence).prefix(5).map(\.candidate)
        // The prompt both model rungs send, from the one place it is written.
        let whole = ModelPrompt.sense(SenseQuestion(
            sentence: sentence, partOfSpeech: partOfSpeech, senses: considered.map(\.text)))
        let short = ModelPrompt.sense(SenseQuestion(
            sentence: sentence, partOfSpeech: partOfSpeech, senses: shortlisted.map(\.text)))

        let everything = SenseCandidates.considered(
            try SenseSelectionAccuracyTests.candidates(for: "run"), matching: nil)
        var report = """

            prompt size — run [\(partOfSpeech ?? "?")]
              keyable senses      \(everything.count)
              narrowed to \(partOfSpeech ?? "?")     \(considered.count) senses, \(whole.count) characters
              shortlist 5         \(shortlisted.count) senses, \(short.count) characters

            """
        guard try await Self.modelRunsHere() else {
            report += "  latency: Apple Intelligence UNAVAILABLE on this Mac, not measured\n"
            print(report)
            return
        }
        // **Interleaved, after a discarded warm-up.** Run one arrangement to completion and then
        // the other and the second one inherits a warmer model, which is how a 730 ms / 113 ms
        // "prompt size wins" reading was produced from the order alone. Alternating spreads any
        // drift across both.
        let arrangements = [("all senses", considered), ("shortlist 5", Array(shortlisted))]
        let timers = [Timed(FoundationModelsSenseSelector(matchesPartOfSpeech: false)),
                      Timed(FoundationModelsSenseSelector(matchesPartOfSpeech: false))]
        for (timer, arrangement) in zip(timers, arrangements) {
            _ = await timer.inner.choose(
                from: arrangement.1, reading: sentence, context: .complete, partOfSpeech: partOfSpeech)
        }
        for _ in 0..<5 {
            for (timer, arrangement) in zip(timers, arrangements) {
                _ = await timer.choose(
                    from: arrangement.1, reading: sentence, context: .complete,
                    partOfSpeech: partOfSpeech)
            }
        }
        for (timer, arrangement) in zip(timers, arrangements) {
            report += "  \(arrangement.0.padded(20))\(timer.summary)\n"
        }
        print(report)
        try? report.write(toFile: "/tmp/xiaolaidict-probe/prompt-size.txt", atomically: true, encoding: .utf8)
    }
}

/// **Does knowing the word class find the right entry?** — the measurement ADR-0004 turns on.
///
/// The cases are paired: each spelling appears once where the lemma's entry is right and once where
/// the surface's own entry is, so a resolver that always prefers one scores exactly half and a bias
/// cannot read as an improvement.
///
/// Scored on the embedding rung. Not the model rungs, and deliberately:
/// `dictionary-research/oracle-contamination` measured a local model reproducing eleven consecutive
/// words of Oxford's definition of *run* from memory, and these candidates *are* Oxford's text. The
/// embedding compares the reader's sentence against the sense wording — it has no memory of which
/// sense NOAD numbers what.
struct InflectedEntryChoiceTests {
    /// Prints both numbers rather than asserting one. What narrowing is worth is a measurement to
    /// be read and argued with, not a threshold to be defended — and a bar set from the first run
    /// would only ever record what this Mac did that day.
    @Test func narrowingByWordClassIsMeasuredOnBothHalvesOfEachPair() async throws {
        let selector = EmbeddingSenseSelector()
        var report = "\ninflected entry choice — \(LabelledSenses.inflectedCases.count) paired cases\n"
        var narrowedRight = 0, wideRight = 0, narrowedCandidates = 0, wideCandidates = 0

        for labelled in LabelledSenses.inflectedCases {
            let candidates = try SenseSelectionAccuracyTests.candidates(for: labelled.word)
            let partOfSpeech = Lemmatizer.partOfSpeech(
                of: labelled.word, in: labelled.sentence, at: nil)

            let wide = await selector.choose(
                from: candidates, reading: labelled.sentence, context: .complete, partOfSpeech: nil)
            let narrow = await selector.choose(
                from: candidates, reading: labelled.sentence, context: .complete,
                partOfSpeech: partOfSpeech)

            let wideOK = LabelledSenses.bucket(wide, correct: labelled.correct) == .right
            let narrowOK = LabelledSenses.bucket(narrow, correct: labelled.correct) == .right
            if wideOK { wideRight += 1 }
            if narrowOK { narrowedRight += 1 }
            wideCandidates += candidates.count
            narrowedCandidates += candidates.filter {
                guard let partOfSpeech, let its = $0.partOfSpeech else { return true }
                return its.split(separator: " ").contains(Substring(partOfSpeech))
            }.count

            report += "  \(labelled.word.padded(8)) [\(partOfSpeech ?? "?")]"
                + "  all: \(wideOK ? "✓" : "✗")   narrowed: \(narrowOK ? "✓" : "✗")"
                + "   \(labelled.why)\n"
        }
        report += "  ——\n"
        report += "  right without narrowing: \(wideRight)/\(LabelledSenses.inflectedCases.count)"
            + "   candidates seen: \(wideCandidates)\n"
        report += "  right with narrowing:    \(narrowedRight)/\(LabelledSenses.inflectedCases.count)"
            + "   candidates seen: \(narrowedCandidates)\n"
        print(report)

        // The one thing that must hold however the numbers land: narrowing must not make the
        // reader worse off. A filter that loses answers is worse than no filter.
        #expect(narrowedRight >= wideRight,
                "narrowing by word class lost answers it should have kept")
    }
}
