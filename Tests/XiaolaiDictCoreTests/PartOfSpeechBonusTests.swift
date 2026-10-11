import CaptureModel
import DictionaryModel
import Testing
@testable import XiaolaiDictCore

/// **The embedding rung's part-of-speech bonus: bounded, reordering, never deleting** (ADR-0053 addendum, 2026-10-11).
///
/// The retired narrowing deleted every sense whose label disagreed with the tag. The bonus may only move a sense whose
/// label agrees *ahead* by at most `weight`, among the senses the sentence already reaches. These tests hand `decide`
/// distances directly, so each rule is checked on numbers chosen to break it rather than on what an embedding happened
/// to answer.
struct PartOfSpeechBonusTests {
    private static func sense(_ key: String, _ label: String?) -> SenseCandidate {
        SenseCandidate(entryID: "e", key: key, keyKind: .publisher, text: "sense \(key)", partOfSpeech: label)
    }

    private static func rung(_ weight: Double) -> EmbeddingSenseSelector {
        EmbeddingSenseSelector(partOfSpeechWeight: weight, embedding: { _ in nil })
    }

    // MARK: Matching a label — the cases the deleted filter's tests held, moved to the scoring they now govern.

    /// *sanction* in 牛津: `noun`, `plural noun`, `transitive verb`. A subtype of a part of speech is that part of speech.
    @Test func aPluralNounIsANoun() {
        #expect(PartOfSpeechLabel.matches("plural noun", tag: "noun"))
        #expect(PartOfSpeechLabel.matches("noun", tag: "noun"))
        #expect(!PartOfSpeechLabel.matches("transitive verb", tag: "noun"))
    }

    @Test func aTransitiveVerbIsAVerb() {
        for label in ["verb", "transitive verb", "intransitive verb", "impersonal verb"] {
            #expect(PartOfSpeechLabel.matches(label, tag: "verb"), "\(label)")
        }
    }

    /// **The reason this is by word**: `adverb` contains `verb`, and an adverb sense is not a verb sense.
    @Test func anAdverbIsNotAVerb() {
        #expect(!PartOfSpeechLabel.matches("adverb", tag: "verb"))
        #expect(!PartOfSpeechLabel.matches("adverb phrase", tag: "verb"))
        #expect(PartOfSpeechLabel.matches("adverb phrase", tag: "adverb"))
    }

    /// 譯典通's `n.` and `vt.` say the same thing in a vocabulary this does not read: inert, never wrong.
    @Test func aVocabularyItCannotReadMatchesNothing() {
        for label in ["n.", "vt.", "vi.", "a.", "ad."] {
            #expect(!PartOfSpeechLabel.matches(label, tag: "noun") && !PartOfSpeechLabel.matches(label, tag: "verb"))
        }
    }

    @Test func noTagOrNoLabelMatchesNothing() {
        #expect(!PartOfSpeechLabel.matches("noun", tag: nil))
        #expect(!PartOfSpeechLabel.matches("noun", tag: ""))
        #expect(!PartOfSpeechLabel.matches(nil, tag: "noun"))
    }

    /// Case is the dictionary's typography, not a different part of speech.
    @Test func caseDoesNotMatter() {
        #expect(PartOfSpeechLabel.matches("Noun", tag: "noun"))
    }

    // MARK: Scoring

    /// **Every candidate survives**, whatever the tag and the weight: the bonus reorders and removes nothing.
    @Test(arguments: [0.0, 0.05, 0.2, 5.0])
    func everyCandidateIsKept(weight: Double) {
        let ranked = [(Self.sense("a", "verb"), 0.40), (Self.sense("b", "noun"), 0.45),
                      (Self.sense("c", nil), 0.50), (Self.sense("d", "noun"), 1.60)]
        for tag in [nil, "noun", "verb", "adjective"] {
            let scored = Self.rung(weight).scored(ranked.map { ($0.0, $0.1) }, partOfSpeech: tag)
            #expect(scored.map(\.candidate.key).sorted() == ["a", "b", "c", "d"], "a candidate was dropped")
        }
    }

    /// **Bounded**: a score is the distance, less at most the weight, and less anything only where the label agrees
    /// and the sense is eligible.
    @Test func theScoreIsBoundedByTheWeight() {
        let weight = 0.1
        let ranked = [(Self.sense("a", "verb"), 0.40), (Self.sense("b", "noun"), 0.45),
                      (Self.sense("c", nil), 0.50), (Self.sense("d", "plural noun"), 0.70),
                      (Self.sense("e", "noun"), 1.60)]
        let scored = Self.rung(weight).scored(ranked.map { ($0.0, $0.1) }, partOfSpeech: "noun")
        for entry in scored {
            #expect(entry.score <= entry.distance && entry.score >= entry.distance - weight, "\(entry.candidate.key)")
            let earns = PartOfSpeechLabel.matches(entry.candidate.partOfSpeech, tag: "noun")
                && entry.distance <= EmbeddingSenseSelector.maximumDistance
            #expect(entry.score == (earns ? entry.distance - weight : entry.distance), "\(entry.candidate.key)")
        }
    }

