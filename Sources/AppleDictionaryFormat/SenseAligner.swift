import Foundation

/// Matching one dictionary's senses to another's, within a pair of entries the publisher has already joined.
///
/// **What this can and cannot do, measured before it was written.** Aligning 牛津英汉汉英 to NOAD over 8,644
/// entry pairs joined by a shared Oxford anchor:
///
/// | method | one clear match | too close to call | nothing shared |
/// |---|---|---|---|
/// | shared example words, best wins | 46.6% | 48.2% | 5.2% |
/// | part of speech + IDF + NOAD's definitions + a 25% margin | **53.4%** | 39.3% | 7.2% |
///
/// The first row is almost certainly the "44% by arithmetic" the feature ledger records from an earlier
/// attempt elsewhere; it reproduced at 46.6% here. The second is this matcher.
///
/// **So it settles about half, and the honest half is the point.** The 39.3% it cannot separate are cases
/// where several senses of the hub share vocabulary with one sense of the spoke, and nothing in the text
/// distinguishes them. Those are **refused**, not assigned to the highest score — the same rule
/// `KeyResolutionReport.confidence` applies to a key mapping, and for the same reason: a wrong pair a reader
/// cannot see is worse than a missing one. A model reading the Chinese translation against the English
/// definition would very likely do better, and deliberately does not live here.
///
/// **Why a bilingual dictionary cannot be matched on its definitions.** 牛津英汉汉英 marks its `d:def` on the
/// *translation* — `fine` gives `罚款` — so the two sides' definitions are not in the same language. What is
/// shared is the **English example sentences** both dictionaries print against each sense, and NOAD's own
/// definition wording. Those are the only common material, which is why the score is built from them.
public struct SenseAligner: Sendable {
    /// What produced a pair, stored beside it so a later matcher is distinguishable from this one.
    public static let method = "examples+pos+idf/1"

    /// A pair must beat the runner-up by this much to be claimed at all. A bare maximum is not a finding
    /// when the second place is a hair behind it.
    public static let requiredMargin = 1.25

    /// And a pair must rest on at least this many distinct shared words.
    ///
    /// **One word is a collocation, not a meaning.** Measured on the 8,221 pairs the score floor alone
    /// allowed: of 30 pairs sampled deterministically, 26 were right, and two of the four wrong ones were
    /// decided by a single term that the spoke's example merely collocates with — 礼堂 "a school hall" took
    /// NOAD's "the room used for meals in a college, university, or **school**" over "a large room for
    /// meetings", and 部门 "the upper/lower reaches (of government)" took "a stretch of river" from NOAD's
    /// "the **upper** reaches of the Nile". Neither shares a second word with the sense it was given.
    public static let requiredTerms = 2

    /// And it must clear this on its own, in the natural-log units `Weighting` produces.
    ///
    /// **A margin alone is not evidence.** Where only one candidate shared anything at all, the runner-up was
    /// zero, the margin was infinite, and the pair was claimed on a single common word: three senses of
    /// 牛津英汉汉英's `hold` — 握着, 咬住, 阻止 — all landed on "arrange and take part in (a meeting or
    /// conversation)" at the same confidence. 3.0 is roughly one term occurring in 5% of the hub's senses, or
    /// two at 1.5; below that the overlap is vocabulary rather than meaning.
    public static let requiredScore = 3.0

    /// Words too common to carry a sense. Deliberately short: the weighting below is what handles frequency,
    /// and a long hand-written list becomes a place where a real signal quietly goes missing.
    ///
    /// **The placeholders are here in both dictionaries' spellings.** `sb` and `sth` are how a bilingual
    /// writes a variable slot; `someone` and `something` are how NOAD writes the same slot, and ignoring only
    /// the abbreviations left the English spellings to decide pairs. Reflexives and `own` are the same thing:
    /// they mark a slot rather than name a meaning.
    static let ignored: Set<String> = [
        "the", "and", "for", "with", "that", "this", "these", "those", "from", "not", "its", "his",
        "her", "their", "them", "was", "were", "been", "are", "sth", "sb", "one", "she", "who", "you",
        "your", "our", "had", "has", "have", "him", "but", "all", "any", "out", "off",
        "someone", "somebody", "something", "anyone", "anybody", "anything", "own",
        "oneself", "itself", "himself", "herself", "themselves", "myself", "yourself",
    ]

