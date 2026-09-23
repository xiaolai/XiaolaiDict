import Testing
import XiaolaiDictCore

/// **The sentence pane must work without Apple Intelligence.** The LLM panes are decided for every
/// reader, whether or not they have it — most of mainland China does not — so the downloaded model
/// answers first and Apple's is the fallback, not the other way round.
struct LadderSentenceExplainerTests {
    private struct ScriptedApple: SentenceExplaining {
        let tier = ExplainerTier.onDevice
        let answer: SentenceExplanation
        func explain(_ question: SentenceQuestion) async -> SentenceExplanation { answer }
    }

    private static let question = SentenceQuestion(
        sentence: "The ship's hold was full.", term: "hold",
        senseText: "a large space in the lower part of a ship")

    @Test func theDownloadedModelAnswersAndAppleIsNotAsked() async {
        let apple = ScriptedApple(answer: .unavailable("Apple should not have been asked."))
        let explainer = LadderSentenceExplainer(
            local: { _ in .explanation("Here it means the cargo space.") }, apple: apple)
        #expect(await explainer.explain(Self.question)
            == .explained("Here it means the cargo space.", tier: .onDevice))
    }

    /// Not installed, out of memory, declined, or no service at all: the rung below answers.
    @Test(arguments: [
        ModelReply.failure(.notInstalled), .failure(.refused),
        .failure(.insufficientMemory(needed: 1, available: 0)), .failure(.generationFailed("x")),
        // An answer to a question nobody asked is not an answer either.
        .translation("这艘船的货舱装满了。"), .prewarmed,
    ])
    func whereTheModelCannotAnswerApplesDoes(reply: ModelReply) async {
        let explainer = LadderSentenceExplainer(
            local: { _ in reply }, apple: ScriptedApple(answer: .explained("Apple's words", tier: .onDevice)))
        #expect(await explainer.explain(Self.question) == .explained("Apple's words", tier: .onDevice))
    }

    /// No service at all is the same fall-through.
    @Test func noServiceFallsThroughToo() async {
        let explainer = LadderSentenceExplainer(
            local: { _ in nil }, apple: ScriptedApple(answer: .unavailable("Apple could not either.")))
        #expect(await explainer.explain(Self.question) == .unavailable("Apple could not either."))
    }

    /// The prompt the local model is given may carry the dictionary's own text, because it runs on
    /// this Mac — and the tier says so rather than each call site deciding.
    @Test func theLocalPromptCarriesTheSenseAndTheRemoteOneNever() {
        #expect(Self.question.prompt(for: .onDevice).contains("a large space in the lower part of a ship"))
        #expect(!Self.question.prompt(for: .remote).contains("a large space in the lower part of a ship"))
    }
}
