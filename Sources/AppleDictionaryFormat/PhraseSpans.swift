import Foundation

/// Which span of a sentence is a phrase the reader's dictionary knows.
///
/// **This is the half that was missing, and it is the smaller half.** `DictionaryBridge` already answers
/// any phrase string with the phrase's own entry — *purple passage* is `m_en_gbus0830950`, *kick the
/// bucket* carries 7 senses, *beat around the bush* 14. What no part of the app could do was notice that
/// *purple passage* in a sentence is a phrase at all, which is exactly the failure worth catching: the
/// reader sees two familiar words, feels no doubt, and never looks it up.
///
/// So this supplies no senses, no entries and no identity. Nothing here can orphan a study item, and the
/// sense-key question does not arise.
///
/// **The key index is cheap.** The phrase list is read straight from `KeyText.data`: NOAD yields
/// **104,009** multi-word keys in about a second, against 319 MB and 317 s for the full index. Re-reading
/// is cheap enough that staleness is not a problem to solve.
///
/// **A phrase is not always written unbroken.** *take what people think into account* is
/// `take something into account`, and a matcher that only looks at adjacent words misses every separable
/// phrasal verb. Where the phrase is an **idiom**, nothing needs to be guessed about where the object
/// goes, because the publisher wrote the slot down: **1,572** of NOAD's multi-word keys and **211** of the
/// sub-entry labels found nowhere else spell `something`, `someone`, `one's` or `oneself` at exactly that
/// position (measured 2026-09-29). So a phrase is a `Template` — the literal words, and the gaps between
/// them.
///
/// **A plain phrasal verb is not marked, and that is the harder half.** NOAD files `turn down`,
/// `give away` and `look after` bare: `give`, `look` and `turn` have 93, 43 and 48 sub-entries between
/// them and not one carries a slot. So *turn the offer down* is separable as a fact about English rather
/// than about the dictionary, and `Separation` keeps the two apart so a caller cannot mistake a guess for
/// a publisher's mark.
///
/// **A dictionary stores its keys in lemma form.** `give up` is a key and `gave up` is not, so a caller
/// normalises each word of the sentence before asking — `Lemmatizer` resolves 8 of 8 measured irregulars
/// when it has the sentence, which it does here. The words handed in are expected to be already
/// normalised and case-folded; this type does no language work of its own, because the module deliberately
/// links nothing but Foundation, Compression, CryptoKit and SQLite3.
///
/// **A span is a candidate, never a verdict.** `AGENTS.md` — *phrase length does not choose the unit…
/// only the selector collapses the set*. A match is offered beside the hovered word's own senses and the
/// sentence decides between them, which is why `widestGap` can afford to be generous: a span the selector
/// rejects costs a candidate, not a wrong answer shown to a reader.
public struct PhraseSpans: Sendable, Equatable {
    /// A phrase as the dictionary spells it, split at the slots the publisher wrote.
    ///
    /// `take something into account` is `[["take"], ["into", "account"]]` — two runs of literal words with
    /// one slot between them. `account for something` is `[["account", "for"]]`: a trailing slot names no
    /// gap inside the phrase, so that template matches adjacent words like any other.
    public struct Template: Sendable, Equatable, Hashable {
        /// The dictionary's own spelling, slots included. **This is what a lookup asks for** — the entry
        /// is filed under the template, not under the words the reader happened to write.
        public let phrase: String

        /// The literal words, in order, grouped into the runs the slots divide them into.
        public let runs: [[String]]

        /// How much of the phrase is literal words. A template is ranked by this before anything else.
        var literals: Int { runs.reduce(0) { $0 + $1.count } }

        /// **A two-word phrasal verb the publisher wrote unbroken, which English lets a reader break.**
        ///
        /// The slot answer above covers only what the dictionary marks, and measurement says that is the
        /// idioms: NOAD files `take something under advisement` and `do someone's bidding` with the slot,
        /// and files `turn down`, `give away` and `look after` bare. So *turn the offer down* is separable
        /// as a fact about English rather than a fact about the dictionary, and this flag is the one place
        /// this type infers anything.
        ///
        /// Restricted hard, because an inference is noise on every sentence and a marked slot is not:
        /// exactly two literal words, no slots, and the second must be in `particles`.
        var separable: Bool {
            runs.count == 1 && runs[0].count == 2 && PhraseSpans.particles.contains(runs[0][1])
        }

