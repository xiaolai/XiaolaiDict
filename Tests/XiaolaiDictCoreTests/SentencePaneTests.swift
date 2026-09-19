import XiaolaiDictCore
import Testing

/// The tier boundary is a **licence**, not a preference. The dictionaries are licensed to the
/// reader, not to XiaolaiDict, and their text must never reach a remote service.
struct SentenceTierTests {
    private let question = SentenceQuestion(
        sentence: "He was ordered to pay a heavy fine for speeding.",
        term: "fine",
        senseText: "money a court orders you to pay for breaking a rule")

    /// The remote tier sees the reader's own sentence and nothing of the publisher's.
    @Test func theRemoteTierNeverSeesDictionaryText() {
        let prompt = question.prompt(for: .remote)
        #expect(prompt.contains("He was ordered to pay a heavy fine"), "the reader's own sentence was dropped")
        #expect(prompt.contains("fine"))
        #expect(!prompt.contains("money a court orders you to pay"), "publisher's text reached the remote prompt")
        #expect(!question.leaksDictionaryText(prompt))
    }

    /// On-device may see it, because nothing leaves the Mac.
    @Test func theOnDeviceTierMaySeeIt() {
        let prompt = question.prompt(for: .onDevice)
        #expect(prompt.contains("money a court orders you to pay"))
        #expect(question.leaksDictionaryText(prompt))
    }

    /// Dropping happens at the boundary, so a caller cannot smuggle it through by assembling the
    /// question differently.
    @Test(arguments: ExplainerTier.allCases)
    func everyTierIsExplicitAboutWhatItMaySee(tier: ExplainerTier) {
        #expect(tier.maySeeDictionaryText == (tier == .onDevice))
    }

    /// A question with no sense text is safe for either tier, and the prompt is still usable.
    @Test func withoutASenseBothTiersGetTheSamePrompt() {
        let bare = SentenceQuestion(sentence: "He paid the fine.", term: "fine")
        #expect(bare.prompt(for: .remote) == bare.prompt(for: .onDevice))
        #expect(!bare.leaksDictionaryText(bare.prompt(for: .remote)))
    }
}

/// The on-device explainer's contract, which holds whether or not the model is present.
struct OnDeviceSentenceExplainerTests {
    @Test func itIsTheOnDeviceTier() {
        #expect(OnDeviceSentenceExplainer().tier == .onDevice)
    }

    @Test func noSentenceIsNotExplained() async {
        let answer = await OnDeviceSentenceExplainer().explain(SentenceQuestion(sentence: "  ", term: "fine"))
        guard case .unavailable(let why) = answer else {
            Issue.record("a blank sentence was explained: \(answer)")
            return
        }
        #expect(!why.isEmpty)
    }

    /// Where the model is absent it says so — it does not fall through to anything that might send
    /// the text off the Mac.
    @Test func anAbsentModelSaysSoRatherThanFallingBack() async {
        let answer = await OnDeviceSentenceExplainer().explain(SentenceQuestion(
            sentence: "He was ordered to pay a heavy fine.", term: "fine",
            senseText: "money a court orders you to pay"))
        switch answer {
        case .explained(_, let tier): #expect(tier == .onDevice, "an on-device request was answered by another tier")
        case .unavailable(let why): #expect(!why.isEmpty, "it failed without saying why")
        }
    }
}
