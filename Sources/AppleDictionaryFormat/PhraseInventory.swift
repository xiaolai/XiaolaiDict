import Foundation

/// Every phrase one dictionary knows, **and what each one means**.
///
/// **The artefact the phrase feature actually needs, and it is small.** Measured 2026-09-29 over the three
/// dictionaries that serve a Simplified reader: **103,517 phrases, 9,740 of them explained, 2,080 KB across
/// three files**, read cold in 19 s and from the store in 0.5 s. For comparison the full index is 319 MB and
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
public struct PhraseInventory: Sendable, Equatable {
    /// Which build of which dictionary this was read from — `DictionaryBundle.contentVersion()`. Apple
    /// re-masters these, so a stored inventory is only valid for the bytes it came from.
    public let contentVersion: String

    /// Phrase to its meaning, the phrase lowercased as a dictionary files it.
    ///
    /// The meaning is the sub-entry's own first definition — *kick the bucket → die*, *take something into
    /// account → consider something along with other factors before reaching a decision*. This is the half
    /// the live sense path cannot reach at all: `EntryDocument` walks `x_xd0`/`x_xd1` and a sub-entry is
    /// `x_xo<N>`, so *account*'s 16 sub-entries and 32 definitions yield 6 senses and none of them is this.
    public let meanings: [String: String]

    /// **Every multi-word phrase, whether or not this dictionary explains one.** The search keys come from
    /// `KeyText.data` and carry spellings without definitions, so `phrases` is a superset of
    /// `meanings.keys` — 116,122 against 9,743, measured over three dictionaries.
    ///
    /// Stored rather than re-read. Decompressing the key indexes costs **2.24 s** every launch and reading
    /// them back from here costs **0.08 s**: the bytes were already walked once to compute
    /// `contentVersion`, so re-deriving them is work with a known answer.
    public let phrases: Set<String>

    public init(contentVersion: String, phrases: Set<String>, meanings: [String: String]) {
        self.contentVersion = contentVersion
        self.phrases = phrases
        self.meanings = meanings
    }

    /// Reads one dictionary's phrases from its body.
    ///
    /// **A narrow scan, not `EntryIndexer`.** It needs two class tokens and nothing else, and 86% of entries
    /// are skipped on a substring test before any of it runs — only 16,099 of NOAD's 111,606 entries hold a
    /// sub-entry at all.
    public static func read(_ bundle: DictionaryBundle) throws -> PhraseInventory {
        var meanings: [String: String] = [:]
        // The cheap half first: a dictionary whose key index cannot be read is not worth walking the body of.
        var phrases = try PhraseSpans.keys(in: bundle.url)
        try ContainerReader.forEachEntry(in: bundle.url) { xhtml in
            // The prefilter, and it is where the time goes. Without it every entry is scanned for a
            // structure five sixths of them do not have.
            // Parsing costs more than a substring test, and five sixths of entries hold no sub-entry at all —
            // only 16,099 of NOAD's 111,606. The class name is what the walk looks for, so this is the same
            // question asked cheaply first.
            guard xhtml.contains(Self.labelClass) else { return }
            for (phrase, meaning) in Self.subEntries(in: xhtml) where meanings[phrase] == nil {
                meanings[phrase] = meaning
                phrases.insert(phrase)
            }
        }
        return PhraseInventory(contentVersion: bundle.contentVersion(),
                              phrases: phrases, meanings: meanings)
    }

    // MARK: - On disk

    /// **Tab-separated lines, not JSON.** This is a cache of 1.7 MB of strings read on every launch, and the
    /// shape is a flat list: `String(contentsOf:)` plus a split reads it in **0.08 s** where decoding the
    /// same content as JSON is several times that for no benefit a derived file needs.
    ///
    /// Line one is the format's own version and the dictionary's `contentVersion`; every line after it is a
    /// phrase and its meaning, the meaning empty for a phrase from the key index.
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
    static let formatVersion = "phrases/5"

    public func encoded() -> String {
        // **The row count is in the header, so a truncated file is refused rather than read short.**
        // Validating only the header accepted a valid line followed by half the data, and `contentVersion`
        // then matched — so an inventory missing most of its phrases was treated as current for ever.
        let writable = phrases.sorted().filter { !$0.contains("\t") && !$0.contains("\n") }
        var lines = ["\(Self.formatVersion)\t\(contentVersion)\t\(writable.count)"]
        lines.reserveCapacity(writable.count + 1)
        for phrase in writable {
            // **A phrase carrying a tab or a newline is skipped, not escaped.** It would split into two
            // fields or two lines and come back as a phrase nothing matches; no key measured contains one,
            // and an escape scheme for a case that does not arise is a parser nobody has tested.
            guard !phrase.contains("\t"), !phrase.contains("\n") else { continue }
            let meaning = meanings[phrase] ?? ""
            lines.append("\(phrase)\t\(meaning.replacingOccurrences(of: "\n", with: " "))")
        }
        return lines.joined(separator: "\n")
    }

    /// Nil where this is not an inventory of a version this build reads — **refused, never guessed at**, for
    /// the same reason the index refuses an unknown schema: a half-understood cache is worse than none.
    public init?(decoding text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let header = lines.first else { return nil }
        let fields = header.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == Self.formatVersion,
              let declared = Int(fields[2]) else { return nil }
        lines.removeFirst()
        var phrases = Set<String>()
        var meanings: [String: String] = [:]
        phrases.reserveCapacity(lines.count)
        for line in lines where !line.isEmpty {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let phrase = parts.first, !phrase.isEmpty else { continue }
            phrases.insert(String(phrase))
            if parts.count == 2, !parts[1].isEmpty { meanings[String(phrase)] = String(parts[1]) }
        }
        // Short of what the header promised means the file was cut; refused, so the next launch rebuilds.
        guard phrases.count == declared else { return nil }
        self.init(contentVersion: String(fields[1]), phrases: phrases, meanings: meanings)
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

    /// One entry's sub-entries: the label, and the first definition inside the same block.
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
    static func subEntries(in xhtml: String) -> [(String, String)] {
        guard let tree = EntryTree.parse(xhtml) else { return [] }
        var found: [(String, String)] = []
        // Maximal blocks: a sub-entry nested inside another is reached through its parent, and taking both
        // would attribute the inner one's definition twice.
        for block in tree.root.maximalDescendants(where: { $0.classes.contains(blockClass) }) {
            guard let label = block.firstDescendant(where: { $0.classes.contains(labelClass) }) else { continue }
            let text = collapsed(
                label.firstDescendant(where: { $0.classes.contains(labelTextClass) })?.text ?? label.text)
            guard PhraseSpans.isMultiWord(text) else { continue }
            // **Inside this block only.** Searching past it gave a sub-entry with no definition of its own
            // the *following* one's — the wrong meaning under the right words.
            guard let definition = block.firstDescendant(where: { $0.classes.contains(definitionClass) })
            else { continue }
            let meaning = collapsed(definition.text)
            guard !meaning.isEmpty else { continue }
            found.append((text.lowercased(), meaning))
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
