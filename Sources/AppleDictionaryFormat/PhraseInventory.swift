import Foundation

/// Every phrase one dictionary knows, **and what each one means**.
///
/// **The artefact the phrase feature actually needs, and it is small.** Measured 2026-09-29 over the three
/// dictionaries that serve a Simplified reader: **103,517 phrases, 9,740 of them explained, 2,636 KB across
/// three files**, read cold in 20.7 s and from the store in 0.5 s. (2,080 KB while a phrase kept one
/// unattributed definition; keeping every definition and both locators costs 556 KB.) For comparison the full index is 319 MB and
/// minutes, and `EntryIndexer` over the same bodies costs **109 s for NOAD alone** — 102 of those seconds
/// spent on sense keys, content hashes and ordinals that a phrase list has no use for. Reading the phrases
/// with the indexer because the indexer was already written is what made this look expensive.
///
/// Two things follow from being cheap. The phrase feature stops depending on the index — which a reader may
/// not have, and which refuses a schema it does not know — and it stops needing `EntryDocument` to learn
/// sub-entries, so nothing on the sense-keying path moves.
///
/// **Never distributed.** Derived from dictionaries Apple licensed to one Mac, kept on that Mac. The same
/// rule as the index, for the same reason.
/// One sub-entry block: **where it is filed, and every definition it holds.**
///
/// A phrase is filed inside another word's entry — `take something into account` inside `account` — and the
/// block carries its own publisher id. Measured 2026-09-29, **9,762 of NOAD's 9,762** sub-entry blocks have
/// one, so this is the dictionary's own name for the filing rather than a locator this project invented.
///
/// **Both plurals are load-bearing.** A block holds several definitions where the publisher numbers the
/// phrase's senses — `give up` has five — and a phrase is filed under more than one parent where it means
/// different things in each: NOAD does it 18 times, 牛津粵英雙語詞典 70 times in 647 phrases. Keeping only
/// the first of either is what this type exists to stop, and it is not a locator for a *study item*: an
/// occurrence is where a definition was found, not a durable name for a sense.
public struct PhraseExplanation: Sendable, Equatable {
    /// The entry document this block sits in — `account`'s id for `take something into account`.
    public let parentEntryID: String
    /// The block's own publisher id, empty where the dictionary marks none.
    public let blockID: String
    /// Every definition in the block, in document order. Never empty: a block with none is not an
    /// explanation and is dropped at the walk.
    public let definitions: [String]

    public init(parentEntryID: String, blockID: String, definitions: [String]) {
        self.parentEntryID = parentEntryID
        self.blockID = blockID
        self.definitions = definitions
    }
}

public struct PhraseInventory: Sendable, Equatable {
    /// Which build of which dictionary this was read from — `DictionaryBundle.contentVersion()`. Apple
    /// re-masters these, so a stored inventory is only valid for the bytes it came from.
    public let contentVersion: String

    /// Phrase to **every** way this dictionary files and explains it, the phrase lowercased as it files it.
    ///
    /// *kick the bucket → die*, *take something into account → consider something along with other factors
    /// before reaching a decision*. This is the half the live sense path cannot reach at all:
    /// `EntryDocument` walks `x_xd0`/`x_xd1` and a sub-entry is `x_xo<N>`, so *account*'s 16 sub-entries and
    /// 32 definitions yield 6 senses and none of them is this.
    ///
    /// **A list, because one string was a silent choice.** Until 2026-09-29 this was `[String: String]`
    /// holding the first definition of the first block walked, and the losers were dropped: **2,832
    /// definitions in NOAD** beyond each block's first, plus 18 phrases filed under a second parent. The
    /// order is document order, and choosing between them belongs to whoever can see the reader's sentence.
    public let explanations: [String: [PhraseExplanation]]

    /// **Every multi-word phrase, whether or not this dictionary explains one.** The search keys come from
    /// `KeyText.data` and carry spellings without definitions, so `phrases` is a superset of
    /// `explanations.keys` — **103,517 against 9,740** for the three dictionaries serving a Simplified
    /// reader, re-measured 2026-09-29. An earlier `116,122 against 9,743` is from before `serves(reader:)`
    /// scoped the set and is not this measurement; the two were quoted side by side for a week.
    ///
    /// Stored rather than re-read. Decompressing the key indexes costs **2.24 s** every launch and reading
    /// them back from here costs **0.08 s**: the bytes were already walked once to compute
    /// `contentVersion`, so re-deriving them is work with a known answer.
    public let phrases: Set<String>

    public init(contentVersion: String, phrases: Set<String>,
                explanations: [String: [PhraseExplanation]]) {
        self.contentVersion = contentVersion
        self.phrases = phrases
        self.explanations = explanations
    }

