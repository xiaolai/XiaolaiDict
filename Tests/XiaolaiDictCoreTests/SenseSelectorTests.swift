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
    @Test func whateverItChoosesIsOneOfTheCandidates() async {
        let choice = await selector.choose(
            from: Self.senses, reading: "He was ordered to pay a heavy fine for speeding.", context: .complete)
        if let key = choice.key {
            #expect(Self.senses.map(\.key).contains(key), "chose \(key), which was never offered")
        }
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
        #expect(choice == .abstained(.tooClose))
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
    @Test func aSingleCandidateIsNotAChoiceTheSelectorMade() async {
        let choice = await selector.choose(
            from: [Self.candidate("e.1", "a penalty")], reading: "He paid it.", context: .complete)
        #expect(choice.key == "e.1")
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

    /// Every abstention can be shown to the reader: the popup must be able to say why it did not
    /// mark anything, and an empty string would be a blank where an explanation belongs.
    @Test(arguments: Abstention.allCases)
    func everyAbstentionHasSomethingToSay(abstention: Abstention) {
        #expect(!abstention.reason.isEmpty)
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
}
