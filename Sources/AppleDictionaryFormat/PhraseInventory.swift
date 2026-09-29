import Foundation

/// Every phrase one dictionary knows, **and what each one means**.
///
/// **The artefact the phrase feature actually needs, and it is small.** Measured on NOAD 2026-09-29:
/// **9,743 phrases with their meanings in 632 KB, read in 7.0 s.** For comparison, the full index is
/// 319 MB and minutes, and `EntryIndexer` over the same body is **109 s** — 102 of those seconds spent on
/// sense keys, content hashes and ordinals that a phrase list has no use for. Reading the phrases with the
/// indexer because the indexer was already written is what made this look expensive.
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
    static let formatVersion = "phrases/1"

    public func encoded() -> String {
        var lines = ["\(Self.formatVersion)\t\(contentVersion)"]
        lines.reserveCapacity(phrases.count + 1)
        for phrase in phrases.sorted() {
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
        let fields = header.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0] == Self.formatVersion else { return nil }
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
        self.init(contentVersion: String(fields[1]), phrases: phrases, meanings: meanings)
    }

    /// The sub-entry label's class, and the definition's.
    ///
    /// **`class="df"`, not the `d:def` attribute.** A sub-entry's definition span carries only the class —
    /// which is the same reason reading `d:def` reaches 74.6% of NOAD's definitions and `class="df"` reaches
    /// nearly all. A first version searched for the attribute and found **zero** phrases in 111,606 entries,
    /// which is what a wrong selector looks like: not an error, an empty answer.
    static let labelClass = "x_xoh"
    static let definitionClass = "df"

    /// One entry's sub-entries: the label, and the first definition under it.
    ///
    /// Multi-word only. A one-word sub-entry is a derived form — *bucketful* under *bucket* — not a phrase a
    /// reader meets mid-sentence and fails to notice.
    static func subEntries(in xhtml: String) -> [(String, String)] {
        var found: [(String, String)] = []
        var scanner = xhtml.startIndex
        while let hit = xhtml.range(of: labelClass, range: scanner ..< xhtml.endIndex) {
            scanner = hit.upperBound
            // **A whole class token, never a prefix.** `class="sn x_xoh"` and `class="l x_xoh"` are both
            // real spellings, so anchoring on `class="x_xoh` found 11 of `take`'s labels where the whole-word
            // test finds every one. The project's own rule, and this is the third place it has bitten.
            guard isWholeToken(at: hit, in: xhtml),
                  let label = element(after: hit.upperBound, in: xhtml),
                  label.text.contains(" "),
                  let definition = xhtml.range(of: "class=\"\(definitionClass)\"",
                                               range: label.end ..< xhtml.endIndex),
                  let meaning = element(after: definition.upperBound, in: xhtml),
                  !meaning.text.isEmpty
            else { continue }
            found.append((label.text.lowercased(), meaning.text))
        }
        return found
    }

    /// Whether the class name found at `range` is a whole token rather than part of a longer one.
    private static func isWholeToken(at range: Range<String.Index>, in xhtml: String) -> Bool {
        let after = range.upperBound < xhtml.endIndex ? xhtml[range.upperBound] : " "
        let before = range.lowerBound > xhtml.startIndex
            ? xhtml[xhtml.index(before: range.lowerBound)] : " "
        return (after == "\"" || after == " ") && (before == "\"" || before == " ")
    }

    /// The text of the element whose opening tag contains `from`, and where that element ends.
    private static func element(after from: String.Index, in xhtml: String) -> (text: String, end: String.Index)? {
        guard let tag = xhtml.range(of: ">", range: from ..< xhtml.endIndex),
              let shut = xhtml.range(of: "</span>", range: tag.upperBound ..< xhtml.endIndex)
        else { return nil }
        return (stripped(xhtml[tag.upperBound ..< shut.lowerBound]), shut.upperBound)
    }

    /// Markup removed, whitespace collapsed to one space and trimmed. A label arrives as
    /// `take something into account ` with a trailing space, and a key with one is a key nothing matches.
    private static func stripped(_ markup: Substring) -> String {
        var text = String(markup)
        while let open = text.range(of: "<"),
              let shut = text.range(of: ">", range: open.lowerBound ..< text.endIndex) {
            text.removeSubrange(open.lowerBound ..< shut.upperBound)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
