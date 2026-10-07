/// Why the selector declined to choose. **A selector forced to always answer will always answer**,
/// so declining is a first-class result rather than a failure.
public enum Abstention: String, Sendable, CaseIterable, Codable {
    /// Nothing keyable to choose between — including the case the request calls 再想别的办法: the
    /// sense the reader wants is not in any installed dictionary.
    case noCandidates
    /// No sentence, or one that may be cut. No context, no disambiguation.
    case noContext
    /// Several senses genuinely fit. Two meanings this instrument cannot separate must not be
    /// separated by rounding.
    case tooClose
    /// Nothing is close enough to the sentence to claim.
    case nothingFits
    /// **A model answered that the sentence does not settle the question.** Its own instructions
    /// offer 0 for two different situations at once — "no sense clearly fits, *or* two or more fit
    /// equally well" — so the answer cannot say which, and this claims neither. `.tooClose` and
    /// `.nothingFits` belong to the embedding rung, where the distance to the runner-up is measured
    /// and says which of the two it is; filing a model's 0 under `.tooClose` told the reader
    /// "several senses fit equally well" on sentences where the model meant the opposite.
    case undecided
    /// The selector could not run at all — no model on this Mac, one that does not fit in memory
    /// right now, or no embedding for this language.
    case unavailable
    /// A model was here and **declined this sentence**. Not `.unavailable`: "no model here" and "the
    /// model would not answer" are different facts about a lookup, and the ledger keeps them apart.
    /// Measured: Apple's model refuses *"The police will charge him with fraud."* four runs of four,
    /// and filed as `.unavailable` that refusal left no trace.
    case refused

    // What the reader is told for each case is `Abstention.reason`, in `XiaolaiDictUI`. Display
    // text lives in the view layer because that is where the string catalog is extracted from and
    // where a translation is looked up; a sentence here could be shown but never translated.
}
