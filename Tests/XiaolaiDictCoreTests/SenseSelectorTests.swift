import DictionaryModel
import Synchronization
import XiaolaiDictCore
import Testing

/// The selector's contract, independent of how well any rung scores. **Abstention is mandatory**:
/// a selector forced to always answer will always answer.
struct SenseSelectorTests {
    private static func candidate(_ key: String, _ text: String, kind: SenseKeyKind = .publisher) -> SenseCandidate {
        SenseCandidate(entryID: "e", key: key, keyKind: kind, text: text)
    }

    private static let senses = [
        candidate("e.1", "money a court orders you to pay for breaking a rule"),
        candidate("e.2", "made or done very well indeed"),
        candidate("e.3", "clear and sunny weather, without rain"),
    ]

    private let selector = EmbeddingSenseSelector()

    /// The output is a closed-set choice. It cannot invent a sense, which is what makes this the
    /// safe use of a model rather than the risky one.
    ///
    /// **Required rather than unwrapped with `if let`.** Guarded that way it asserted nothing at
    /// all whenever the selector abstained, which is every way this can go wrong except the one it
    /// was written for — a sentence naming one sense outright is the case where a rung that
    /// answers nothing is itself the defect.
    @Test func whateverItChoosesIsOneOfTheCandidates() async throws {
        let choice = await selector.choose(
            from: Self.senses, reading: "He was ordered to pay a heavy fine for speeding.", context: .complete)
        let key = try #require(choice.key, "abstained as \(String(describing: choice.abstention))")
        #expect(Self.senses.map(\.key).contains(key), "chose \(key), which was never offered")
    }

    // MARK: - The three cases where it must not answer

    /// The case the request calls 再想别的办法: the sense is in no installed dictionary.
    @Test func nothingToChooseBetweenIsAnAbstention() async {
        #expect(await selector.choose(from: [], reading: "anything", context: .complete)
            == .abstained(.noCandidates))
    }

    /// No sentence, no disambiguation. This is not a failure to report — it is the answer.
    @Test(arguments: [CaptureQuality.Context.missing, .mayBeCut])
    func withoutAWholeSentenceItAbstains(context: CaptureQuality.Context) async {
        let choice = await selector.choose(from: Self.senses, reading: "He paid the fine.", context: context)
        #expect(choice == .abstained(.noContext))
    }

    @Test func anEmptySentenceIsNoSentence() async {
        #expect(await selector.choose(from: Self.senses, reading: "   ", context: .complete)
            == .abstained(.noContext))
        #expect(await selector.choose(from: Self.senses, reading: nil, context: .complete)
            == .abstained(.noContext))
    }

    /// Two senses this instrument cannot separate must not be separated by rounding.
    @Test func sensesTooCloseToSeparateAreNotSeparated() async {
        let twins = [Self.candidate("e.1", "a warm drink"), Self.candidate("e.2", "a warm drink")]
        let choice = await selector.choose(from: twins, reading: "She made a warm drink.", context: .complete)
        #expect(choice.abstention == .tooClose)
        #expect(choice.key == nil, "a near miss is not a choice and must not answer as one")
    }

    /// **The favourite is kept, not chosen.** Declining to choose used to throw away the sense the
    /// selector was a hair from picking, and the panel could then say nothing but "several senses
    /// fit this sentence equally well" — a non-answer to a reader who had just pointed at a word.
    /// The near miss is what lets the card lead with something and badge it as unsure.
    @Test func decliningBecauseSeveralFitKeepsTheOneItNearlyPicked() async throws {
        let twins = [Self.candidate("e.1", "a warm drink"), Self.candidate("e.2", "a warm drink")]
        let choice = await selector.choose(from: twins, reading: "She made a warm drink.", context: .complete)
        let nearest = try #require(choice.nearest, "the favourite was discarded")
        #expect(twins.map(\.key).contains(nearest.key), "the near miss is not one of the candidates")
        #expect(nearest.among == twins.count)
        // Below the margin it needs to commit — which is exactly why it is a near miss.
        #expect(nearest.margin < 1)
    }

    /// **Only `.tooClose` has one.** Nothing fitting is not a narrow decision, and offering the
    /// least-bad candidate there would be inventing an answer rather than hedging one.
    ///
    /// `.nothingFits` is forced the way `nothingCloseEnoughIsAnAbstention` forces it — by the
    /// distance, not by hoping an unrelated sense scores badly enough. Guarded by
    /// `if … == .nothingFits` over the default 1.45, the assertion inside simply never ran: the
    /// one candidate is always the favourite, so the selector chose it and the guard was false.
    @Test func theOtherAbstentionsKeepNothing() async {
        let strict = EmbeddingSenseSelector(maximumDistance: 0.0001)
        let nothingFits = await strict.choose(
            from: Self.senses, reading: "She made a warm drink.", context: .complete)
        #expect(nothingFits.abstention == .nothingFits)
        #expect(nothingFits.nearest == nil)

        let noContext = await selector.choose(from: Self.senses, reading: nil, context: .complete)
        #expect(noContext.abstention == .noContext)
        #expect(noContext.nearest == nil)
    }

    /// A dictionary whose senses cannot be keyed can never yield a sense-level choice, however
    /// well its text happens to match.
    @Test func aDictionaryThatCannotKeyItsSensesYieldsNoSenseChoice() async {
        let unkeyable = Self.senses.map {
            SenseCandidate(entryID: $0.entryID, key: $0.key, keyKind: SenseKeyKind.none, text: $0.text)
        }
        let choice = await selector.choose(
            from: unkeyable, reading: "He was ordered to pay a heavy fine.", context: .complete)
        #expect(choice == .abstained(.noCandidates))
    }

    /// One sense is not a choice, and is not credited to the selector as one.
    ///
    /// **The margin is the load-bearing half, not the key.** `.infinity` is what the resolver reads
    /// as "nothing was chosen, so nothing can be wrong" and turns into `chosenBy: .onlySense` —
    /// the distinction the ledger's *`chosen_by` never merges* invariant rests on. Asserting the
    /// key alone, a selector that returned a finite margin here would pass while every one of those
    /// encounters was filed as the selector's own guess.
    @Test func aSingleCandidateIsNotAChoiceTheSelectorMade() async {
        let choice = await selector.choose(
            from: [Self.candidate("e.1", "a penalty")], reading: "He paid it.", context: .complete)
        #expect(choice == .chose(key: "e.1", margin: .infinity, entryID: "e"))
    }

    /// Nothing close enough is an abstention, not a least-bad pick.
    @Test func nothingCloseEnoughIsAnAbstention() async {
        let strict = EmbeddingSenseSelector(maximumDistance: 0.0001)
        let choice = await strict.choose(
            from: Self.senses, reading: "He was ordered to pay a heavy fine.", context: .complete)
        #expect(choice == .abstained(.nothingFits))
    }

    /// A language with no embedding is a selector that could not run — said plainly, never turned
    /// into a guess.
    @Test func noEmbeddingForTheLanguageIsAnAbstention() async {
        let none = EmbeddingSenseSelector(embedding: { _ in nil })
        let choice = await none.choose(
            from: Self.senses, reading: "He was ordered to pay a heavy fine.", context: .complete)
        #expect(choice == .abstained(.unavailable))
    }
}

