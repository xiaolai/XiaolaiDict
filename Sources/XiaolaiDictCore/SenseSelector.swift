import Foundation
import NaturalLanguage

/// One sense the reader might have been reading, as the selector sees it.
public struct SenseCandidate: Sendable, Equatable {
    public let entryID: String
    public let key: String
    public let keyKind: SenseKeyKind
    /// The sense's definition and its examples — what the reader's sentence is compared against.
    public let text: String
    /// The `d:pos` of the block this sense sits in: "noun", "verb", "adjective". Nil when the block
    /// named none.
    public let partOfSpeech: String?

    public init(entryID: String, key: String, keyKind: SenseKeyKind, text: String, partOfSpeech: String? = nil) {
        self.entryID = entryID
        self.key = key
        self.keyKind = keyKind
        self.text = text
        self.partOfSpeech = partOfSpeech
    }
}

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

/// The sense the selector *nearly* chose, kept when it declined to choose at all.
///
/// **Only `.tooClose` has one**, and the distinction is the whole design. `.tooClose` means
/// several senses scored well and one was narrowly ahead — there is a real favourite, and saying
/// "several fit equally well" and nothing else throws away the most useful thing the selector
/// knows. `.nothingFits` means the best was still too far away; offering it would be inventing an
/// answer, which is what abstention exists to prevent.
///
/// It is not a choice and must never be drawn as one. A card built on this says *ambiguous* and
/// puts the alternatives in front of the reader rather than behind a disclosure.
public struct NearMiss: Sendable, Equatable {
    public let key: String
    /// How far ahead of the runner-up it was — below the margin the selector needs to commit,
    /// which is why this is a near miss and not a choice.
    public let margin: Double
    /// How many senses were in the running, so the card can say what the reader is choosing among.
    public let among: Int

    public init(key: String, margin: Double, among: Int) {
        self.key = key
        self.margin = margin
        self.among = among
    }
}

/// What the selector decided.
public enum SenseSelection: Sendable, Equatable {
    /// `key` is always one of the candidates it was given — the output is a choice from a closed
    /// set, never generated, so the worst failure is a *wrong existing* sense, not an invented one.
    /// `margin` is how far ahead of the runner-up it was.
    ///
    /// **`entryID` is what makes the key mean something.** A positional key is literally
    /// `"\(block).\(ordinal)"` — no entry id, no hash — so every entry in a dictionary has a sense
    /// keyed `"1.1"`. A caller resolving a choice by key alone takes the first entry that happens
    /// to contain one, which is the right sense of the wrong word often enough to matter, and it
    /// writes that into the study ledger. Nil only where the selector did not know it.
    case chose(key: String, margin: Double, entryID: String? = nil)
    /// `nearest` is set only for `.tooClose`; see `NearMiss`.
    case abstained(Abstention, nearest: NearMiss? = nil)

    public var key: String? {
        guard case .chose(let key, _, _) = self else { return nil }
        return key
    }

    /// Which entry the chosen sense belongs to, where the selector knew.
    public var entryID: String? {
        guard case .chose(_, _, let entryID) = self else { return nil }
        return entryID
    }

    public var abstention: Abstention? {
        guard case .abstained(let why, _) = self else { return nil }
        return why
    }

    /// The sense it nearly chose, where there was one.
    public var nearest: NearMiss? {
        guard case .abstained(_, let nearest) = self else { return nil }
        return nearest
    }
}

/// Choosing which sense of an entry the reader was reading.
///
/// This is the model's real job in XiaolaiDict, and it is a **closed-set choice, not generation**. The
/// output must already be in the candidate set, so the worst failure is picking a wrong existing
/// sense — it cannot invent one. That is what makes it the safe use of a model rather than the
/// risky one, and why it comes before any pane that generates text.
public protocol SenseSelecting: Sendable {
    /// `context` says whether the sentence is whole; a cut one is not evidence.
    /// `partOfSpeech` is how the word is being used in that sentence, where the tagger would commit.
    func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?
    ) async -> SenseSelection
}