    /// The bonus does what it is for: two senses the sentence cannot separate, and the tag decides between them.
    @Test func anAgreeingLabelMovesASenseAhead() {
        let ranked = [(Self.sense("verb", "verb"), 0.50), (Self.sense("noun", "noun"), 0.52)]
        let choice = Self.rung(0.1).decide(ranked, partOfSpeech: "noun")
        #expect(choice.key == "noun")
        // Without a tag, the sentence alone abstains as too close, which is the rung's honest answer.
        #expect(Self.rung(0.1).decide(ranked, partOfSpeech: nil).abstention == .tooClose)
    }

    /// **The positive control: semantic evidence defeats a wrong tag.** The noun is far closer to the sentence; the
    /// tag says verb, and a bounded bonus cannot carry the verb past it.
    @Test func semanticEvidenceDefeatsAWrongTag() {
        let ranked = [(Self.sense("noun", "noun"), 0.30), (Self.sense("verb", "verb"), 0.60)]
        let choice = Self.rung(0.1).decide(ranked, partOfSpeech: "verb")
        #expect(choice.key == "noun", "a wrong tag overrode the sentence: \(choice)")
    }

    /// **Raw eligibility stands.** Nothing the sentence reaches: the bonus cannot rescue the agreeing sense.
    @Test func theBonusRescuesNothingTheSentenceDoesNotReach() {
        let beyond = EmbeddingSenseSelector.maximumDistance + 0.05
        let ranked = [(Self.sense("noun", "noun"), beyond), (Self.sense("verb", "verb"), beyond + 0.1)]
        #expect(Self.rung(0.2).decide(ranked, partOfSpeech: "noun").abstention == .nothingFits)
    }

    /// And an ineligible sense earns no bonus, so it cannot overtake one the sentence does reach.
    @Test func anIneligibleSenseCannotOvertakeAnEligibleOne() {
        let eligible = EmbeddingSenseSelector.maximumDistance - 0.05
        let ranked = [(Self.sense("verb", "verb"), eligible), (Self.sense("noun", "noun"), eligible + 0.06)]
        let choice = Self.rung(0.2).decide(ranked, partOfSpeech: "noun")
        #expect(choice.key == "verb", "an ineligible sense was rescued: \(choice)")
    }

    /// No tag, an unlabelled sense, or a label in a vocabulary the tag does not use: each contributes zero, so the
    /// answer is the unweighted one.
    @Test func anUnknownLabelOrAnAbsentTagContributesNothing() {
        let close = [(Self.sense("a", "n."), 0.50), (Self.sense("b", nil), 0.51), (Self.sense("c", "vt."), 0.60)]
        let unweighted = Self.rung(0).decide(close, partOfSpeech: "noun")
        #expect(Self.rung(0.2).decide(close, partOfSpeech: "noun") == unweighted)
        let labelled = [(Self.sense("a", "verb"), 0.50), (Self.sense("b", "noun"), 0.51)]
        #expect(Self.rung(0.2).decide(labelled, partOfSpeech: nil) == Self.rung(0).decide(labelled, partOfSpeech: nil))
    }

    /// **Abstention is preserved.** Two senses that both agree with the tag both earn it, so the margin is the
    /// sentence's, and a sentence that does not settle still says so — with its favourite kept.
    @Test func aBonusBothRivalsEarnLeavesTheMarginAlone() {
        let ranked = [(Self.sense("a", "noun"), 0.50), (Self.sense("b", "plural noun"), 0.51),
                      (Self.sense("c", "verb"), 0.90)]
        let choice = Self.rung(0.2).decide(ranked, partOfSpeech: "noun")
        #expect(choice.abstention == .tooClose)
        #expect(choice.nearest?.key == "a")
    }

    /// **At weight zero the decision is the unfiltered rung's, whatever the tag.**
    @Test func weightZeroIgnoresTheTag() {
        let ranked = [(Self.sense("a", "verb"), 0.50), (Self.sense("b", "noun"), 0.51), (Self.sense("c", "noun"), 0.70)]
        for tag in ["noun", "verb", "adverb"] {
            #expect(Self.rung(0).decide(ranked, partOfSpeech: tag) == Self.rung(0).decide(ranked, partOfSpeech: nil))
        }
    }

    /// The rungs that could not run are untouched: no embedding for the language, and no sentence to compare.
    @Test func whatTheRungCouldNotScoreTheBonusCannotChange() async {
        let field = [Self.sense("a", "noun"), Self.sense("b", "verb")]
        let rung = Self.rung(0.2)
        #expect(await rung.choose(from: field, reading: "A sentence.", context: .complete, partOfSpeech: "noun")
            .abstention == .unavailable)
        #expect(await rung.choose(from: field, reading: nil, context: .missing, partOfSpeech: "noun")
            .abstention == .noContext)
        #expect(Self.rung(0.2).decide([], partOfSpeech: "noun").abstention == .unavailable)
    }
}