/// The ladder falls through when a rung is *absent*, and never when a rung has *decided*.
struct LadderSenseSelectorTests {
    private struct Fixed: SenseSelecting {
        let answer: SenseSelection
        func choose(
            from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
            partOfSpeech: String?
        ) async -> SenseSelection { answer }
    }

    private static let candidates = [
        SenseCandidate(entryID: "e", key: "e.1", keyKind: .publisher, text: "one"),
        SenseCandidate(entryID: "e", key: "e.2", keyKind: .publisher, text: "two"),
    ]

    private func choose(_ rungs: [any SenseSelecting]) async -> SenseSelection {
        await LadderSenseSelector(rungs: rungs).choose(
            from: Self.candidates, reading: "a sentence", context: .complete, partOfSpeech: nil)
    }

    @Test func anAbsentRungFallsThroughToTheNext() async {
        let choice = await choose([
            Fixed(answer: .abstained(.unavailable)), Fixed(answer: .chose(key: "e.2", margin: 0.4)),
        ])
        #expect(choice == .chose(key: "e.2", margin: 0.4))
    }

    /// The failure mode this guards: a rung that says "several senses fit" has **decided**, and
    /// asking a weaker rung until one answers is how a selector ends up always answering.
    @Test(arguments: [Abstention.tooClose, .nothingFits, .noContext, .noCandidates])
    func aRungThatDecidedIsNotOverruledByALowerOne(decision: Abstention) async {
        let choice = await choose([
            Fixed(answer: .abstained(decision)), Fixed(answer: .chose(key: "e.1", margin: 9)),
        ])
        #expect(choice == .abstained(decision), "a real abstention was overruled by a lower rung")
    }

    @Test func theTopRungsAnswerWins() async {
        let choice = await choose([
            Fixed(answer: .chose(key: "e.1", margin: 0.2)), Fixed(answer: .chose(key: "e.2", margin: 0.9)),
        ])
        #expect(choice.key == "e.1")
    }

    /// Every rung absent is still an honest answer: nothing could run.
    @Test func everyRungAbsentIsUnavailable() async {
        #expect(await choose([Fixed(answer: .abstained(.unavailable))]) == .abstained(.unavailable))
        #expect(await choose([]) == .abstained(.unavailable))
    }

    /// A refusal falls through — the next rung is the right answer to a model that declined — and
    /// a lower rung's answer then stands as its own.
    @Test func aRefusalFallsThroughToTheNextRung() async {
        let choice = await choose([
            Fixed(answer: .abstained(.refused)), Fixed(answer: .chose(key: "e.2", margin: 0.4)),
        ])
        #expect(choice == .chose(key: "e.2", margin: 0.4))
    }

