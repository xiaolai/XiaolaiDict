import XiaolaiDictCore

/// What the panel says when a reader points at a word.
///
/// **The question is "what does it mean *here*", not "what can this word mean".** The panel used
/// to answer the second one: a sidebar of every dictionary and every sense beside the publisher's
/// full entry, with the sense XiaolaiDict picked marked somewhere inside it. That is a reference work,
/// and the reader already has one — it is called Dictionary.app and it is one click away.
///
/// So this leads with a single sense. The constraint that shapes everything else is that **the
/// selector is not reliable enough to show only one**: re-measured 2026-09-22, the confidently-wrong
/// rate is **17% with Apple's on-device model and 17% with the `NLEmbedding` fallback** — the two
/// are now the same, where the model rung used to be 0%. The fallback is what runs where
/// FoundationModels is unavailable, which by the project's own note includes mainland China, a core
/// audience. One reader in six gets a confident wrong answer and no way to notice, **and that is
/// now true with or without Apple Intelligence.**
///
/// Hence the shape: **the answer, the evidence, the way out.** The answer is one sense. The
/// evidence is the reader's own sentence beside it and a plain statement of how the sense was
/// picked, so a wrong answer is visible rather than authoritative. The way out is every other
/// sense, one gesture away. That is D2 — *a wrong jump hides the right sense; a wrong mark is
/// visible and recoverable* — applied to a surface that leads with one answer instead of all of
/// them.
public struct LookupCard: Equatable {
    /// What the panel can say about the meaning. Four cases because there are four things that
    /// actually happen, and the two unhappy ones are not errors — an abstention is the selector
    /// working.
    public enum Answer: Equatable {
        /// One sense, and how much is being claimed about it.
        case sense(SensePresentation)
        /// The entry was read but no sense was settled on. **Not a failure**: the selector
        /// abstaining is the designed outcome when the sentence does not decide, and a card that
        /// picked one anyway would be the confidently-wrong case this whole design avoids.
        case undecided(reason: String?)
        /// Several senses fit and one was narrowly ahead. **Shown, and marked as unsure.**
        ///
        /// "Several senses fit this sentence equally well" and nothing else was the worst thing
        /// this card could say: the reader pointed at a word and got a non-answer, while the
        /// selector was sitting on a favourite it had just declined to name. Every abstention in
        /// the measured suite is this case, so it was every abstention throwing away its best
        /// guess.
        ///
        /// It is not `.sense`, and that separation is the point — a card drawn from this says
        /// *ambiguous* and opens the alternatives, because if XiaolaiDict is admitting it does not know,
        /// the choosing has to be in front of the reader rather than behind a disclosure.
        ///
        /// **Shipped against the evidence, knowingly.** In the measured suite the favourite leads
        /// with the *wrong* sense twice out of twice, at margins of 0.0103 and 0.0015 — noise, not
        /// a preference. Two adversarial cases is not proof it never helps, and the badge plus the
        /// open alternatives make a wrong lead recoverable, which is why it ships. The reasoning,
        /// the numbers and the version to build instead are in
        /// `dev-docs/leading-with-a-near-miss.md`.
        case ambiguous(SensePresentation, among: Int)
        /// A dictionary that answered in prose rather than in structure — no senses to choose
        /// between, so there is nothing to lead with but the text itself.
        case prose(String)
        /// Nothing was found. The word is still shown, because the reader looked it up and the
        /// fact that it is not there is the answer.
        case absent
    }

    public let term: String
    public let heading: String
    public let partOfSpeech: String?
    public let pronunciation: String?
    public let answer: Answer
    /// The reader's own sentence, where one was captured. The cue that makes a wrong answer
    /// visible: they can judge the claim against the text they read it in without opening anything.
    public let sentence: String?
    /// How many times this word has been looked up before, and where. **Shown as a number, not
    /// as a sentence.** "3rd lookup" spelled out above the answer tells a reader they have failed
    /// to learn this word twice already — true, unasked for, and the last thing someone reaching
    /// for a definition needs read back to them. A digit is a fact they can ignore; a sentence is
    /// a comment on them. It opens on a click, for the reader who wants it.
    public let memory: MemoryStrip?
    /// Every other sense in the entry, in the entry's own order. Present, and not shown until
    /// asked for.
    public let alternatives: [SensePresentation]

    /// How many senses the reader could turn to. Named rather than `alternatives.count` at the
    /// call site so the view cannot start counting something else.
    public var otherSenseCount: Int { alternatives.count }

