import Foundation

/// Every inflected form one dictionary **prints**, and the headword it is printed under.
///
/// **The publisher's own list, read where it is written.** An Oxford entry carries its inflections in the
/// part-of-speech block: `break` (verb) prints `<span class="infg"><span class="sy">past</span> <span
/// class="inf">broke</span></span>` and the same again for `broken`. That is a statement by the dictionary
/// that *broke* is a form of *break*, which is the one thing a lemmatiser has to know and `NLTagger` gets
/// wrong or declines to answer for the irregular ones — ADR-0002, ADR-0051.
///
/// **Not the key index, which is a different and larger list.** `KeyText.data` also files `blitzers`,
/// `enjoyer` and `learnable` under their root word, because a reader who types one should land on that
/// entry. Those are *run-ons* — derived words printed at the foot of an entry — and filing is not
/// inflection: taking `enjoyer → enjoy` as a lemma would merge two words. Measured 2026-10-06 over the four
/// English monolinguals: 68,043 single-word forms pair up that way, against ~14 k printed, and in a sample of
/// the pairs where the tagger and the index disagreed, about half were the tagger being right about the word
/// (`blitzers → blitzer`) and the index being right about the filing (`→ blitz`). The printed list has no
/// second reading.
///
/// **Never distributed.** Derived from dictionaries Apple licensed to one Mac and kept on that Mac, like
/// the phrase inventory and the index.
public struct InflectionInventory: Sendable, Equatable {
    /// One reading of a form: the headword it inflects, and the word class of the block it was printed in.
    public struct Reading: Sendable, Hashable, Comparable {
        public let lemma: String
        /// `verb`, `noun`, `adjective` or `adverb` — the vocabulary `Lemmatizer.partOfSpeech` reports, so the
        /// two compare without a table — or empty where the block's label says none of them. **Empty is
        /// unknown, never "any"**: a caller that wants to filter by class treats it as compatible with all.
        public let partOfSpeech: String

        public init(lemma: String, partOfSpeech: String) {
            self.lemma = lemma
            self.partOfSpeech = partOfSpeech
        }

        public static func < (lhs: Reading, rhs: Reading) -> Bool {
            (lhs.lemma, lhs.partOfSpeech) < (rhs.lemma, rhs.partOfSpeech)
        }
    }

    /// **Bump this whenever the extraction changes, not only the stored shape** — the same rule, for the same
    /// reason, as `PhraseInventory.formatVersion`: `contentVersion` says whether the dictionary changed and
    /// cannot say whether this code did. A stored table built by an older extraction would be accepted as
    /// current for ever. `FormTableReader` writes it into the table's sources, so moving it rebuilds.
    public static let formatVersion = "inflections/2"

    /// Which build of which dictionary this was read from — `DictionaryBundle.contentVersion()`.
    public let contentVersion: String

    /// Form to every reading of it, the form lowercased as printed. A form printed under two headwords
    /// (`found` is the past of *find* and a verb in its own right) has both.
    public let forms: [String: Set<Reading>]

    /// The forms that are **also headwords of their own**, restricted to the forms printed here.
    ///
    /// *saw*, *found*, *felt*, *ground*, *left*: each is the inflection of one word and the base form of
    /// another, so what a reader meant is decided by the sentence and never by this list. Without the flag
    /// a lemmatiser that sees `found` listed as a form of *find* would resolve it, and *they will found a
    /// company* would be filed under *find*. Read from the key index, whose headword groups say it exactly.
    public let ownHeadwords: Set<String>

    /// **Every one-word, alphabetic entry title** — the dictionary's own word list, lowercased. What a regular
    /// inflection the dictionary does not print is checked against: `abuelas` is not printed, and is the plural of
    /// a title. ~100 k words for NOAD, which is most of what this inventory weighs.
    public let headwords: Set<String>