public extension SenseSelecting {
    func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context
    ) async -> SenseSelection {
        await choose(from: candidates, reading: sentence, context: context, partOfSpeech: nil)
    }
}

/// Narrowing the candidates to the senses the word could grammatically be.
///
/// A word used as a noun cannot mean a verb sense, however close the wording is. Every sense
/// already knows its block's `d:pos`, and `NLTagger` — linked already, for lemmas — says how the
/// word is being used, so this is a fact both sides already have rather than a tuned threshold. It
/// is applied to **every** rung, so no rung is compared against another on a different field.
///
/// It only ever narrows: if the tagger did not commit, or nothing matches — a dictionary that
/// labels its blocks in another vocabulary, or a tagger that read the word wrongly — the full set
/// is kept. A filter that can empty the field would turn one wrong reading into a wrong answer.
///
/// **A label is matched by word, never by prefix and never by substring.** A dictionary qualifies
/// the part of speech: 牛津英汉汉英 prints `plural noun`, `transitive verb`, `impersonal verb`,
/// `adverb phrase`, and a `plural noun` sense is a noun sense. Matched by prefix, the tagger's
/// "noun" kept 牛津's `noun` block and dropped its `plural noun` one — which is where *sanction*'s
/// commonest reading lives ("sanctions against the regime"), and *water*'s "the waters",
/// *content*'s "contents", *rain*'s "the rains". Measured 2026-09-21: six of twenty-six words
/// narrowed to a subset missing senses of the very part of speech asked for. By substring it would
/// be wrong the other way — `adverb` contains `verb` — which is the same reason the entry parser
/// matches classes by token.
///
/// It stays inert where the vocabulary is not English words at all: 譯典通 labels its blocks `n.`
/// and `vt.`, nothing matches, and the whole entry goes to the selector.
public enum PartOfSpeechFilter {
    public static func narrow(_ candidates: [SenseCandidate], to partOfSpeech: String?) -> [SenseCandidate] {
        guard let partOfSpeech, !partOfSpeech.isEmpty else { return candidates }
        let wanted = partOfSpeech.lowercased()
        let matching = candidates.filter { candidate in
            candidate.partOfSpeech?.lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .contains(Substring(wanted)) ?? false
        }
        return matching.isEmpty ? candidates : matching
    }
}

/// The candidates a rung will actually consider, before any scoring.
///
/// Shared by every rung deliberately: two rungs that narrowed differently would be compared on
/// different fields, and the measurement would be reading the narrowing rather than the rungs. It
/// drops the senses the dictionary cannot key — a choice among those could never be recorded
/// anywhere — then narrows to the part of speech the word actually carries, which only ever
/// narrows and never empties.
public enum SenseCandidates {
    public static func considered(
        _ candidates: [SenseCandidate], matching partOfSpeech: String?
    ) -> [SenseCandidate] {
        let keyable = candidates.filter { $0.keyKind != SenseKeyKind.none && !$0.text.isEmpty }
        return PartOfSpeechFilter.narrow(keyable, to: partOfSpeech)
    }

    /// What a rung settles **before** asking anything: nothing to choose between, one sense, or no
    /// sentence to choose by. Every rung answered these three the same way in its own copy of the
    /// same eight lines — and a copy is where the answers drift apart.
    enum Preflight {
        /// Ask: these candidates, that sentence.
        case ask([SenseCandidate], sentence: String)
        /// Nothing to ask; this is the answer.
        case settled(SenseSelection)
    }