    /// Reads one dictionary's phrases from its body.
    ///
    /// **A narrow scan, not `EntryIndexer`.** It needs two class tokens and nothing else, and 86% of entries
    /// are skipped on a substring test before any of it runs — only 16,099 of NOAD's 111,606 entries hold a
    /// sub-entry at all.
    public static func read(_ bundle: DictionaryBundle) throws -> PhraseInventory {
        var explanations: [String: [PhraseExplanation]] = [:]
        // The cheap half first: a dictionary whose key index cannot be read is not worth walking the body of.
        var phrases = try PhraseSpans.keys(in: bundle.url)
        try ContainerReader.forEachEntry(in: bundle.url) { xhtml in
            Self.accumulate(xhtml, into: &explanations, phrases: &phrases)
        }
        return PhraseInventory(contentVersion: bundle.contentVersion(),
                              phrases: phrases, explanations: explanations)
    }

    /// One entry's contribution, appended rather than merged.
    ///
    /// **Its own function so the accumulation can be tested without a dictionary.** The rule it carries is
    /// one line long and was wrong for the life of the type: `where explanations[phrase] == nil` kept the
    /// first filing and discarded every later one, and a body walk has no basis for preferring the entry it
    /// happened to reach first.
    static func accumulate(_ xhtml: String, into explanations: inout [String: [PhraseExplanation]],
                           phrases: inout Set<String>) {
        // The prefilter, and it is where the time goes. Without it every entry is scanned for a structure
        // five sixths of them do not have — only 16,099 of NOAD's 111,606 hold a sub-entry. The class name
        // is what the walk looks for, so this is the same question asked cheaply first.
        guard xhtml.contains(Self.labelClass) else { return }
        for (phrase, explanation) in Self.subEntries(in: xhtml) {
            explanations[phrase, default: []].append(explanation)
            phrases.insert(phrase)
        }
    }

    // MARK: - On disk

    /// **Tab-separated lines, not JSON.** This is a cache of 1.7 MB of strings read on every launch, and the
    /// shape is a flat list: `String(contentsOf:)` plus a split reads it in **0.08 s** where decoding the
    /// same content as JSON is several times that for no benefit a derived file needs.
    ///
    /// **Two sections, each with its own count in the header.** Line one is the format's version, the
    /// dictionary's `contentVersion`, the number of phrase lines and the number of explanation lines. Then
    /// that many bare phrases — most of them, from the key index, which no dictionary explains — and then
    /// that many explanations: `phrase`, parent id, block id, and one field per definition. A phrase filed
    /// twice has two lines. One count could only ever guard the section it counted.
    /// **Bump this whenever the extraction changes, not only when the file's shape does.**
    ///
    /// `contentVersion` says whether the *dictionary* changed; it cannot say whether this code did. Lowercasing
    /// the search keys made every stored inventory wrong and nothing noticed — the bytes had not moved, so the
    /// cache stayed current and 8,046 phrases went on being unreachable with the fix already in the binary.
    /// That is the same failure the index's `user_version` exists for, one level up.
    ///
    /// **It has already been forgotten once, in the session that wrote the rule.** Extraction changed twice
    /// — bounding the definition, then reading the label from its own text span — and this was bumped once,
    /// so a file written by the broken intermediate was accepted as current and `kick the bucket` reached the
    /// wire with no meaning. What caught it was not this comment but
    /// `PhraseCandidateTests.everyPhraseIsClassifiedByWhoseEntryAnsweredIt`, which names four phrases and
    /// asserts each arrives explained. A version a person must remember to bump needs an assertion that does
    /// not; that test is it.
    /// `phrases/6`: a phrase now carries every filing and every definition in each, with the parent and
    /// block ids the walk had been throwing away. Every stored `phrases/5` file holds one arbitrary
    /// definition per phrase and must be rebuilt, which is what this bump is for.
    static let formatVersion = "phrases/6"