    public init(contentVersion: String, forms: [String: Set<Reading>], ownHeadwords: Set<String>,
                headwords: Set<String> = []) {
        self.contentVersion = contentVersion
        self.forms = forms
        self.ownHeadwords = ownHeadwords
        self.headwords = headwords
    }

    /// Reads one dictionary in a single body walk: the printed forms, and every entry's title so the forms
    /// that are also headwords can be told.
    ///
    /// **86% of entries are skipped on a substring test** before anything is parsed, the same prefilter the
    /// phrase inventory uses; what is left goes through `EntryTree`. The titles come from each opening tag
    /// alone (`EntryTree.title(of:)`), which is what lets the walk see every entry without building a tree for
    /// any but the 8% that print an inflection.
    ///
    /// **`contentVersion` is the caller's where it has one**: hashing both files of a 100 MB dictionary is not free,
    /// and `FormTableReader` has just done it to decide whether to read at all. Hashed here only when nobody
    /// supplied it. The version is taken before the walk, which is the safe side: a dictionary replaced during it
    /// leaves the stored sources behind the new build's, and the next launch rebuilds.
    public static func read(_ bundle: DictionaryBundle, contentVersion: String? = nil) throws -> InflectionInventory {
        var forms: [String: Set<Reading>] = [:]
        var titles = Set<String>()
        try ContainerReader.forEachEntry(in: bundle.url) { xhtml in
            // An entry that printed inflections has been parsed and named already; the others are named from
            // their opening tag, and only a record with no `d:title` is parsed to find its headword block.
            switch accumulate(xhtml, into: &forms) {
            case .named(let named):
                if !named.isEmpty { titles.insert(named) }
                return
            case .unread: break
            }
            if let title = EntryTree.title(of: xhtml).map(normalised), !title.isEmpty {
                titles.insert(title)
            } else if let tree = EntryTree.parse(xhtml) {
                let named = lemma(of: tree)
                if !named.isEmpty { titles.insert(named) }
            }
        }
        return InflectionInventory(contentVersion: contentVersion ?? bundle.contentVersion(), forms: forms,
                                   ownHeadwords: Set(forms.keys).intersection(titles),
                                   headwords: titles.filter(isWord))
    }

    // MARK: - One entry

    static let groupClass = "infg"
    static let formClass = "inf"
    static let partOfSpeechBlockClass = "x_xd0"
    static let partOfSpeechLabelClass = "pos"
    /// A sub-entry (`give up` filed under *give*) holds inflections of **its own label**, which is a phrase;
    /// attributing them to the parent's headword would file *gave up* under *give*.
    static let subEntryClass = "subEntry"

    /// One entry's contribution, merged into `forms`.
    ///
    /// **Its own function so the rule can be tested without a dictionary** — the real markup is licensed and
    /// never vendored here.
    ///
    /// Returns the headword the entry is filed under **when it had to be parsed to find out**, so the caller does not
    /// parse it a second time for its title; `unread` where the record was skipped.
    @discardableResult
    static func accumulate(_ xhtml: String, into forms: inout [String: Set<Reading>]) -> Named {
        guard xhtml.contains(groupClass) else { return .unread }
        guard let tree = EntryTree.parse(xhtml) else { return .unread }
        let lemma = Self.lemma(of: tree)
        guard Self.isHeadword(lemma) else { return .named("") }
        let isSubEntry: (EntryNode) -> Bool = { Self.marksSubEntry($0) }

        // Inside a part-of-speech block, so the form carries the class it was printed under.
        for block in tree.root.maximalDescendants(
            where: { $0.classes.contains(partOfSpeechBlockClass) }, stoppingAt: isSubEntry) {
            let label = block.firstDescendant(
                where: { $0.classes.contains(partOfSpeechLabelClass) }, stoppingAt: isSubEntry)
            let partOfSpeech = Self.partOfSpeech(from: label?.text ?? "")
            for group in block.maximalDescendants(
                where: { $0.classes.contains(groupClass) }, stoppingAt: isSubEntry) {
                add(group, of: lemma, partOfSpeech, to: &forms)
            }
        }
        // And any group printed outside every block — an entry with no part-of-speech structure — with no
        // class: nothing says which one it belongs to.
        for group in tree.root.maximalDescendants(
            where: { $0.classes.contains(groupClass) },
            stoppingAt: { isSubEntry($0) || $0.classes.contains(partOfSpeechBlockClass) }) {
            add(group, of: lemma, "", to: &forms)
        }
        return .named(lemma)
    }

