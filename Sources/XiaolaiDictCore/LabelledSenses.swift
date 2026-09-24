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

    /// **The inflected set**, for ADR-0004: does knowing the word class find the right *entry*?
    ///
    /// Separate from `hardCases` and not merged into it, because `hardCases` is what the recorded
    /// ladder order rests on — 6/0, 5/1, 3/1 — and folding six more cases in would silently make
    /// that number mean something else.
    ///
    /// **Paired on purpose.** Each spelling appears twice, once where the reader means the verb the
    /// form inflects and once where they mean the noun the spelling *is*. A resolver that always
    /// prefers the lemma's entry, or always prefers the surface's, scores exactly half — so the
    /// pairing is what stops a bias reading as an improvement. `ground` alone is 20 NOAD senses
    /// across the two entries; the class narrows it to 6 or to 14.
    ///
    /// The sentences are written here rather than taken from NOAD's own examples.
    /// `dictionary-research/oracle-contamination` measured a local model reproducing eleven
    /// consecutive words of Oxford's definition of *run* from memory, so a case built from Oxford's
    /// own text would measure the model's memory rather than its reading.
    public static let inflectedCases: [LabelledCase] = [
        LabelledCase(
            word: "ground", sentence: "She ground the coffee beans before breakfast.",
            correct: "m_en_gbus0434260.010",
            why: "the past of grind, against the 14 senses of the earth underfoot"),
        LabelledCase(
            word: "ground", sentence: "He sat down on the cold wet ground.",
            correct: "m_en_gbus0435410.008",
            why: "the same spelling, and here the noun is what was read"),
        LabelledCase(
            word: "saw", sentence: "From the ridge he saw the whole valley below.",
            correct: "m_en_gbus0917420.011",
            why: "the past of see, against the cutting tool that owns the spelling"),
        LabelledCase(
            word: "saw", sentence: "He cut the plank in two with a saw.",
            correct: "m_en_gbus0903150.005",
            why: "the tool, which is the headword the surface form is"),
        LabelledCase(
            word: "rose", sentence: "The sun rose over the hills a little after six.",
            correct: "m_en_gbus0875650.019",
            why: "the past of rise; the flower is a noun entry of its own"),
        LabelledCase(
            word: "rose", sentence: "She gave him a single red rose.",
            correct: "m_en_gbus0882370.015",
            why: "the flower, and the pair is what stops a lemma-preferring bias scoring well"),
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