    static func preflight(
        _ candidates: [SenseCandidate], matching partOfSpeech: String?, reading sentence: String?,
        context: CaptureQuality.Context
    ) -> Preflight {
        let considered = considered(candidates, matching: partOfSpeech)
        guard !considered.isEmpty else { return .settled(.abstained(.noCandidates)) }
        // One sense is not a choice. Nothing was chosen, so nothing can be wrong.
        guard considered.count > 1 else {
            return .settled(.chose(key: considered[0].key, margin: .infinity, entryID: considered[0].entryID))
        }
        guard context == .complete, let sentence,
              !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .settled(.abstained(.noContext)) }
        return .ask(considered, sentence: sentence)
    }
}

/// Rung 1: `NLEmbedding` cosine distance between the reader's sentence and each sense's text.
///
/// It costs nothing — `NaturalLanguage` is already linked for `NLTagger`, it is offline,
/// deterministic, has no cold start and no memory footprint. Its job is to be the number every
/// rung above it has to beat on evidence. **A rung that cannot beat this is a dependency bought for
/// nothing** (decision D6).
public struct EmbeddingSenseSelector: SenseSelecting {
    /// Below this, two senses are not distinguishable by this instrument, and rounding must not
    /// separate them. Fixed before the first measurement, per D6.
    public static let minimumMargin = 0.03
    /// Beyond this, nothing in the entry is close to the sentence.
    public static let maximumDistance = 1.45

    private let minimumMargin: Double
    private let maximumDistance: Double
    private let matchesPartOfSpeech: Bool
    private let embedding: @Sendable (NLLanguage) -> NLEmbedding?

    public init(
        minimumMargin: Double = EmbeddingSenseSelector.minimumMargin,
        maximumDistance: Double = EmbeddingSenseSelector.maximumDistance,
        matchesPartOfSpeech: Bool = true,
        embedding: @escaping @Sendable (NLLanguage) -> NLEmbedding? = { NLEmbedding.sentenceEmbedding(for: $0) }
    ) {
        self.minimumMargin = minimumMargin
        self.maximumDistance = maximumDistance
        self.matchesPartOfSpeech = matchesPartOfSpeech
        self.embedding = embedding
    }

    public func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?
    ) async -> SenseSelection {
        // A dictionary that cannot key its senses offers nothing to choose between, so this can
        // never yield a sense-level choice for one. And, measured: "kept a tight rein on spending"
        // drew the *verb* "to hold something back" over the noun "the power to steer or restrain"
        // — the meaning right, the grammar wrong. The three answers before any scoring are the
        // shared ones, so no rung answers them differently from another.
        let keyable: [SenseCandidate], reading: String
        switch SenseCandidates.preflight(
            candidates, matching: matchesPartOfSpeech ? partOfSpeech : nil, reading: sentence,
            context: context
        ) {
        case .settled(let answer): return answer
        case .ask(let asking, let sentence): (keyable, reading) = (asking, sentence)
        }

        let scored = rank(keyable, reading: reading)
        guard let best = scored.first else { return .abstained(.unavailable) }
        guard best.distance <= maximumDistance else { return .abstained(.nothingFits) }

        // The list is in distance order, so the first entry holding a *different* key is the
        // runner-up. Keys repeat across entries: a positional key is literally
        // "\(block).\(ordinal)", so a margin measured against a second copy of the favourite's
        // own key would be zero, and a set with no real rival in it would abstain as "too close".
        let runnerUp = scored.first { $0.candidate.key != best.candidate.key }?.distance
        guard let runnerUp else {
            return .chose(key: best.candidate.key, margin: .infinity, entryID: best.candidate.entryID)
        }
        let margin = runnerUp - best.distance
        guard margin >= minimumMargin else {
            // The favourite is kept rather than discarded. It is not a choice — the margin says
            // so — but it is the most useful thing known about a sentence that does not settle.
            return .abstained(
                .tooClose,
                nearest: NearMiss(key: best.candidate.key, margin: margin, among: scored.count))
        }
        return .chose(key: best.candidate.key, margin: margin, entryID: best.candidate.entryID)
    }

    /// The candidates in distance order, nearest first — the scoring half of `choose`, with none
    /// of its thresholds.
    ///
    /// Separate because three callers want the *ordering* rather than the decision: `choose`
    /// itself, the recall@K measurement, and `ShortlistSenseSelector`, which hands the top of this
    /// list to a model. Empty where the space cannot run — no dominant language, no embedding for
    /// it, or nothing that scored a finite distance — which every caller reads as `.unavailable`.
    ///
    /// **It filters nothing.** The keyable and part-of-speech narrowing belong to the caller and
    /// are applied once, so a shortlist and a direct choice are ranked over exactly the same set
    /// and the comparison between them stays like for like.
    public func rank(
        _ candidates: [SenseCandidate], reading sentence: String
    ) -> [(candidate: SenseCandidate, distance: Double)] {
        guard let language = NLLanguageRecognizer.dominantLanguage(for: sentence),
              let space = embedding(language)
        else { return [] }

        var scored: [(candidate: SenseCandidate, distance: Double)] = []
        for candidate in candidates {
            let distance = space.distance(between: sentence, and: candidate.text)
            // `distance` answers a finite number even for text it cannot place; an infinite or NaN
            // reading is the model declining, and is dropped rather than sorted as "very far".
            guard distance.isFinite else { continue }
            scored.append((candidate, distance))
        }
        // Ordered with the original position as the tiebreak, because **Swift's sort is not
        // stable**: two senses at an identical distance would otherwise be free to change places
        // between runs, and which one became "the favourite" would be luck.
        return scored.indices
            .sorted { scored[$0].distance == scored[$1].distance
                ? $0 < $1 : scored[$0].distance < scored[$1].distance }
            .map { scored[$0] }
    }
}