    /// Whether `accumulate` parsed the record, and what it was named. **`named("")` is a record that was parsed and
    /// has no usable headword** — told apart from `unread` so the caller does not parse it a second time to find
    /// out what is already known.
    enum Named: Equatable {
        case unread
        case named(String)
    }

    /// A sub-entry by Oxford's `subEntry` class **or** by the `x_xo<N>` depth every dictionary's profile knows —
    /// one that carries only the second leaked its inflections into the parent.
    private static let defaultProfile = DictionaryProfile(identifier: "")
    static func marksSubEntry(_ node: EntryNode) -> Bool {
        node.classes.contains(subEntryClass) || defaultProfile.marksSubEntry(classes: node.classes)
    }

    private static func add(_ group: EntryNode, of lemma: String, _ partOfSpeech: String,
                            to forms: inout [String: Set<Reading>]) {
        for node in group.maximalDescendants(where: { $0.classes.contains(formClass) }) {
            let form = normalised(node.text(excluding: Walk.isNotPartOfAName))
            // **One alphabetic word, and not the headword restated.** A lemmatiser is handed a word at a time,
            // so a form with a space (`abominable snowmen`), a hyphen (`mothers-in-law`), an apostrophe
            // (`cc'd`), a full stop (`mfrs.`) or a placeholder (`@ed`, from an entry that describes the
            // suffix) is never asked for: 496 of Oxford's 15,143 printed forms, measured 2026-10-06.
            guard isWord(form), form != lemma else { continue }
            forms[form, default: []].insert(Reading(lemma: lemma, partOfSpeech: partOfSpeech))
        }
    }

    /// The headword the entry is filed under: Apple's own `d:title`, then the headword block.
    ///
    /// `d:title` first because it is the publisher's statement of the entry's name and costs nothing; the
    /// block is what a record without one still has.
    static func lemma(of tree: EntryTree) -> String {
        if let title = tree.dictionaryAttribute("title", of: tree.root), !collapsed(title).isEmpty {
            return normalised(title)
        }
        return normalised(Walk(tree: tree, profile: DictionaryProfile(identifier: "")).headword())
    }

    /// `verb`, `noun`, `adjective`, `adverb` from a block's label, or empty. **By whole word**: `phrasal verb`
    /// is a verb and `pronoun` is not a noun, which is the project's rule for every part-of-speech label.
    static func partOfSpeech(from label: String) -> String {
        let words = Set(label.lowercased().split { !$0.isLetter }.map(String.init))
        for candidate in ["verb", "noun", "adjective", "adverb"] where words.contains(candidate) {
            return candidate
        }
        return ""
    }

    /// A headword a form can be filed under: letters, with the spaces, hyphens and apostrophes a phrase or a
    /// compound has — and not `@`, the placeholder a suffix entry (`-ed`) is titled with.
    static func isHeadword(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isAlphabetic }
            && text.unicodeScalars.allSatisfy { $0.properties.isAlphabetic || " -'".unicodeScalars.contains($0) }
    }

    /// Letters only — every script, since `chassés` and `aperçus` are printed.
    static func isWord(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.properties.isAlphabetic }
    }

    /// Collapsed, lowercased and **composed (NFC)**: `chassés` written with a combining accent is the same word as
    /// the precomposed one, and the letter test below sees scalars — it would refuse the first and keep the second.
    static func normalised(_ text: String) -> String {
        collapsed(text).lowercased().precomposedStringWithCanonicalMapping
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