        init?(phrase: String) {
            var runs: [[String]] = []
            var run: [String] = []
            for word in PhraseSpans.tokens(of: phrase) {
                if PhraseSpans.slots.contains(word) {
                    if !run.isEmpty { runs.append(run) }
                    run = []
                } else {
                    run.append(word)
                }
            }
            if !run.isEmpty { runs.append(run) }
            // **A single literal word is never a phrase**, however many slots surround it: the bridge
            // already looks one word up, and admitting `take something` here would make an ordinary
            // hover claim to have found a phrase.
            guard runs.reduce(0, { $0 + $1.count }) > 1 else { return nil }
            self.phrase = phrase
            self.runs = runs
        }
    }

    /// Whether the words of the phrase sat together, and on whose authority they were allowed not to.
    ///
    /// **Three-valued because the two kinds of gap carry different weight.** A gap the publisher marked is
    /// the dictionary telling us an object goes there; a gap this matcher inferred from a particle is a
    /// guess about English that the publisher did not make. A caller that flattened the two into one
    /// integer would hand the selector a marked nine-word span and an inferred two-word span as if they
    /// were the same kind of evidence.
    public enum Separation: Sendable, Equatable {
        /// Written unbroken, exactly as the dictionary spells it.
        case none
        /// The publisher wrote a slot here, and this many words of the sentence filled it.
        case marked(Int)
        /// The publisher wrote the phrase unbroken; the gap is this matcher's own inference.
        case inferred(Int)
    }

    /// One phrase found around one hovered word.
    public struct Match: Sendable, Equatable {
        /// The dictionary's own spelling — slots and all — which is the string to look up.
        public let phrase: String

        /// First through last matched word of the sentence handed in, gap included.
        public let words: ClosedRange<Int>

        /// Whether the phrase was written unbroken, and if not, who said it could be.
        public let separation: Separation

        /// How many words of the sentence the span stepped over. **Zero for a phrase written unbroken**,
        /// and a signal the selector can weigh: a wide gap is weaker evidence than a narrow one.
        public var gap: Int {
            switch separation {
            case .none: 0
            case .marked(let words), .inferred(let words): words
            }
        }
    }

    /// What a publisher writes where the reader writes an object. Taken from the labels themselves rather
    /// than from a guess about English: these are the forms measured in NOAD's keys and sub-entries.
    static let slots: Set<String> = [
        "something", "someone", "somebody", "someone's", "somebody's", "one's", "oneself",
    ]

