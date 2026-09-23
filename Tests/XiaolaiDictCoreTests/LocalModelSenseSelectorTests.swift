import XiaolaiDictTestSupport
import Testing
import XiaolaiDictCore

/// The local model's rung: the same closed-set question as the on-device rung, over a process
/// boundary, with its answer checked against the list here.
struct LocalModelSenseSelectorTests {
    private static let candidates = [
        SenseCandidate(entryID: "hold1", key: "h.1", keyKind: .publisher, text: "grasp with the hands", partOfSpeech: "verb"),
        SenseCandidate(entryID: "hold2", key: "h.2", keyKind: .publisher, text: "the cargo space of a ship", partOfSpeech: "noun"),
        SenseCandidate(entryID: "hold2", key: "h.3", keyKind: .publisher, text: "a grip in wrestling", partOfSpeech: "noun"),
        SenseCandidate(entryID: "hold3", key: "", keyKind: .none, text: "an unkeyable sense", partOfSpeech: "noun"),
    ]

    private static func choose(
        _ reply: ModelReply?, partOfSpeech: String? = "noun", asked: Recorder<[SenseQuestion]> = Recorder([])
    ) async -> SenseSelection {
        await LocalModelSenseSelector { question in
            asked.withLock { $0.append(question) }
            return reply
        }.choose(from: candidates, reading: "The ship's hold was full.", context: .complete, partOfSpeech: partOfSpeech)
    }

    /// **An entry longer than the answer can name is not asked about.** The service refuses a list
    /// past the schema's bound as an invalid request — a defect in whatever built it — and *run* in
    /// a large dictionary is not a defect. The rung abstains so the one below, which has no such
    /// bound, runs.
    @Test func anEntryTooLongForTheAnswerIsNotAsked() async {
        let many = (1...ModelPrompt.maximumSenses + 1).map {
            SenseCandidate(entryID: "run", key: "r.\($0)", keyKind: .publisher, text: "sense \($0)",
                           partOfSpeech: "verb")
        }
        let asked = Recorder<[SenseQuestion]>([])
        let choice = await LocalModelSenseSelector { question in
            asked.withLock { $0.append(question) }
            return .sense(1)
        }.choose(from: many, reading: "He had to run for it.", context: .complete, partOfSpeech: "verb")
        #expect(choice == .abstained(.unavailable))
        #expect(asked.withLock { $0.isEmpty }, "a list the answer cannot name was sent anyway")
    }

    /// The number is a position in the list the model was sent — narrowed to nouns and to what can
    /// be keyed — and it comes back as that sense's key and entry.
    @Test func theAnswerIsReadAgainstTheListTheModelWasSent() async {
        let asked = Recorder<[SenseQuestion]>([])
        let choice = await Self.choose(.sense(1), asked: asked)
        #expect(choice == .chose(key: "h.2", margin: 1, entryID: "hold2"))
        #expect(asked.withLock { $0.first?.senses } == ["the cargo space of a ship", "a grip in wrestling"])
        #expect(asked.withLock { $0.first?.partOfSpeech } == "noun")
    }

    /// 0 is the model saying the sentence does not settle it — a decision, which the ladder respects.
    ///
    /// **Its own abstention, not `.tooClose`.** The instructions offer 0 for "no sense clearly fits"
    /// *and* for "two or more fit equally well", so the answer cannot carry the claim that several
    /// fit — which is what the reader was told on sentences where the model meant the opposite.
    @Test func zeroIsTheModelDecliningToSettleIt() async {
        #expect(await Self.choose(.sense(0)) == .abstained(.undecided))
    }

    /// **A number that names no sense in the list is not a decision.** 2B answered "10" of eight
    /// senses once; that rung could not run, so the answer must let the next one try rather than
    /// standing as an abstention of its own.
    @Test(arguments: [3, 10, -1])
    func aNumberOutsideTheListLetsTheNextRungAnswer(number: Int) async {
        #expect(await Self.choose(.sense(number)) == .abstained(.unavailable))
    }

    /// Every other reply is the model not being here for this lookup — including an answer to a
    /// question nobody asked.
    @Test(arguments: [ModelReply.translation("x"), .prewarmed, .unloading])
    func anAnswerToAnotherQuestionIsNotAnAnswer(reply: ModelReply) async {
        #expect(await Self.choose(reply) == .abstained(.unavailable))
    }

    /// Not downloaded, too little memory now, a failed generation, or no service at all: the model
    /// is not here, and the next rung runs.
    @Test(arguments: [
        ModelReply.failure(.notInstalled), .failure(.insufficientMemory(needed: 1, available: 0)),
        .failure(.generationFailed("x")), .translation("wrong reply"),
    ])
    func absenceIsUnavailable(reply: ModelReply) async {
        #expect(await Self.choose(reply) == .abstained(.unavailable))
    }

    @Test func noServiceIsUnavailable() async {
        #expect(await Self.choose(nil) == .abstained(.unavailable))
    }

    /// A refusal is kept as one.
    @Test func aRefusalIsARefusal() async {
        #expect(await Self.choose(.failure(.refused)) == .abstained(.refused))
    }

    /// The model is not woken for what the cascade can answer itself.
    @Test func itAsksNothingWhenThereIsNothingToAsk() async {
        let asked = Recorder<[SenseQuestion]>([])
        let selector = LocalModelSenseSelector { question in
            asked.withLock { $0.append(question) }
            return .sense(1)
        }
        #expect(await selector.choose(from: Self.candidates, reading: nil, context: .missing, partOfSpeech: "noun")
            == .abstained(.noContext))
        #expect(await selector.choose(from: [Self.candidates[3]], reading: "a sentence", context: .complete)
            == .abstained(.noCandidates))
        #expect(await selector.choose(from: [Self.candidates[1]], reading: "a sentence", context: .complete)
            == .chose(key: "h.2", margin: .infinity, entryID: "hold2"))
        #expect(asked.withLock { $0.isEmpty })
    }

    /// The ladder the app builds: the local model first, and its absence costs nothing but a rung.
    @Test func withTheModelAbsentTheLadderFallsToTheNextRung() async {
        struct Next: SenseSelecting {
            func choose(from candidates: [SenseCandidate], reading sentence: String?,
                        context: CaptureQuality.Context, partOfSpeech: String?) async -> SenseSelection {
                .chose(key: "h.3", margin: 0.2, entryID: "hold2")
            }
        }
        let ladder = LadderSenseSelector(rungs: [
            LocalModelSenseSelector { _ in .failure(.notInstalled) }, Next(),
        ])
        #expect(await ladder.choose(from: Self.candidates, reading: "The ship's hold was full.", context: .complete).key
            == "h.3")
    }
}