    /// The content words of a string, **less the ones the entry is about**.
    ///
    /// The headword is in nearly every example on both sides — a NOAD example for `hold` and a
    /// 牛津英汉汉英 example for `hold` both contain "hold" — so it is the one term guaranteed to be shared and
    /// it carries no information about *which* sense. Left in, it decided the match whenever nothing else
    /// did.
    public static func terms(_ text: String, about headwords: Set<String>) -> Set<String> {
        terms(text).subtracting(headwords)
    }

    /// The content words of a string: lowercased, three letters or more, and not in `ignored`.
    ///
    /// An apostrophe stays inside a word, so `don't` is one token — but a **trailing possessive is dropped**,
    /// because `one's` is the word `one` wearing a grammatical marker and the stop list cannot see it
    /// otherwise. That is not hypothetical: NOAD's "empty (one's bowels)" was paired with 移动 *to move* on
    /// `bowels` and `one's`, two terms, which is exactly the number the term floor asks for.
    public static func terms(_ text: String) -> Set<String> {
        var out: Set<String> = []
        var word = ""
        func flush() {
            var candidate = word
            if candidate.hasSuffix("'s") { candidate.removeLast(2) }
            while candidate.hasSuffix("'") { candidate.removeLast() }
            if candidate.count >= 3, !ignored.contains(candidate) { out.insert(candidate) }
            word = ""
        }
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.lowercaseLetters.contains(scalar) || scalar == "'" {
                word.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// Inverse document frequency over the hub's senses.
    ///
    /// **A shared `money` says more than a shared `make`.** Counting bare overlap let a sense win on common
    /// vocabulary, and weighting by rarity is most of the difference between 46.6% and 53.4%.
    public struct Weighting: Sendable {
        let documents: Int
        let frequency: [String: Int]

        public init(documents: [Set<String>]) {
            self.documents = max(1, documents.count)
            var counts: [String: Int] = [:]
            for document in documents {
                for term in document { counts[term, default: 0] += 1 }
            }
            self.frequency = counts
        }

        public func weight(_ term: String) -> Double {
            log(Double(documents) / Double(1 + (frequency[term] ?? 0)))
        }

        public func score(_ a: Set<String>, _ b: Set<String>) -> Double {
            a.intersection(b).reduce(0) { $0 + weight($1) }
        }
    }

    /// One candidate on the hub side, with the text a match is scored against.
    public struct Candidate: Sendable, Equatable {
        public let senseKey: String
        public let partOfSpeech: String?
        /// Everything about this sense that is in the spoke's language — its definition wording and its
        /// examples.
        public let terms: Set<String>

        public init(senseKey: String, partOfSpeech: String?, terms: Set<String>) {
            self.senseKey = senseKey
            self.partOfSpeech = partOfSpeech
            self.terms = terms
        }
    }

    /// What a match attempt concluded.
    public enum Verdict: Sendable, Equatable {
        /// One candidate beat the rest by the required margin, on `sharedTerms` words in common.
        ///
        /// **The count is part of the evidence, not decoration.** A pair resting on one shared word is a
        /// different kind of claim from one resting on four, and the score alone cannot tell them apart: a
        /// single rare term outweighs several ordinary ones. `requiredTerms` is the rule that acts on it, and
        /// the count is reported so a caller can see the distribution rather than trust the rule.
        case matched(senseKey: String, confidence: Double, sharedTerms: Int)
        /// Two or more candidates were too close to separate. **Not a match with lower confidence** — there
        /// is no evidence which of them is right, and storing the highest would invent one.
        case tooClose(contenders: Int)
        /// Nothing was shared with any candidate, though there was material to share.
        case nothingShared
        /// **The spoke sense carries nothing this method can match on.** Distinct from `nothingShared`, and
        /// the distinction is most of the story: only 82,659 of 牛津英汉汉英's 197,386 senses print an
        /// example, so 58% have no English text at all. Reporting those as "shared nothing" blamed the
        /// matcher for a sense it was never given anything to match.
        case noMaterial
        /// No candidate survived the part-of-speech filter.
        case noCandidate
    }

    /// The part of speech, reduced to what two dictionaries can agree on.
    ///
    /// 牛津英汉汉英 writes `transitive verb` where NOAD writes `verb`, so comparing the strings rejects a pair
    /// that agrees. Comparing the family is what the filter is for.
    public static func family(of partOfSpeech: String?) -> String? {
        guard let text = partOfSpeech?.lowercased() else { return nil }
        for family in ["noun", "verb", "adjective", "adverb", "pronoun", "preposition",
                       "conjunction", "interjection", "determiner", "exclamation", "abbreviation"]
        where text.contains(family) {
            return family
        }
        return nil
    }

    let weighting: Weighting

    public init(weighting: Weighting) {
        self.weighting = weighting
    }

    /// Which hub sense a spoke sense belongs to, or why that could not be decided.
    ///
    /// The part-of-speech filter runs first and only where **both** sides declare one: 27 of 84 dictionaries
    /// mark none, and treating an absent label as a mismatch would reject every pair in them.
    public func match(spoke terms: Set<String>, partOfSpeech: String?,
                      against candidates: [Candidate]) -> Verdict {
        guard !terms.isEmpty else { return .noMaterial }
        let wanted = Self.family(of: partOfSpeech)
        let eligible = candidates.filter { candidate in
            guard let wanted, let theirs = Self.family(of: candidate.partOfSpeech) else { return true }
            return wanted == theirs
        }.filter { !$0.terms.isEmpty }
        guard !eligible.isEmpty else { return .noCandidate }

        // **A term most of this entry's senses share cannot say which of them is meant.**
        //
        // Excluding the headword was not enough, because a dictionary writes its inflections: `hold`'s own
        // form was dropped and *`held`* was not, and "a meeting was held at the church" shares it with "she
        // held me by the sleeve", "it held the worm in its beak" and "we held the thief". `held` is rare
        // across the whole dictionary, so corpus weighting rated it highly, and it decided three pairs that
        // had nothing else in common — all three wrong.
        //
        // Frequency *within the entry* is the statistic that sees this, and it needs no lemmatiser: whatever
        // form a headword takes, it turns up in most of that entry's examples, and a term in most candidates
        // is worth almost nothing. Applied only with two or more candidates — with one there is nothing to
        // discriminate between, and that case is already capped lower by the confidence below.
        let localWeight: (String) -> Double
        if eligible.count > 1 {
            var withinEntry: [String: Int] = [:]
            for candidate in eligible {
                for term in candidate.terms { withinEntry[term, default: 0] += 1 }
            }
            let n = Double(eligible.count)
            localWeight = { term in
                log((1 + n) / (1 + Double(withinEntry[term] ?? 0)))
            }
        } else {
            localWeight = { _ in 1 }
        }
        let scored = eligible
            .map { candidate -> (key: String, score: Double, shared: Int) in
                let shared = terms.intersection(candidate.terms)
                return (key: candidate.senseKey,
                        score: shared.reduce(0.0) { $0 + weighting.weight($1) * localWeight($1) },
                        shared: shared.count)
            }
            .sorted { $0.score > $1.score }
        guard let best = scored.first, best.score >= Self.requiredScore,
              best.shared >= Self.requiredTerms else { return .nothingShared }
        let runnerUp = scored.count > 1 ? scored[1].score : 0
        guard best.score > runnerUp * Self.requiredMargin else {
            // Every candidate within the margin of the leader is a contender, the leader included.
            let contenders = scored.filter { $0.score * Self.requiredMargin >= best.score }.count
            return .tooClose(contenders: max(2, contenders))
        }
        // Confidence is the margin over the runner-up, bounded — twice the runner-up is as much as this
        // evidence can claim. With no runner-up at all it rests on the score alone, and is capped below the
        // margin cases: one candidate sharing something is weaker evidence than one candidate beating another.
        let confidence = runnerUp > 0
            ? min(1.0, 0.5 + 0.5 * min(1.0, best.score / runnerUp - 1))
            : min(0.8, 0.5 + 0.3 * min(1.0, best.score / (Self.requiredScore * 3)))
        return .matched(senseKey: best.key, confidence: confidence, sharedTerms: best.shared)
    }
}