/// The ladder: the best rung that can actually run here, falling back only when a rung is *absent*.
///
/// This is not a "try until one answers" loop, and the distinction is the whole point. A rung that
/// **abstained** has decided, and its decision stands — falling through to a lower rung on a real
/// abstention would rebuild exactly the thing abstention exists to prevent: a selector that always
/// answers. Only a rung that did not get to decide falls through: `.unavailable`, the model is not
/// here, and `.refused`, it declined the sentence — for which the next rung is the right answer and
/// has always been.
///
/// **Where nothing below a refusal answers either, the refusal is what is reported**, not
/// "unavailable": the reader's lookup met a model that declined, and that is the more specific
/// fact. Where a lower rung does answer, its answer stands and is recorded as its own.
///
/// It matters because Apple Intelligence is unavailable in mainland China, a core audience, and on
/// plenty of Macs besides: measured `deviceNotEligible` on the development Mac and `available` on
/// the E2E machine. The local model is the top rung for every reader who has downloaded it; Apple's
/// is the second, and runs while the download is pending, declined, or does not fit; `NLEmbedding`
/// is the floor. None of them is a selector that guesses.
public struct LadderSenseSelector: SenseSelecting {
    private let rungs: [any SenseSelecting]

    /// Highest rung first. Without the model service — which only the app can reach — the default
    /// ladder is Apple's on-device model, then `NLEmbedding`.
    public init(rungs: [any SenseSelecting] = [FoundationModelsSenseSelector(), EmbeddingSenseSelector()]) {
        self.rungs = rungs
    }

    public func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?
    ) async -> SenseSelection {
        var refused = false
        for rung in rungs {
            // **A cancelled lookup asks nothing more.** The reader has moved on — every rung below
            // would be work for an answer nobody is waiting for, and a rung that reports a
            // cancellation as "not here" would otherwise walk the whole ladder doing it.
            guard !Task.isCancelled else { return .abstained(refused ? .refused : .unavailable) }
            let answer = await rung.choose(
                from: candidates, reading: sentence, context: context, partOfSpeech: partOfSpeech)
            // Cancelled *while* the rung answered: the reader has moved on, and an answer nobody
            // waited for must not be written down as a sense a model chose for them.
            guard !Task.isCancelled else { return .abstained(refused ? .refused : .unavailable) }
            switch answer.abstention {
            case .unavailable: continue
            case .refused: refused = true
            default: return answer
            }
        }
        return .abstained(refused ? .refused : .unavailable)
    }
}

