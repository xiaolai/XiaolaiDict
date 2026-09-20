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
    /// The selector could not run at all — no embedding for this language, or a refusal.
    case unavailable

    /// What the panel says instead of a mark. It says why it did not choose, which is the other
    /// half of "the popup can mark a sense, and can say why it did not".
    public var reason: String {
        switch self {
        case .noCandidates: "This dictionary does not mark its senses, so XiaolaiDict cannot say which one you read."
        case .noContext: "No sentence was captured around the word, so XiaolaiDict cannot tell its senses apart."
        case .tooClose: "Several senses fit this sentence equally well."
        case .nothingFits: "No sense in this entry clearly fits this sentence."
        case .unavailable: "XiaolaiDict could not compare this sentence against the senses."
        }
    }
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
public enum PartOfSpeechFilter {
    public static func narrow(_ candidates: [SenseCandidate], to partOfSpeech: String?) -> [SenseCandidate] {
        guard let partOfSpeech, !partOfSpeech.isEmpty else { return candidates }
        let matching = candidates.filter { $0.partOfSpeech?.lowercased().hasPrefix(partOfSpeech) ?? false }
        return matching.isEmpty ? candidates : matching
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
        // never yield a sense-level choice for one.
        var keyable = candidates.filter { $0.keyKind != SenseKeyKind.none && !$0.text.isEmpty }
        guard !keyable.isEmpty else { return .abstained(.noCandidates) }

        // Measured: "kept a tight rein on spending" drew the *verb* "to hold something back"
        // over the noun "the power to steer or restrain" — the meaning right, the grammar wrong.
        if matchesPartOfSpeech { keyable = PartOfSpeechFilter.narrow(keyable, to: partOfSpeech) }
        // One sense is not a choice. It is answered by `onlySense` before any selector runs, and if
        // it reaches here it is still not something a model got right.
        guard keyable.count > 1 else {
            return .chose(key: keyable[0].key, margin: .infinity, entryID: keyable[0].entryID)
        }

        guard context == .complete, let sentence, !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .abstained(.noContext) }

        guard let language = NLLanguageRecognizer.dominantLanguage(for: sentence),
              let space = embedding(language)
        else { return .abstained(.unavailable) }

        var scored: [(key: String, entryID: String, distance: Double)] = []
        for candidate in keyable {
            let distance = space.distance(between: sentence, and: candidate.text)
            // `distance` answers a finite number even for text it cannot place; an infinite or NaN
            // reading is the model declining, and is dropped rather than sorted as "very far".
            guard distance.isFinite else { continue }
            scored.append((candidate.key, candidate.entryID, distance))
        }
        guard let best = scored.min(by: { $0.distance < $1.distance }) else { return .abstained(.unavailable) }
        guard best.distance <= maximumDistance else { return .abstained(.nothingFits) }

        let runnerUp = scored.filter { $0.key != best.key }.map(\.distance).min()
        guard let runnerUp else {
            return .chose(key: best.key, margin: .infinity, entryID: best.entryID)
        }
        let margin = runnerUp - best.distance
        guard margin >= minimumMargin else {
            // The favourite is kept rather than discarded. It is not a choice — the margin says
            // so — but it is the most useful thing known about a sentence that does not settle.
            return .abstained(
                .tooClose, nearest: NearMiss(key: best.key, margin: margin, among: scored.count))
        }
        return .chose(key: best.key, margin: margin, entryID: best.entryID)
    }
}

/// The ladder: the best rung that can actually run here, falling back only when a rung is *absent*.
///
/// This is not a "try until one answers" loop, and the distinction is the whole point. A rung that
/// **abstained** has decided, and its decision stands — falling through to a lower rung on a real
/// abstention would rebuild exactly the thing abstention exists to prevent: a selector that always
/// answers. Only `.unavailable` — the model is not on this Mac, or it refused — falls through.
///
/// It matters because Apple Intelligence is unavailable in mainland China, a core audience, and on
/// plenty of Macs besides: measured `deviceNotEligible` on the development Mac and `available` on
/// the E2E machine. The reader in Shanghai gets rung 1; the reader in Tokyo gets rung 2; neither
/// gets a selector that guesses.
public struct LadderSenseSelector: SenseSelecting {
    private let rungs: [any SenseSelecting]

    /// Highest rung first. The default ladder is Apple's on-device model, then `NLEmbedding`.
    public init(rungs: [any SenseSelecting] = [FoundationModelsSenseSelector(), EmbeddingSenseSelector()]) {
        self.rungs = rungs
    }

    public func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?
    ) async -> SenseSelection {
        var last: SenseSelection = .abstained(.unavailable)
        for rung in rungs {
            last = await rung.choose(
                from: candidates, reading: sentence, context: context, partOfSpeech: partOfSpeech)
            guard last.abstention == .unavailable else { return last }
        }
        return last
    }
}