    /// Whether the card is claiming something it might be wrong about. Drives how the answer is
    /// drawn, and it is deliberately true for `proposed` and false for a reader's own tap.
    public var isHypothesis: Bool {
        switch answer {
        case .sense(let sense): return sense.standing == .proposed
        case .ambiguous: return true
        default: return false
        }
    }

    /// Whether the alternatives are open the moment the card appears. They are when XiaolaiDict has
    /// admitted it cannot tell: leaving the reader to discover a disclosure before they can
    /// resolve the thing the card just told them is unresolved would be the non-answer again,
    /// one click further away.
    public var opensAlternatives: Bool {
        switch answer {
        case .ambiguous, .undecided: return true
        default: return false
        }
    }

    public init(
        term: String, heading: String, partOfSpeech: String?, pronunciation: String?,
        answer: Answer, sentence: String?, alternatives: [SensePresentation],
        memory: MemoryStrip? = nil
    ) {
        self.term = term
        self.heading = heading
        self.partOfSpeech = partOfSpeech
        self.pronunciation = pronunciation
        self.answer = answer
        self.sentence = sentence
        self.alternatives = alternatives
        self.memory = memory
    }
}

public extension LookupCard {
    /// The card for one lookup, from the entry the reader is reading.
    ///
    /// `entry` is the primary dictionary's — the one the reader studies from (D7). The others are
    /// not merged in: across seven dictionaries *hold* offers a hundred near-duplicate senses, and
    /// a card that led with one of them would be picking from a pile nobody can check.
    init(
        presentation: EntryPresentation, term: String, sentence: String?, mark: SenseMark?,
        memory: MemoryStrip? = nil
    ) {
        let chosen = presentation.senses.first { sense in
            guard let key = sense.key else { return false }
            return key == mark?.key
        }
        let answer: Answer
        if let chosen {
            answer = .sense(chosen)
        } else if presentation.senses.count == 1, let only = presentation.senses.first {
            // Nothing was chosen because there was nothing to choose between. That is a fact, not
            // a guess, and `SenseStanding` already says so.
            answer = .sense(only)
        } else if case .couldNot(let why, let nearest) = mark {
            // Only `.tooClose` carries a near miss, and only there is showing a favourite honest.
            // `.nothingFits` has a best candidate too and it is too far away to mean anything.
            if let nearest,
               let sense = presentation.senses.first(where: { $0.key == nearest.key }) {
                answer = .ambiguous(sense, among: nearest.among)
            } else {
                answer = .undecided(reason: why.reason)
            }
        } else if presentation.senses.isEmpty {
            // **Nothing was identified because there was nothing to identify.** Three of the seven
            // dictionaries enabled on this developer's Mac mark senses with nothing a parser can
            // key to — `senseKeyKind == .none` — so their entries arrive with an empty sense list
            // and fell through to "the sense you read could not be identified". That reads as a
            // failure of the selector on an entry the selector was never asked about, and it is
            // the dictionary's shape rather than anything that went wrong.
            //
            // It still shows no definition: this card renders senses, and rendering the entry's
            // own prose needs plain text `EntryDocument` does not keep. What changes here is that
            // the reader is no longer told something untrue about it.
            answer = .undecided(reason: String(
                localized: "This dictionary does not mark senses, so none can be pointed at here.",
                comment: "Shown where a dictionary's entries carry no sense structure at all"))
        } else {
            answer = .undecided(reason: nil)
        }

        let shown: String? = {
            switch answer {
            case .sense(let sense), .ambiguous(let sense, _): return sense.key ?? "\(sense.ordinal)"
            default: return nil
            }
        }()
        self.init(
            term: term,
            heading: presentation.heading,
            // The chosen sense's own part of speech where there is one: an entry's list of every
            // part of speech it covers says less than the one the reader is actually in.
            partOfSpeech: {
                switch answer {
                case .sense(let sense), .ambiguous(let sense, _):
                    if let part = sense.partOfSpeech { return part }
                default: break
                }
                return presentation.partsOfSpeech.first
            }(),
            // One respelling, the first the entry prints. A heading that carries the whole `d:prn`
            // list is telling the reader about the dictionary rather than about the word — the old
            // panel did that, and `Token.Limit.pronunciations` was the number that capped it. The
            // card does not need the number: `pronunciation` is a `String?`, so there is no list
            // here to run long, and document order is the publisher's own idea of which respelling
            // leads. That is the rule; it is a type now rather than a token nothing read.
            pronunciation: presentation.pronunciations.first,
            answer: answer,
            sentence: sentence,
            alternatives: presentation.senses.filter { ($0.key ?? "\($0.ordinal)") != shown },
            memory: memory)
    }
}
