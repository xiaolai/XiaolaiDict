/// What varies between Apple's dictionaries, and nothing that does not.
///
/// **Apple's container and markup are shared; only a handful of facts are per dictionary.** Measured
/// over all 86 assets in the macOS 27 catalogue, 2026-09-27: every entry is well-formed XML (0
/// unparsable of 100,872 read), `x_xh0` marks the headword block in 99.9% and `d:def` a definition in
/// 97.5%. So an adapter is a *capability record*, not a parser — adding a language declares facts
/// rather than writing extraction code.
///
/// Two facts genuinely vary, and both were measured rather than assumed.
public struct DictionaryProfile: Sendable, Equatable {
    /// `CFBundleIdentifier`, read from the bundle's own `Info.plist`.
    ///
    /// **Never key off the file name.** `Simplified Chinese - English.dictionary` contains
    /// `com.apple.dictionary.zh_CN-en.OCD`, the Oxford Chinese Dictionary — the package names are
    /// generic and Apple can re-point them in any release.
    public let identifier: String

    /// Which `x_xdN` depth delimits one sense. **1 for 79 of 84; five dictionaries nest deeper.**
    ///
    /// This number was measured three times and only the third question was the right one.
    ///
    /// 1. *Shallowest `x_xdN` carrying any `id`* — reported six departures. Wrong: it matched sub-sense
    ///    wrappers that have an `id` and no definition of their own.
    /// 2. *Shallowest `x_xdN` carrying a definition* — reported depth 1 for all 84. Also wrong, and more
    ///    dangerously so, because it asks whether *a* block at that depth holds *a* definition. A
    ///    dictionary can satisfy that while most of its definitions sit deeper.
    /// 3. **Retention**: indexing at this depth, what share of the definitions the markup declares reach a
    ///    sense? That is the question, because losing them is the actual harm. Measured through
    ///    `EntryIndexer` itself — Vietnamese kept **23%** at depth 1 against 103% at depth 2; Greek 48%
    ///    against 100% at depth 3.
    ///
    /// **Those figures are from the superseded metric, and one of them is now an impossible value.** It
    /// counted `d:def=` against the joined definition split on `"; "`, so a definition containing that
    /// sequence inflated the numerator and the share could exceed 1 — which is what "103%" is. The metric
    /// now counts maximal definition regions on both sides, over the union of `d:def` and `class="df"`, so
    /// it is bounded in [0, 1] and `DepthRetentionTests` asserts that. **The depths below are still the
    /// right ones by the old ranking and have not been re-ranked under the new one**, because that needs the
    /// full catalogue and none of the five is installed here.
    ///
    /// `x_xd0` is always the part-of-speech block, and anything deeper than `senseDepth` belongs to the
    /// sense above it. A rule accepting *any* `x_xdN` is wrong in the other direction: it broke
    /// 牛津英汉汉英, where `x_xd2`/`x_xd3` are subsenses.
    public let senseDepth: Int

    /// The attributes that may carry the publisher's own sense id, in order of preference.
    ///
    /// **This is the field that genuinely varies.** Measured over the 84 readable dictionaries by indexing
    /// each one twice, once with each attribute pinned: **`lexid` only in 27, `id` only in 24, both in 10,
    /// and neither in 23.** Those 23 are why `SenseKey` has a content-addressed form.
    ///
    /// An earlier probe reported 33 / 24 / 27 by looking for the attribute in the markup. It agreed on `id`
    /// exactly and was wrong on the other two, because `lexid=` also appears on elements that are not
    /// senses and because it could not represent a dictionary carrying both.
    ///
    /// **An array, and empty is a real value.** A language adapter that has measured its dictionaries
    /// pins this to exactly one attribute, or to none; the default accepts either, because for a
    /// dictionary nobody has measured "Apple uses one of these two" is the most that is known and
    /// guessing one would lose every id in the 33 that use the other. Naming a single attribute by
    /// default did exactly that: it dropped 28 dictionaries out of the validation set.
    ///
    /// Declaring none is safe rather than lossy — those senses get content keys, which is a real name,
    /// not a missing one.
    public let senseIDAttributes: [String]