    /// **"The model declined" is not "no model here".** Where nothing below a refusal can run either,
    /// the refusal is what the lookup reports — whichever order the absence and the refusal came in.
    @Test func aRefusalNobodyBelowCouldAnswerIsReportedAsARefusal() async {
        #expect(await choose([Fixed(answer: .abstained(.refused)), Fixed(answer: .abstained(.unavailable))])
            == .abstained(.refused))
        #expect(await choose([Fixed(answer: .abstained(.unavailable)), Fixed(answer: .abstained(.refused))])
            == .abstained(.refused))
    }
}

/// The cascade: rank with the cheap instrument, decide with the expensive one.
struct ShortlistSenseSelectorTests {
    /// Records what it was handed, so the shortlist itself can be asserted rather than inferred
    /// from the answer.
    private final class Spy: SenseSelecting, @unchecked Sendable {
        let saw = Mutex<[SenseCandidate]>([])
        let sawPartOfSpeech = Mutex<String??>(nil)
        func choose(
            from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
            partOfSpeech: String?
        ) async -> SenseSelection {
            saw.withLock { $0 = candidates }
            sawPartOfSpeech.withLock { $0 = partOfSpeech }
            return .chose(key: candidates[0].key, margin: 1, entryID: candidates[0].entryID)
        }
    }

    private static func sense(_ key: String, _ text: String, pos: String? = nil) -> SenseCandidate {
        SenseCandidate(entryID: "e", key: key, keyKind: .publisher, text: text, partOfSpeech: pos)
    }

    private static let many = (1...9).map { sense("e.\($0)", "sense number \($0)") }

    @Test func itHandsTheDeciderOnlyTheShortlist() async {
        let spy = Spy()
        _ = await ShortlistSenseSelector(shortlist: 3, decider: spy).choose(
            from: Self.many, reading: "a sentence about number four", context: .complete)
        #expect(spy.saw.withLock { $0.count } == 3)
    }

    /// **The rule that keeps the cascade from being worse than the rung it wraps.** Where the
    /// embedding cannot run — every `zh-Hant`, `ja` and `ko` sentence, measured 2026-09-22 — the
    /// decider must still see everything. Abstaining here would take the only rung those readers
    /// have and hand them nothing.
    @Test func aShortlistItCouldNotBuildHandsTheDeciderEverything() async {
        let spy = Spy()
        let cascade = ShortlistSenseSelector(
            shortlist: 3, decider: spy, ranker: EmbeddingSenseSelector(embedding: { _ in nil }))
        let choice = await cascade.choose(
            from: Self.many, reading: "a sentence", context: .complete)
        #expect(spy.saw.withLock { $0.count } == Self.many.count, "the decider was starved")
        #expect(choice.abstention == nil, "an unrankable sentence became an abstention")
    }

    /// Narrowing happens once, here, so the decider is never asked to narrow a different set —
    /// otherwise the comparison between configurations would be reading the narrowing.
    @Test func itNarrowsByPartOfSpeechBeforeRanking() async {
        let spy = Spy()
        let mixed = [
            Self.sense("e.1", "to do something", pos: "verb"),
            Self.sense("e.2", "a thing", pos: "noun"),
            Self.sense("e.3", "another thing", pos: "noun"),
        ]
        _ = await ShortlistSenseSelector(shortlist: 9, decider: spy).choose(
            from: mixed, reading: "a sentence", context: .complete, partOfSpeech: "noun")
        #expect(spy.saw.withLock { $0.map(\.key) } == ["e.2", "e.3"])
        // Passed on regardless: the decider may want it for its prompt, and narrowing an
        // already-narrowed set is a no-op.
        #expect(spy.sawPartOfSpeech.withLock { $0 } == "noun")
    }

    /// A shortlist longer than the field is the field, and the cascade degenerates to the decider
    /// alone rather than doing something clever.
    @Test func aShortlistLongerThanTheFieldIsTheField() async {
        let spy = Spy()
        _ = await ShortlistSenseSelector(shortlist: 99, decider: spy).choose(
            from: Self.many, reading: "a sentence", context: .complete)
        #expect(spy.saw.withLock { $0.count } == Self.many.count)
    }

    /// The pre-rung refusals belong to the cascade, not to the decider: a model must not be woken
    /// up to be told there was nothing to choose between.
    @Test func itRefusesBeforeWakingTheDecider() async {
        let spy = Spy()
        let cascade = ShortlistSenseSelector(shortlist: 3, decider: spy)
        #expect(await cascade.choose(from: Self.many, reading: nil, context: .missing)
            == .abstained(.noContext))
        let unkeyable = [SenseCandidate(entryID: "e", key: "", keyKind: .none, text: "a sense")]
        #expect(await cascade.choose(from: unkeyable, reading: "a sentence", context: .complete)
            == .abstained(.noCandidates))
        #expect(spy.saw.withLock { $0.isEmpty }, "the decider was woken for a refusal")
    }
}