    /// A phrase's words, as the dictionary wrote them.
    ///
    /// **Whitespace, and nothing else.** Splitting on a single space missed the labels where a slot was
    /// elided — `a   and a half` — and any tokenisation finer than this disagrees with the key: 4,102 phrases
    /// were unreachable because `NLTagger` splits `24-hour` into two words and `one's` into `one` and `'s`,
    /// while the key spells each as one. The caller tokenises the reader's sentence the same way.
    static func tokens(of phrase: String) -> [String] {
        phrase.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The particles a two-word phrasal verb may be broken around.
    ///
    /// **Deliberately short, and shortening it is the safe direction.** Every word here is adverbial in
    /// the separable construction — *turn the light on*, *give the plan up*. The prepositional particles
    /// are left out on purpose: *look after* is not separable, and admitting `after` would match *look* at
    /// the child *after* lunch. Adding a word to this set is a measurable change to the false-positive
    /// rate, not a spelling fix.
    static let particles: Set<String> = [
        "up", "down", "out", "off", "in", "on", "over", "away", "back",
        "together", "apart", "aside", "forward",
    ]

    /// How far apart the literal words of one phrase may sit **where the publisher marked the slot**.
    ///
    /// Measured: across 598 fillings of a marked slot in NOAD's own example sentences, the object is
    /// **p50 1, p90 2, p95 2, p99 3, max 4** words (2026-09-29). So the publisher's prose never needs more
    /// than four — but the reader's does: the sentence that raised this question,
    /// *take what people think and other possible edge cases all into account*, puts **nine** words in the
    /// slot, and its object contains "and", so no clause rule would rescue a tighter cap either.
    ///
    /// The cap therefore sits above real prose rather than above the examples, and `Separation.marked`
    /// carries the width so the selector can weigh a nine-word span against a one-word one. That is the
    /// right division of labour: **this type does not decide, it reports.**
    public static let widestGap = 12

    /// How far apart a phrasal verb may be broken **on this matcher's own inference**.
    ///
    /// Tight where `widestGap` is generous, because nobody marked this gap. Set at the p99 of the 598
    /// measured fillings: past three words an inferred split is more likely two clauses than one object.
    public static let widestInferredGap = 3

    /// Multi-word keys only, exactly as given — slot forms included.
    public let phrases: Set<String>

    /// The most literal words any one phrase here has. Slots do not count toward it, because a slot
    /// matches words rather than being one.
    public let longest: Int

    /// Unsorted, and **built on demand**.
    ///
    /// An earlier version constructed every `Template` up front and sorted them by phrase. Both were waste:
    /// the sort is redundant because `match` breaks its last tie on `phrase` anyway, and constructing 116,122
    /// templates — each an array of arrays — cost **1.36 s** of a 2.8 s startup to answer questions about the
    /// twenty or so a given hover can touch. The phrase strings are kept; a `Template` is made when a hover
    /// actually reaches it.
    let phraseList: [String]

    /// Literal word to the templates containing it. **A hover looks at the templates naming the word under
    /// the pointer and at nothing else**, which is what keeps a 100,000-phrase inventory a hash lookup
    /// rather than a scan.
    let byWord: [String: [Int]]

    public init(phrases: Set<String>) {
        let multiword = phrases.filter { $0.contains(" ") }
        var list: [String] = []
        list.reserveCapacity(multiword.count)
        var byWord: [String: [Int]] = [:]
        byWord.reserveCapacity(multiword.count)
        var longest = 1
        for phrase in multiword {
            // **The words, without building the template.** Indexing needs to know which literal words a
            // phrase contains; it does not need the runs-and-gaps structure, which is the allocation-heavy
            // part and is only wanted for a phrase a hover actually reaches.
            var literals = 0
            var seen: Set<String> = []
            for word in Self.tokens(of: phrase) where !Self.slots.contains(word) {
                literals += 1
                seen.insert(word)
            }
            guard literals > 1 else { continue }
            let index = list.count
            list.append(phrase)
            for word in seen { byWord[word, default: []].append(index) }
            longest = max(longest, literals)
        }
        self.phrases = multiword
        self.phraseList = list
        self.byWord = byWord
        self.longest = longest
    }

    /// Every multi-word key of one dictionary, read from its key index.
    ///
    /// `xpointer(` forms are skipped: they are locators into a document, not spellings of a word, and the
    /// same fragments once made sub-entry scoping match the wrong phrase.
    ///
    public init(bundle: URL) throws {
        try self.init(bundle: bundle, labels: [])
    }

    /// The whole inventory: the dictionary's multi-word keys **and** the sub-entry labels only the body
    /// holds, which `IndexStore.subEntryLabels(in:)` has already walked for.
    ///
    /// **This is what the index buys the phrase feature.** Keys alone give 104,009 phrases in about a
    /// second and miss `take something into account`, `beat around the bush`, `once in a blue moon` and
    /// `cost an arm and a leg` — every one of which a reader meets and none of which they would think to
    /// look up. The labels add 935 phrases NOAD files nowhere else, 211 of them carrying a slot, and cost
    /// a query rather than the 60-second body walk that produced them (measured 2026-09-29).
    public init(bundle: URL, labels: Set<String>) throws {
        self.init(phrases: try Self.keys(in: bundle)
            .union(labels.map { $0.lowercased() }.filter { $0.contains(" ") }))
    }

    /// Every multi-word key of one dictionary, without building a matcher around them.
    ///
    /// For a caller collecting the inventory of several dictionaries: building one `PhraseSpans` per bundle
    /// only to read `phrases` off it computes a template index per dictionary and throws each away.
    public static func keys(in bundle: URL) throws -> Set<String> {
        var found = Set<String>()
        // **Every key of the group, not just the first.** A group is a folded search key followed by
        // display forms, so `keys.first` alone loses the spellings a reader actually writes: measured
        // 2026-09-29, 90,391 phrases from the first key against **104,009** from all of them.
        for group in try KeyIndexReader.groups(in: bundle) {
            for key in group.keys where key.contains(" ") && !key.contains("xpointer(") {
                // **Lowercased here.** 8,046 of 116,122 phrases were unreachable for case alone — `5 Eyes`,
                // `A. A. Milne` — because the reader's sentence arrives case-folded and these did not.
                found.insert(key.lowercased())
            }
        }
        return found
    }

    /// The dictionary's spelling of the phrase covering `word`, or nil where the reader is on an ordinary
    /// word.
    public func phrase(in words: [String], containing word: Int) -> String? {
        match(in: words, containing: word)?.phrase
    }

    /// The phrase covering `word`, with the span it occupies and the gap it stepped over.
    ///
    /// **It must contain the hovered word, and contain it as a literal.** A phrase elsewhere in the
    /// sentence is not what the reader pointed at, and a word that merely fell inside somebody else's slot
    /// is not part of the phrase at all — hovering *people* in *take what people think into account* is
    /// hovering *people*.
    public func match(in words: [String], containing word: Int,
                      widestGap: Int = PhraseSpans.widestGap,
                      widestInferredGap: Int = PhraseSpans.widestInferredGap) -> Match? {
        match(in: words.map { [$0] }, containing: word,
              widestGap: widestGap, widestInferredGap: widestInferredGap)
    }

    /// The phrase covering `word`, where each position offers **every form the dictionary might file it
    /// under** — as the reader wrote it, and its dictionary form.
    ///
    /// **Choosing one form loses 36,766 of 116,122 phrases.** A dictionary does not file every phrase in lemma
    /// form: `by all accounts` needs the plural, `on one's last legs` needs it twice, `mass produced` needs the
    /// participle. Lemmatising the reader's sentence turns those into `by all account` and matches nothing.
    /// Meanwhile *kept a tight rein on* is only findable **through** the lemma. Both are true at once, so the
    /// sentence offers both and the dictionary decides — the same rule as everywhere else on this path:
    /// nothing may delete a candidate, only the selector collapses the set.
    public func match(in words: [[String]], containing word: Int,
                      widestGap: Int = PhraseSpans.widestGap,
                      widestInferredGap: Int = PhraseSpans.widestInferredGap) -> Match? {
        guard words.indices.contains(word) else { return nil }
        // `borrowed` counts the positions matched through a form the reader did not write.
        var found: [(literals: Int, borrowed: Int, match: Match)] = []
        // Every form of the hovered word, because the phrase may be filed under any of them.
        var reachable: [Int] = []
        var seen = Set<Int>()
        for form in words[word] {
            for index in byWord[form] ?? [] where seen.insert(index).inserted { reachable.append(index) }
        }
        for index in reachable {
            // Built here, for the handful of phrases naming this word, rather than for all 116,122 up front.
            guard let template = Template(phrase: phraseList[index]) else { continue }
            guard let hit = Self.tightest(template, in: words, containing: word,
                                          widestGap: widestGap,
                                          widestInferredGap: widestInferredGap) else { continue }
            found.append((template.literals, hit.borrowed, hit.match))
        }
        // **More of the phrase written out wins, then the narrower gap.** A span the reader can see whole
        // is better evidence than one assembled across a clause; `phrase` breaks the last tie only so that
        // the same sentence always answers the same way.
        found.sort { first, second in
            if first.literals != second.literals { return first.literals > second.literals }
            if first.match.gap != second.match.gap { return first.match.gap < second.match.gap }
            // **Then the reader's own spelling.** *mass produced* and *mass produce* are both keys, and a
            // reader who wrote the participle meant the first; without this the alphabetical tie-break chose
            // the second — the right phrase's neighbour, shown as the phrase. Same for `24 hour clocks`
            // against `24 hour clock`.
            if first.borrowed != second.borrowed { return first.borrowed < second.borrowed }
            return first.match.phrase < second.match.phrase
        }
        return found.first?.match
    }

    /// The narrowest placement of one template that covers the hovered word.
    ///
    /// Two passes, and **the order is the ranking**: the phrase as the publisher spelled it first, then —
    /// only for a separable two-word verb, and only if that found nothing unbroken — the inferred split.
    /// A contiguous reading is never given up for a guess.
    private static func tightest(_ template: Template, in words: [[String]], containing word: Int,
                                 widestGap: Int, widestInferredGap: Int) -> (match: Match, borrowed: Int)? {
        var best: Match?
        var borrowed = 0
        func consider(_ runs: [[String]], cap: Int, inferred: Bool) {
            for starts in placements(runs, in: words, from: 0, through: words.count - 1, widestGap: cap)
            where covers(starts, runs, word) {
                guard let first = starts.first, let last = starts.last, let tail = runs.last else { continue }
                let span = first ... (last + tail.count - 1)
                let gap = span.count - template.literals
                guard gap <= cap else { continue }
                let separation: Separation = gap == 0 ? .none
                    : (inferred ? .inferred(gap) : .marked(gap))
                if best == nil || gap < best!.gap {
                    best = Match(phrase: template.phrase, words: span, separation: separation)
                    borrowed = Self.borrowedForms(runs, at: starts, in: words)
                }
            }
        }
        consider(template.runs, cap: widestGap, inferred: false)
        if best == nil, template.separable, let pair = template.runs.first {
            consider([[pair[0]], [pair[1]]], cap: widestInferredGap, inferred: true)
        }
        return best.map { ($0, borrowed) }
    }

    /// How many positions of this placement matched a form the reader did not write.
    ///
    /// **Zero where the key is spelled exactly as the sentence spells it.** `candidates` puts the written form
    /// first, and this is what turns that documented order into a preference the ranking can see.
    private static func borrowedForms(_ runs: [[String]], at starts: [Int], in words: [[String]]) -> Int {
        var borrowed = 0
        for (start, run) in zip(starts, runs) {
            for (offset, expected) in run.enumerated() where words[start + offset].first != expected {
                borrowed += 1
            }
        }
        return borrowed
    }

    /// Where each run of literal words could begin, in order.
    private static func placements(_ runs: [[String]], in words: [[String]],
                                   from: Int, through: Int, widestGap: Int) -> [[Int]] {
        guard let run = runs.first else { return [[]] }
        let rest = Array(runs.dropFirst())
        var out: [[Int]] = []
        var start = from
        while start + run.count <= words.count, start <= through {
            // A run matches where **some** form of each position is the key's word there.
            if zip(run, words[start ..< start + run.count]).allSatisfy({ $1.contains($0) }) {
                let end = start + run.count
                if rest.isEmpty {
                    out.append([start])
                } else {
                    // **A slot is filled by at least one word**, so the next run cannot begin where this
                    // one ended — abutting runs spell the unslotted phrase, which is a different key.
                    for tail in placements(rest, in: words, from: end + 1,
                                           through: end + widestGap, widestGap: widestGap) {
                        out.append([start] + tail)
                    }
                }
            }
            start += 1
        }
        return out
    }

    /// Whether the hovered word falls inside a run of literal words rather than inside a slot.
    private static func covers(_ starts: [Int], _ runs: [[String]], _ word: Int) -> Bool {
        for (start, run) in zip(starts, runs) where (start ..< start + run.count).contains(word) {
            return true
        }
        return false
    }
}