    /// The single declared attribute, where a profile names exactly one. Nil when it names none or
    /// accepts several.
    public var senseIDAttribute: String? {
        senseIDAttributes.count == 1 ? senseIDAttributes[0] : nil
    }

    /// Whether this profile expects a publisher id at all.
    public var expectsPublisherID: Bool { !senseIDAttributes.isEmpty }

    /// The default accepts either attribute Apple is known to use. An adapter narrows it.
    public init(identifier: String, senseDepth: Int = 1, senseIDAttributes: [String] = ["lexid", "id"]) {
        self.identifier = identifier
        self.senseDepth = senseDepth
        self.senseIDAttributes = senseIDAttributes
    }

    /// Convenience for a profile that names exactly one attribute, or none.
    public init(identifier: String, senseDepth: Int = 1, senseIDAttribute: String?) {
        self.init(identifier: identifier, senseDepth: senseDepth,
                  senseIDAttributes: senseIDAttribute.map { [$0] } ?? [])
    }

    /// The default: senses at `x_xd1`, accepting either id attribute. Correct for **79 of 84**; the five
    /// that nest deeper are in `overrides`.
    public static func profile(for identifier: String) -> DictionaryProfile {
        if let known = overrides[identifier] { return known }
        return DictionaryProfile(identifier: identifier)
    }

    /// Departures from the default, **measured by definition retention** and nothing else.
    ///
    /// Each row is a dictionary that loses a large share of its definitions when indexed at depth 1.
    /// The figures are the retention gap that put it here; `DepthRetentionTests` re-measures every
    /// installed dictionary and fails if any declared depth is clearly not the best one, so this table
    /// cannot quietly drift and a new dictionary cannot be guessed into it.
    ///
    /// **Every figure below is from the superseded metric** — see `senseDepth` — which is why several read
    /// above 100%, a value the corrected metric cannot produce. The *ranking* is what put each row here and
    /// the ranking is what matters; the shares are kept as the historical evidence rather than re-stated as
    /// current. None of the five is installed on this Mac, so re-ranking them needs the full catalogue.
    ///
    /// **Odia and Sanskrit were left out for clearing a margin they did not clear, and both are in now.** The depth
    /// test's margin (25 points) is a guard against churn, not a standard: `DefinitionReachTests` holds every
    /// dictionary to nearly all of its declared definitions, and on that standard `or-en.oup` failed at depth 1.
    /// Re-measured 2026-10-06 on the corrected metric: Odia keeps 85.4% at depth 1 and 100.0% at depth 2
    /// (192,874 of 221,970 reached at depth 1); Sanskrit 50.9% and 100.0%. Where the shallowest depth that keeps
    /// every definition is not the default, it is the one declared.
    public static let overrides: [String: DictionaryProfile] = [
        // 23% retained at depth 1, 103% at depth 2
        "com.apple.dictionary.vi.oup": DictionaryProfile(
            identifier: "com.apple.dictionary.vi.oup", senseDepth: 2),
        // 48% at depth 1, 100% at depth 3 — the only one that needs three
        "com.apple.dictionary.el.oup": DictionaryProfile(
            identifier: "com.apple.dictionary.el.oup", senseDepth: 3),
        // 62% at depth 1, 122% at depth 2
        "com.apple.dictionary.ml-en.oup": DictionaryProfile(
            identifier: "com.apple.dictionary.ml-en.oup", senseDepth: 2),
        // 64% at depth 1, 154% at depth 2
        "com.apple.dictionary.as-en.oup": DictionaryProfile(
            identifier: "com.apple.dictionary.as-en.oup", senseDepth: 2),
        // 78% at depth 1, 153% at depth 2
        "com.apple.dictionary.kn-en.oup": DictionaryProfile(
            identifier: "com.apple.dictionary.kn-en.oup", senseDepth: 2),
        // 85.4% at depth 1, 100.0% at depth 2 — measured 2026-10-06, installed on this Mac
        "com.apple.dictionary.or-en.oup": DictionaryProfile(
            identifier: "com.apple.dictionary.or-en.oup", senseDepth: 2),
        // 50.9% at depth 1, 100.0% at depth 2 — measured 2026-10-06, installed on this Mac
        "com.apple.dictionary.sa-en.oup": DictionaryProfile(
            identifier: "com.apple.dictionary.sa-en.oup", senseDepth: 2),
    ]

