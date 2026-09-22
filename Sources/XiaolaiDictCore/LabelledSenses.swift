/// One labelled case: a sentence the reader might be reading, and the sense of it NOAD actually
/// means. The keys are NOAD's own, read out of the live entries.
public struct LabelledCase: Sendable {
    public let word: String
    public let sentence: String
    /// The correct sense key, or nil when the right answer is to abstain.
    public let correct: String?
    public let why: String
}

/// **The labelled set**, the one measurement that decides the sense ladder's order.
///
/// Here rather than in the tests because two instruments read it: the accuracy suite, which runs
/// where the sources are, and `--sense-report`, which runs inside the signed bundle on the E2E Mac —
/// the only place all three rungs, the local model included, run through the real path. One list,
/// so the two cannot be scored on different cases.
///
/// NOAD-only, and NOAD is not the default primary — a limit `sense-lookup-edge-cases.md` records.
/// Six cases cannot support a ship decision on their own; they are what decides the *order*.
public enum LabelledSenses {
    public static let hardCases: [LabelledCase] = [
        LabelledCase(
            word: "fine", sentence: "He was ordered to pay a heavy fine for speeding.",
            correct: "m_en_gbus0362760.005",
            why: "the penalty is homograph 2; homograph 1 owns “made or done very well”"),
        LabelledCase(
            word: "hold",
            sentence: "It was stowed forward in the ship's hold, where the rats had got at the biscuit.",
            correct: "m_en_gbus0472980.005",
            why: "the ship's hold is homograph 2, one sense against homograph 1's eleven"),
        LabelledCase(
            word: "sanction", sentence: "The committee sanctioned the plan after months of debate.",
            correct: "m_en_gbus0897260.018",
            why: "a contronym: the neighbouring verb sense is “impose a penalty on”"),
        LabelledCase(
            word: "table", sentence: "The committee voted to table the motion until the next session.",
            correct: "m_en_gbus1025140.042",
            why: "the neighbouring verb sense is its near-opposite"),
        LabelledCase(
            word: "rein", sentence: "The government kept a tight rein on public spending.",
            correct: "m_en_gbus0858530.009",
            why: "figurative, against a literal horse strap in the same block"),
        LabelledCase(
            word: "temper", sentence: "He tempered his criticism with praise.",
            correct: "m_en_gbus1038310.022",
            why: "the verb “moderate”, against “harden steel” and “tune a piano”"),
    ]

    /// Which bucket one answer falls in. **Five, because an ambiguous answer is two facts**: a sense
    /// shown under an *ambiguous* badge is not a confident answer and is not scored as one, and it is
    /// split by whether the sense it led with was the right one — a hedge that is usually right and
    /// one that is usually wrong are different things to ship. Saying nothing at all is its own
    /// bucket beside them.
    public enum Bucket: String, Sendable, CaseIterable {
        case right, wrong, ambiguousRight, ambiguousWrong, abstained
    }

    /// `correct` is nil where **abstaining is the right answer**, and then a rung that *decided* to
    /// abstain scores right and one that picked a sense scores wrong. Without that, a case whose
    /// answer is "this sentence does not settle it" could only ever be scored a failure.
    ///
    /// **Deciding is not the same as being unable.** `.unavailable` and `.refused` mean the rung
    /// never got to the question — no model here, or the model declined to look — and scoring those
    /// as a correct abstention would credit a rung for not running.
    public static func bucket(_ choice: SenseSelection, correct: String?) -> Bucket {
        switch choice {
        case .chose(let key, _, _):
            return correct != nil && key == correct ? .right : .wrong
        case .abstained(_, let nearest?):
            guard let correct else { return .ambiguousWrong }
            return nearest.key == correct ? .ambiguousRight : .ambiguousWrong
        case .abstained(let why, _):
            return correct == nil && Self.isDecision(why) ? .right : .abstained
        }
    }

    /// Whether an abstention is the selector's judgement about the sentence rather than a report
    /// that it could not run at all.
    static func isDecision(_ why: Abstention) -> Bool {
        switch why {
        // `.undecided` is a model saying the sentence does not settle it — a judgement about the
        // sentence, like the two the embedding rung makes, and not a report that the rung could not
        // run. `.refused` is the other way round: the model was here and would not answer at all.
        case .tooClose, .nothingFits, .undecided, .noCandidates, .noContext: true
        case .unavailable, .refused: false
        }
    }
}