/// Configuration 3: the embedding **shortlists**, and a stronger rung decides among the shortlist.
///
/// The reason to want it is prompt size, not accuracy. Apple's on-device model is prefill-bound and
/// measured at 0.8–2.4 s against a 1 s panel budget. Measured 2026-09-22 on NOAD's *run*: 27
/// keyable senses, 13 once narrowed to the verb, which is a 2,952-character prompt against 1,211
/// for the best five — **59% less prompt, not the order of magnitude an earlier note implied.**
/// That note's "73 senses" was the part-of-speech filter failing to narrow at all, which was fixed
/// on 2026-09-21; the number to argue from is 13, and whether 59% is worth a rung is what the
/// latency measurement has to say.
///
/// Its accuracy is **capped by the embedding's recall@K** — a sense the shortlist dropped is one
/// the decider can never recover — so `theEmbeddingsRecallAtKIsMeasured` is the measurement that
/// says whether any given K is safe. Measured 2026-09-22 on the labelled set: recall@5 is 6/6 with
/// the part-of-speech filter and without it, against a top-1 of 3/6 and 2/6. The ranking is far
/// better at *not losing* the answer than at *finding* it, which is exactly the property a
/// shortlist needs and the property top-1 accuracy hides.
/// **Not in the default ladder, on purpose.** Measured on the E2E machine 2026-09-22
/// (`plan-sense-popup.md`): on the labelled set, whose words offer 2–5 candidates once narrowed,
/// it is the embedding's 40 ms added to an unchanged model call and is *slower* than the model
/// alone — 480 ms against 445. On NOAD's *run* it is 737 ms against 112. So it pays only where the
/// shortlist removes something, and where that threshold sits is a decision six English cases
/// cannot make. This type exists so the next measurement has something to measure; it is wired to
/// nothing until the labelled set can say when to use it.
public struct ShortlistSenseSelector: SenseSelecting {
    public let shortlist: Int
    /// Only `rank` is used, so this instance's own part-of-speech setting is irrelevant — the
    /// narrowing happens once here, before ranking.
    private let ranker: EmbeddingSenseSelector
    private let decider: any SenseSelecting
    private let matchesPartOfSpeech: Bool

    public init(
        shortlist: Int, decider: any SenseSelecting,
        ranker: EmbeddingSenseSelector = EmbeddingSenseSelector(),
        matchesPartOfSpeech: Bool = true
    ) {
        self.shortlist = max(1, shortlist)
        self.decider = decider
        self.ranker = ranker
        self.matchesPartOfSpeech = matchesPartOfSpeech
    }

    public func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?
    ) async -> SenseSelection {
        let considered: [SenseCandidate], reading: String
        switch SenseCandidates.preflight(
            candidates, matching: matchesPartOfSpeech ? partOfSpeech : nil, reading: sentence,
            context: context
        ) {
        case .settled(let answer): return answer
        case .ask(let asking, let sentence): (considered, reading) = (asking, sentence)
        }

        let ranked = ranker.rank(considered, reading: reading)
        // **A shortlist it could not build is not an abstention.** Where the embedding cannot run
        // — which is every Traditional Chinese, Japanese and Korean sentence, measured — the
        // decider is handed everything instead. Abstaining here would make this arrangement
        // strictly worse than the decider alone for exactly the readers who have no other rung.
        let shortlisted = ranked.isEmpty
            ? considered
            : ranked.prefix(shortlist).map(\.candidate)

        // The part of speech is passed on although the narrowing is already done: the decider may
        // put it in its prompt, and narrowing an already-narrowed set is a no-op.
        return await decider.choose(
            from: shortlisted, reading: reading, context: context, partOfSpeech: partOfSpeech)
    }
}