    /// `class` split into whole tokens. One place, because `class` is a space-separated list and every
    /// predicate in this module must agree on what a token is: substring matching reads `x_xd1sub` as a
    /// sense and `tg_df` as a definition.
    static func tokens(_ classAttribute: String?) -> [String] {
        guard let classAttribute else { return [] }
        return classAttribute.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether a class token list opens a part-of-speech block.
    ///
    /// `x_xd0` is the part-of-speech block in every dictionary measured, independently of `senseDepth`.
    /// Whole-token, for the same reason `marksSense` is: `class` is a space-separated list, and `x_xd0`
    /// appears alongside `posg`, `se2` and others.
    public func marksPartOfSpeechBlock(classAttribute: String?) -> Bool {
        marksPartOfSpeechBlock(classes: Self.tokens(classAttribute))
    }

    /// The same question of an already-split token list. The tree walk asks every predicate here once per
    /// node, and re-splitting the `class` string each time was the only cost of asking.
    public func marksPartOfSpeechBlock(classes: [String]) -> Bool {
        classes.contains("x_xd0")
    }

    /// Whether a class token names a sense at this dictionary's depth — `x_xd<senseDepth>` and nothing
    /// else. `x_xd1sub` is excluded because `Int("1sub")` is nil, so subsenses fall out by
    /// construction rather than by a special case.
    public func isSenseClass(_ token: some StringProtocol) -> Bool {
        // **Compared as a string, not parsed as a number.** `Int("01") == 1` and `Int("+1") == 1`, so
        // `x_xd01` and `x_xd+1` matched depth 1 — distinct class names opening a sense region. Comparing
        // against the one token that means this depth cannot admit a variant spelling.
        token == "x_xd\(senseDepth)"
    }

    /// Whether a `class` attribute lists this dictionary's sense token. Matched as a whole token: the
    /// attribute is a space-separated list, `class="se2 x_xd1 hasSn"`, and substring matching reads
    /// `x_xd1sub` as a sense.
    public func marksSense(classAttribute: String?) -> Bool {
        marksSense(classes: Self.tokens(classAttribute))
    }

    public func marksSense(classes: [String]) -> Bool {
        classes.contains(where: isSenseClass)
    }

    /// Whether a `class` attribute marks a definition.
    ///
    /// **`d:def` is not how a definition is marked; it is how *some* definitions are marked.** Classifying
    /// every `class="df"` element in NOAD by ancestry: 142,031 carry `d:def` (71.8%), 23,494 sit under
    /// `x_xd*` without it (11.9%), 19,580 under `x_xdNsub` (9.9%), 12,610 under a sub-entry (6.4%), and 46
    /// under none. Reading only the attribute reached 74.6% of them.
    ///
    /// **A union with `d:def`, never a replacement for it.** Three of the nine dictionaries on this Mac —
    /// the Oxford thesaurus, 뉴에이스 영한사전 and 牛津英汉汉英 — carry **no `class="df"` at all** and mark
    /// every definition with the attribute alone. Swapping one test for the other would have taken them
    /// from every definition to none.
    ///
    /// Whole-token, like `marksSense`: `class="gp tg_df"` is guide punctuation, not a definition, and
    /// substring matching reads it as one.
    public func marksDefinition(classAttribute: String?) -> Bool {
        marksDefinition(classes: Self.tokens(classAttribute))
    }

    public func marksDefinition(classes: [String]) -> Bool {
        classes.contains("df")
    }

    /// Whether a `class` attribute opens a sub-entry — a phrasal verb, idiom or derivative carrying its
    /// own label and its own senses.
    ///
    /// **`x_xo<N>` for N ≥ 1, and the 0 is excluded deliberately.** `x_xo0` is the *block* that wraps
    /// several sub-entries — `class="subEntryBlock x_xo0 t_derivatives"` holds `abjection`, `abjectly` and
    /// `abjectness` as three `x_xo1` siblings — so opening a region at `x_xo0` would merge them into one
    /// sense. `x_xo0` is also what NOAD labels its etymology with, which is not a sub-entry at all; that
    /// block carries no definition-marked element, so the definition predicate is what keeps its prose out
    /// rather than a special case here.
    ///
    /// Deeper tokens are not tested separately because a region opens only when none is already open:
    /// `x_xo2` and `x_xo3` sit inside `x_xo1` and belong to the sub-entry it opened.
    public func marksSubEntry(classAttribute: String?) -> Bool {
        marksSubEntry(classes: Self.tokens(classAttribute))
    }

    /// The `x_xo` depth this class list opens, or nil if it opens no sub-entry.
    ///
    /// Needed because a sub-entry's *senses* sit one level below it — `x_xo1` the phrasal verb, `x_xo2` each
    /// of its numbered senses — so reading them means knowing which level the sub-entry itself was at.
    public func subEntryDepth(classes: [String]) -> Int? {
        for token in classes where token.hasPrefix("x_xo") {
            let suffix = token.dropFirst(4)
            guard let first = suffix.first, first != "0",
                  suffix.count <= 2, suffix.allSatisfy(\.isASCII), suffix.allSatisfy(\.isNumber),
                  let depth = Int(suffix), depth <= maximumMarkupDepth else { continue }
            return depth
        }
        return nil
    }

    /// The deepest `x_xo`/`x_xd` level this module will read.
    ///
    /// **Bounded because the number comes out of a file.** `x_xo9223372036854775807` parsed to `Int.max`,
    /// and the indexer's `depth + 1` then trapped on overflow — a crash from markup. The deepest level
    /// measured anywhere in the catalogue is 5 (`zh_CN-en.OCD`), so 16 refuses the pathological case without
    /// coming near a real one.
    public static let maximumMarkupDepth = 16
    var maximumMarkupDepth: Int { Self.maximumMarkupDepth }

    /// **Defined as `subEntryDepth != nil`, because two copies of one rule disagreed.** `marksSubEntry`
    /// accepted `x_xo9223372036854775808` while `subEntryDepth` returned nil for it, so the main-sense walk
    /// treated that subtree as a sub-entry boundary and excluded it while nothing ever read it as one — the
    /// definitions inside were reachable by neither path.
    public func marksSubEntry(classes: [String]) -> Bool {
        subEntryDepth(classes: classes) != nil
    }

    /// Whether a `class` attribute marks a sub-entry's own label — `x_xoh`, or the `l` span inside it.
    ///
    /// `l` is preferred where both appear: NOAD writes `<span class="x_xoh"><span class="l">abjection
    /// </span><span class="prx"> | əbˈdʒɛkʃən | </span>…</span>`, so the `x_xoh` block's text carries the
    /// pronunciation and the part of speech while `l` carries the label alone.
    public func marksSubEntryLabel(classAttribute: String?) -> (matches: Bool, isPreferred: Bool) {
        guard let classAttribute else { return (false, false) }
        let tokens = classAttribute.split(whereSeparator: \.isWhitespace)
        if tokens.contains("l") { return (true, true) }
        return (tokens.contains("x_xoh"), false)
    }
}
