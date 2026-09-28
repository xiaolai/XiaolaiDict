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
/// **A dictionary stores its keys in lemma form.** `give up` is a key and `gave up` is not, so a caller
/// normalises each word of the sentence before asking — `Lemmatizer` resolves 8 of 8 measured irregulars
/// when it has the sentence, which it does here. The words handed in are expected to be already
/// normalised and case-folded; this type does no language work of its own, because the module deliberately
/// links nothing but Foundation, Compression, CryptoKit and SQLite3.
public struct PhraseSpans: Sendable, Equatable {
    /// Multi-word keys only. A single word is never a phrase: the bridge already looks one up, and
    /// admitting them here would make every lookup claim to have found a phrase.
    public let phrases: Set<String>

    /// The longest phrase in `phrases` spans this many words; searching wider than this cannot match, and
    /// a sentence is not a reason to look at every window in it.
    public let longest: Int

    public init(phrases: Set<String>) {
        let multiword = phrases.filter { $0.contains(" ") }
        self.phrases = multiword
        self.longest = multiword.reduce(1) { max($0, $1.split(separator: " ").count) }
    }

    /// Every multi-word key of one dictionary, read from its key index.
    ///
    /// `xpointer(` forms are skipped: they are locators into a document, not spellings of a word, and the
    /// same fragments once made sub-entry scoping match the wrong phrase.
    public init(bundle: URL) throws {
        var found = Set<String>()
        // **Every key of the group, not just the first.** A group is a folded search key followed by
        // display forms, so `keys.first` alone loses the spellings a reader actually writes: measured
        // 2026-09-29, 90,391 phrases from the first key against **104,009** from all of them.
        for group in try KeyIndexReader.groups(in: bundle) {
            for key in group.keys where key.contains(" ") && !key.contains("xpointer(") {
                found.insert(key)
            }
        }
        self.init(phrases: found)
    }

    /// The longest known phrase covering `word`, or nil where the reader is simply on an ordinary word.
    ///
    /// **Longest wins, and it must contain the hovered word.** A phrase elsewhere in the sentence is not
    /// what the reader pointed at, and answering with it would look like a detector that had drifted.
    /// Nothing is guessed: a span is returned only because the dictionary has it under that exact key.
    public func phrase(in words: [String], containing word: Int) -> String? {
        guard words.indices.contains(word) else { return nil }
        var best: String?
        // Widest first, so the first hit at a given width is settled by length rather than by position.
        for width in stride(from: min(longest, words.count), through: 2, by: -1) {
            let earliest = max(0, word - width + 1)
            let latest = min(word, words.count - width)
            guard earliest <= latest else { continue }
            for start in earliest ... latest {
                let span = words[start ..< start + width].joined(separator: " ")
                if phrases.contains(span) { best = span; break }
            }
            if best != nil { break }
        }
        return best
    }
}
