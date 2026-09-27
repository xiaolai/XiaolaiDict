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
    /// 3. **Retention**: indexing at this depth, what share of the `d:def` elements the markup declares
    ///    survive into a sense? That is the question, because losing them is the actual harm. Measured
    ///    through `EntryIndexer` itself — Vietnamese kept **23%** at depth 1 and 103% at depth 2; Greek
    ///    48% against 100% at depth 3.
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
    /// Odia and Sanskrit nest deeply too but did not clear the margin the test requires, so they are
    /// absent — a dictionary belongs here on evidence, not on resemblance to one that does.
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
    ]

    /// Whether a class token names a sense at this dictionary's depth — `x_xd<senseDepth>` and nothing
    /// else. `x_xd1sub` is excluded because `Int("1sub")` is nil, so subsenses fall out by
    /// construction rather than by a special case.
    public func isSenseClass(_ token: some StringProtocol) -> Bool {
        guard token.hasPrefix("x_xd"), let depth = Int(token.dropFirst(4)) else { return false }
        return depth == senseDepth
    }

    /// Whether a `class` attribute lists this dictionary's sense token. Matched as a whole token: the
    /// attribute is a space-separated list, `class="se2 x_xd1 hasSn"`, and substring matching reads
    /// `x_xd1sub` as a sense.
    public func marksSense(classAttribute: String?) -> Bool {
        guard let classAttribute else { return false }
        return classAttribute.split(whereSeparator: \.isWhitespace).contains(where: isSenseClass)
    }
}
