import CaptureModel
import DictionaryModel
import ModelKit
import Synchronization
import XiaolaiDictTestSupport
import Testing
import XiaolaiDictCore

/// **The tagger's part of speech is a hint, never a filter** (ADR-0053; AGENTS.md, "never gate, always annotate").
///
/// Measured on 270 hard cases: narrowing the candidates to the tagger's part of speech deleted the right sense in 40, and
/// a prompt stating "The word is used as a verb." as a fact cost one model 24 right answers where the tagger was wrong.
/// So a tag — right or wrong — removes nothing from any rung, and a model is told it as a guess.
///
/// Every case here hands a rung a **deliberately wrong** tag: *hold* in "The ship's hold was full." is a noun, and the
/// tag says verb. Under the narrowing that tag left the rung only the verb sense, which is the failure this pins shut.
struct PartOfSpeechHintTests {
    private static let sentence = "The ship's hold was full."
    private static let wrongTag = "verb"

    private static let candidates = [
        SenseCandidate(entryID: "hold1", key: "h.1", keyKind: .publisher, text: "grasp with the hands", partOfSpeech: "verb"),
        SenseCandidate(entryID: "hold2", key: "h.2", keyKind: .publisher, text: "the cargo space of a ship",
                       partOfSpeech: "noun"),
        SenseCandidate(entryID: "hold2", key: "h.3", keyKind: .publisher, text: "a grip in wrestling", partOfSpeech: "noun"),
        // Not keyable: dropped for that reason alone, which the tag has no part in.
        SenseCandidate(entryID: "hold3", key: "", keyKind: .none, text: "an unkeyable sense", partOfSpeech: "noun"),
    ]

    /// Every candidate a rung may consider whatever the tag says: the keyable ones, in their order.
    private static let eligible = ["h.1", "h.2", "h.3"]

    /// Records what it was handed, so the field itself is asserted rather than inferred from an answer.
    private final class Spy: SenseSelecting, @unchecked Sendable {
        let saw = Mutex<[String]>([])
        func choose(
            from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
            partOfSpeech: String?
        ) async -> SenseSelection {
            saw.withLock { $0 = candidates.map(\.key) }
            return .abstained(.undecided)
        }
    }

    /// **The positive control for the embedding rung.** With two senses of different parts of speech and a wrong tag,
    /// the narrowing left one and settled it *without scoring anything* — a confident mark the sentence never earned.
    /// With no embedding to score by, the rung must answer exactly what it answers with no tag at all.
    @Test func theEmbeddingRungIsNotSettledByAWrongTag() async {
        let two = Array(Self.candidates.prefix(2))
        let rung = EmbeddingSenseSelector(embedding: { _ in nil })
        let untagged = await rung.choose(from: two, reading: Self.sentence, context: .complete, partOfSpeech: nil)
        let tagged = await rung.choose(from: two, reading: Self.sentence, context: .complete, partOfSpeech: Self.wrongTag)
        #expect(tagged == untagged, "the tag decided what the sentence did not")
        #expect(tagged.key == nil, "a wrong tag produced a mark")
    }

    /// The model rung is sent every eligible sense, the wrong tag's and the right one's alike.
    @Test func theModelRungIsSentEveryEligibleSense() async {
        let asked = Recorder<[SenseQuestion]>([])
        let choice = await LocalModelSenseSelector { question in
            asked.withLock { $0.append(question) }
            return .sense(2)
        }.choose(from: Self.candidates, reading: Self.sentence, context: .complete, partOfSpeech: Self.wrongTag)
        #expect(asked.withLock { $0.first?.senses.count } == Self.eligible.count, "the tag removed a sense")
        // The number is read against the list that was sent, so 2 is the cargo space — reachable only because the
        // noun senses were not deleted for a verb tag.
        #expect(choice == .chose(key: "h.2", margin: nil, entryID: "hold2"))
    }

    /// The shortlist ranks, and hands its decider, the whole eligible field.
    @Test func theShortlistHandsItsDeciderEveryEligibleSense() async {
        let spy = Spy()
        _ = await ShortlistSenseSelector(
            shortlist: 9, decider: spy, ranker: EmbeddingSenseSelector(embedding: { _ in nil })
        ).choose(from: Self.candidates, reading: Self.sentence, context: .complete, partOfSpeech: Self.wrongTag)
        #expect(spy.saw.withLock { $0 } == Self.eligible)
    }

    /// The ladder passes the whole field to every rung it asks, and the field arrives in the dictionary's order.
    @Test func everyRungOfTheLadderSeesEveryEligibleSense() async {
        let asked = Recorder<[SenseQuestion]>([])
        let model = LocalModelSenseSelector { question in
            asked.withLock { $0.append(question) }
            return nil
        }
        let spy = Spy()
        _ = await LadderSenseSelector(rungs: [model, ShortlistSenseSelector(
            shortlist: 9, decider: spy, ranker: EmbeddingSenseSelector(embedding: { _ in nil }))]
        ).choose(from: Self.candidates, reading: Self.sentence, context: .complete, partOfSpeech: Self.wrongTag)
        #expect(asked.withLock { $0.first?.senses.count } == Self.eligible.count)
        #expect(spy.saw.withLock { $0 } == Self.eligible)
    }

    /// **The tag reaches a model as a guess**, and the sentence that stated it as a fact is gone.
    @Test func thePromptSaysTheTagIsAGuess() {
        let prompt = ModelPrompt.sense(SenseQuestion(
            sentence: Self.sentence, taggerGuess: Self.wrongTag, senses: [.init(text: "grasp with the hands")]))
        #expect(!prompt.contains("The word is used as a"), "the tag is stated as a fact")
        #expect(prompt.contains("guessed"))
        #expect(prompt.contains("may be wrong"))
        #expect(prompt.contains(Self.wrongTag))
    }

    /// **The dictionary's label travels beside each sense**, so the model can weigh it against the guess; a sense whose
    /// block printed no label is listed bare.
    @Test func eachSenseCarriesItsDictionarysLabel() {
        let prompt = ModelPrompt.sense(SenseQuestion(
            sentence: Self.sentence, taggerGuess: Self.wrongTag,
            senses: [.init(text: "grasp with the hands", partOfSpeech: "transitive verb"),
                     .init(text: "the cargo space of a ship", partOfSpeech: "noun"),
                     .init(text: "a grip in wrestling")]))
        let lines = prompt.split(separator: "\n")
        #expect(lines.contains("1. (transitive verb) grasp with the hands"))
        #expect(lines.contains("2. (noun) the cargo space of a ship"))
        #expect(lines.contains("3. a grip in wrestling"))
    }

    /// A label is the publisher's text, so it is flattened like the sense: a newline in it cannot add a line to the
    /// numbered list. The guess is flattened too, though the tagger's vocabulary is closed.
    @Test func aLabelCannotForgeALine() {
        let prompt = ModelPrompt.sense(SenseQuestion(
            sentence: Self.sentence, taggerGuess: "noun\n7. forged",
            senses: [.init(text: "grasp", partOfSpeech: "noun\n7. forged"), .init(text: "hold")]))
        let numbered = prompt.split(separator: "\n").filter { $0.first?.isNumber == true }
        #expect(numbered.count == 2)
    }

    /// No tag, no line about one.
    @Test func noTagNoHint() {
        let prompt = ModelPrompt.sense(SenseQuestion(
            sentence: Self.sentence, taggerGuess: nil, senses: [.init(text: "grasp with the hands")]))
        #expect(!prompt.contains("guessed"))
    }
}
