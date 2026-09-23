import XiaolaiDictTestSupport
import Testing
import XiaolaiDictCore

/// **The sentence pane must work without Apple Intelligence.** The LLM panes are decided for every
/// reader, whether or not they have it — most of mainland China does not — so the downloaded model
/// answers first and Apple's is the fallback, not the other way round.
struct LadderSentenceExplainerTests {
    /// Counts what it was asked, and with what. A rung that is called and whose answer is thrown
    /// away looks exactly like one that was never called; a rung handed the wrong question looks
    /// exactly like one handed the right one.
    private struct ScriptedApple: SentenceExplaining {
        let tier = ExplainerTier.onDevice
        let answer: SentenceExplanation
        let asked: Recorder<[SentenceQuestion]>
        init(answer: SentenceExplanation, asked: Recorder<[SentenceQuestion]> = Recorder([])) {
            self.answer = answer
            self.asked = asked
        }
        func explain(_ question: SentenceQuestion) async -> SentenceExplanation {
            asked.withLock { $0.append(question) }
            return answer
        }
    }

    private static let question = SentenceQuestion(
        sentence: "The ship's hold was full.", term: "hold",
        senseText: "a large space in the lower part of a ship")

    @Test func theDownloadedModelAnswersAndAppleIsNotAsked() async {
        let appleAsked = Recorder<[SentenceQuestion]>([])
        let localAsked = Recorder<[SentenceQuestion]>([])
        let apple = ScriptedApple(answer: .unavailable("Apple should not have been asked."), asked: appleAsked)
        let explainer = LadderSentenceExplainer(
            local: { question in
                localAsked.withLock { $0.append(question) }
                return .explanation("Here it means the cargo space.")
            }, apple: apple)
        #expect(await explainer.explain(Self.question)
            == .explained("Here it means the cargo space.", tier: .onDevice))
        #expect(appleAsked.withLock { $0.isEmpty }, "Apple was asked and its answer thrown away")
        #expect(localAsked.withLock { $0 } == [Self.question], "the rung was handed a different question")
    }

    /// **A blank answer is not an explanation**, and the rung below is asked instead — the same
    /// rule `OnDeviceSentenceExplainer` keeps for itself.
    @Test(arguments: ["", "   ", "\n\t "])
    func anEmptyLocalAnswerFallsThroughToApple(blank: String) async {
        let explainer = LadderSentenceExplainer(
            local: { _ in .explanation(blank) },
            apple: ScriptedApple(answer: .explained("Apple's words", tier: .onDevice)))
        #expect(await explainer.explain(Self.question) == .explained("Apple's words", tier: .onDevice))
    }

    /// The reader closed the panel. Neither rung is woken for an answer nobody will read.
    @Test func aCancelledExplanationWakesNobody() async {
        let appleAsked = Recorder<[SentenceQuestion]>([])
        let localAsked = Recorder<[SentenceQuestion]>([])
        let explainer = LadderSentenceExplainer(
            local: { question in localAsked.withLock { $0.append(question) }; return .explanation("late") },
            apple: ScriptedApple(answer: .explained("Apple's words", tier: .onDevice), asked: appleAsked))
        // **Cancelled from inside, before the call.** `Task { … }; task.cancel()` is a race — the
        // body can run to completion before the cancellation lands — and a racy test that passes
        // is indistinguishable from one that proves the rule.
        let answer = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await explainer.explain(Self.question)
        }.value
        #expect(answer == .unavailable("The explanation was stopped."))
        #expect(appleAsked.withLock { $0.isEmpty })
        #expect(localAsked.withLock { $0.isEmpty })
    }

    /// Nothing to explain is refused before either rung, rather than spending two generations on it.
    @Test(arguments: [("", "hold"), ("   ", "hold"), ("The hold was full.", ""), ("The hold was full.", " ")])
    func anEmptyQuestionWakesNobody(sentence: String, term: String) async {
        let appleAsked = Recorder<[SentenceQuestion]>([])
        let explainer = LadderSentenceExplainer(
            local: { _ in .explanation("should not be asked") },
            apple: ScriptedApple(answer: .explained("nor this", tier: .onDevice), asked: appleAsked))
        let answer = await explainer.explain(SentenceQuestion(sentence: sentence, term: term))
        #expect(answer == .unavailable("There is no sentence to explain."))
        #expect(appleAsked.withLock { $0.isEmpty })
    }

    /// Not installed, out of memory, declined, or no service at all: the rung below answers.
    @Test(arguments: [
        ModelReply.failure(.notInstalled), .failure(.refused),
        .failure(.insufficientMemory(needed: 1, available: 0)), .failure(.generationFailed("x")),
        // **An answer to a question nobody asked is not an answer either** — every shape of one,
        // because each is a different case in the switch and a sampled pair proves nothing about
        // the ones left out.
        .translation("这艘船的货舱装满了。"), .prewarmed, .sense(2), .unloading,
        .status(ModelServiceStatus(
            installed: nil, loaded: false, gpu: nil, footprint: nil, availableMemory: nil)),
    ])
    func whereTheModelCannotAnswerApplesDoes(reply: ModelReply) async {
        let asked = Recorder<[SentenceQuestion]>([])
        let explainer = LadderSentenceExplainer(
            local: { _ in reply },
            apple: ScriptedApple(answer: .explained("Apple's words", tier: .onDevice), asked: asked))
        #expect(await explainer.explain(Self.question) == .explained("Apple's words", tier: .onDevice))
        #expect(asked.withLock { $0 } == [Self.question], "Apple was handed a different question")
    }

    /// No service at all is the same fall-through.
    @Test func noServiceFallsThroughToo() async {
        let explainer = LadderSentenceExplainer(
            local: { _ in nil }, apple: ScriptedApple(answer: .unavailable("Apple could not either.")))
        #expect(await explainer.explain(Self.question) == .unavailable("Apple could not either."))
    }

    // The licence boundary is checked in `SentenceTierTests`, where it belongs: it is a property of
    // `SentenceQuestion.prompt(for:)`, which is the one place the dropping happens, and the test
    // that lived here built neither a ladder nor a local model to exercise it.
}
