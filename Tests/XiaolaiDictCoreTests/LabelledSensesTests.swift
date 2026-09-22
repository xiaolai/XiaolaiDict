import Testing
import XiaolaiDictCore

/// The labelled set and how an answer to it is scored — the measurement that decides the ladder's
/// order, so what counts as right is itself worth pinning.
struct LabelledSensesTests {
    private static let key = "m_en_gbus0472980.005"
    private static func chose(_ key: String) -> SenseSelection { .chose(key: key, margin: 1, entryID: "e") }
    private static func nearly(_ key: String) -> SenseSelection {
        .abstained(.tooClose, nearest: NearMiss(key: key, margin: 0.01, among: 3))
    }

    @Test func aChoiceIsRightOnlyWhenItIsTheLabelledSense() {
        #expect(LabelledSenses.bucket(Self.chose(Self.key), correct: Self.key) == .right)
        #expect(LabelledSenses.bucket(Self.chose("m1.001"), correct: Self.key) == .wrong)
    }

    /// A favourite kept under an *ambiguous* badge is neither a confident answer nor silence, and
    /// which way it led is what a reader sees.
    @Test func anAmbiguousAnswerIsScoredByWhatItLedWith() {
        #expect(LabelledSenses.bucket(Self.nearly(Self.key), correct: Self.key) == .ambiguousRight)
        #expect(LabelledSenses.bucket(Self.nearly("m1.001"), correct: Self.key) == .ambiguousWrong)
        #expect(LabelledSenses.bucket(.abstained(.noContext), correct: Self.key) == .abstained)
    }

    /// **Where abstaining is the right answer, saying nothing is right** — and picking a sense is
    /// wrong, however plausible. Without this a case whose answer is "the sentence does not settle
    /// it" could only ever be scored a failure.
    @Test func anExpectedAbstentionScoresAsRight() {
        #expect(LabelledSenses.bucket(.abstained(.tooClose), correct: nil) == .right)
        #expect(LabelledSenses.bucket(.abstained(.nothingFits), correct: nil) == .right)
        // **Unable is not the same as right.** A rung with no model here, or one the model declined
        // to answer for, never reached the question; crediting it would score not running as skill.
        #expect(LabelledSenses.bucket(.abstained(.unavailable), correct: nil) == .abstained)
        #expect(LabelledSenses.bucket(.abstained(.refused), correct: nil) == .abstained)
        #expect(LabelledSenses.bucket(Self.chose(Self.key), correct: nil) == .wrong)
        #expect(LabelledSenses.bucket(Self.nearly(Self.key), correct: nil) == .ambiguousWrong)
    }

    /// Six cases, each naming a NOAD sense and saying what makes it hard — the `why` a report prints
    /// beside a wrong answer.
    @Test func everyCaseIsLabelledAndExplained() {
        #expect(LabelledSenses.hardCases.count == 6)
        for labelled in LabelledSenses.hardCases {
            #expect(!labelled.sentence.isEmpty)
            #expect(!labelled.why.isEmpty, "\(labelled.word) does not say what makes it hard")
            #expect(labelled.sentence.localizedCaseInsensitiveContains(labelled.word.prefix(4)))
        }
    }
}