    public func encoded() -> String {
        // **A phrase carrying a tab or a newline is skipped, not escaped.** It would split into two fields
        // or two lines and come back as a phrase nothing matches; no key measured contains one, and an
        // escape scheme for a case that does not arise is a parser nobody has tested.
        let writable = phrases.sorted().filter { !$0.contains("\t") && !$0.contains("\n") }
        let filed = Set(writable)
        // Sorted so the file is deterministic: the same dictionary read twice must produce the same bytes,
        // or a cache comparison turns into a diff of dictionary iteration order.
        var explained: [(String, PhraseExplanation)] = []
        for (phrase, found) in explanations where filed.contains(phrase) {
            for explanation in found { explained.append((phrase, explanation)) }
        }
        explained.sort { ($0.0, $0.1.blockID, $0.1.parentEntryID) < ($1.0, $1.1.blockID, $1.1.parentEntryID) }

        var lines = ["\(Self.formatVersion)\t\(contentVersion)\t\(writable.count)\t\(explained.count)"]
        lines.reserveCapacity(writable.count + explained.count + 1)
        lines.append(contentsOf: writable)
        for (phrase, explanation) in explained {
            // A tab inside a definition would arrive as an extra definition the dictionary never wrote;
            // a newline as a line nothing can parse. Both are flattened rather than escaped, for the
            // reason above.
            let fields = [phrase, Self.flattened(explanation.parentEntryID),
                          Self.flattened(explanation.blockID)]
                + explanation.definitions.map(Self.flattened)
            lines.append(fields.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    private static func flattened(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// Nil where this is not an inventory of a version this build reads — **refused, never guessed at**, for
    /// the same reason the index refuses an unknown schema: a half-understood cache is worse than none.
    public init?(decoding text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.first else { return nil }
        let fields = header.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == Self.formatVersion,
              let declaredPhrases = Int(fields[2]), let declaredExplanations = Int(fields[3]),
              declaredPhrases >= 0, declaredExplanations >= 0 else { return nil }
        lines.removeFirst()
        // **Short of what the header promised means the file was cut.** Both sections are counted, so a
        // whole phrase list followed by half the explanations is refused rather than read as current.
        guard lines.count >= declaredPhrases + declaredExplanations else { return nil }

        var phrases = Set<String>()
        phrases.reserveCapacity(declaredPhrases)
        for line in lines.prefix(declaredPhrases) {
            guard !line.isEmpty else { return nil }
            phrases.insert(String(line))
        }
        var explanations: [String: [PhraseExplanation]] = [:]
        for line in lines.dropFirst(declaredPhrases).prefix(declaredExplanations) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            // Phrase, parent, block, and at least one definition.
            guard parts.count >= 4, !parts[0].isEmpty else { return nil }
            let definitions = Array(parts.dropFirst(3)).filter { !$0.isEmpty }
            guard !definitions.isEmpty else { return nil }
            explanations[parts[0], default: []].append(
                PhraseExplanation(parentEntryID: parts[1], blockID: parts[2], definitions: definitions))
        }
        guard phrases.count == declaredPhrases else { return nil }
        self.init(contentVersion: String(fields[1]), phrases: phrases, explanations: explanations)
    }

    /// The sub-entry block, its label's text span, and its definition — by class.
    ///
    /// **`x_xoh` is the label and `l` is its text.** Some labels put both classes on the text span;
    /// others make `x_xoh` a wrapper holding the text *and the pronunciation*, so the text is always the
    /// `l` span where there is one.
    static let blockClass = "subEntry"
    static let labelClass = "x_xoh"
    static let labelTextClass = "l"
    static let definitionClass = "df"

    /// One entry's sub-entries: the label, where the block is filed, and **every** definition inside it.
    ///
    /// **Parsed, not scanned.** Three rounds of audit found three holes in a hand-rolled scan of this
    /// markup — a definition bleeding in from the next sub-entry, a nested span truncating the text, a
    /// self-closing `<span/>` swallowing the block — and each patch exposed the next: a `>` inside an
    /// attribute value, a class name matched inside `title=`, `data_class` read as `class`. That is a
    /// scanner re-deriving XML one defect at a time. `EntryTree` is the module's own `XMLParser` walk; it
    /// knows elements from attributes, decodes character references, and has tests of its own.
    ///
    /// Multi-word labels only. A one-word sub-entry is a derived form — *bucketful* under *bucket* — not a
    /// phrase a reader meets mid-sentence and fails to notice.
    static func subEntries(in xhtml: String) -> [(phrase: String, explanation: PhraseExplanation)] {
        guard let tree = EntryTree.parse(xhtml) else { return [] }
        let parent = tree.entryID() ?? ""
        var found: [(phrase: String, explanation: PhraseExplanation)] = []
        // Maximal blocks: a sub-entry nested inside another is reached through its parent, and taking both
        // would attribute the inner one's definition twice.
        for block in tree.root.maximalDescendants(where: { $0.classes.contains(blockClass) }) {
            guard let label = block.firstDescendant(where: { $0.classes.contains(labelClass) }) else { continue }
            let text = collapsed(
                label.firstDescendant(where: { $0.classes.contains(labelTextClass) })?.text ?? label.text)
            guard PhraseSpans.isMultiWord(text) else { continue }
            // **Inside this block only.** Searching past it gave a sub-entry with no definition of its own
            // the *following* one's — the wrong meaning under the right words.
            //
            // **Maximal, and all of them.** `firstDescendant` took one definition of however many the
            // publisher numbered: 1,698 of NOAD's blocks hold more, and 2,832 definitions were dropped
            // there. Maximal because a definition nested inside another is that one's text already.
            let definitions = block
                .maximalDescendants(where: { $0.classes.contains(definitionClass) })
                .map { collapsed($0.text) }
                .filter { !$0.isEmpty }
            guard !definitions.isEmpty else { continue }
            found.append((text.lowercased(),
                          PhraseExplanation(parentEntryID: parent,
                                            blockID: block.attributes["id"] ?? "",
                                            definitions: definitions)))
        }
        return found
    }

    /// Whitespace collapsed to one space and trimmed. A label arrives as `take something into account `
    /// with a trailing space, and a key with one is a key nothing matches.
    ///
    /// No tag stripping: `EntryNode.text` is text, and character references are already decoded by the
    /// parser — which is also why `one&apos;s` needs no special handling here.
    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
