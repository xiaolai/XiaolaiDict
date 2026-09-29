import AppleDictionaryFormat
import DictionaryModel
import Foundation
import Synchronization

/// Finds the phrase a reader is standing inside, using the reader's **own** dictionaries.
///
/// The adapter between two modules that must not know about each other: `AppleDictionaryFormat` knows which
/// spans a dictionary spells and binds nothing but Foundation and SQLite; `DictionaryModel` carries the wire
/// protocol and the lemmatiser. This turns the one into the other, and is the whole of its job.
///
/// **Nothing here is distributed.** The inventory is read from dictionaries Apple licensed to this Mac, on
/// this Mac, and never leaves it — the same rule the index is built under.
public final class PhraseReader: PhraseFinding {
    /// The matcher and every phrase's meaning, or nil until they have been read. **The nil is the
    /// readiness**, rather than a second flag that could disagree with it, and the two are one value because
    /// a span without its meaning is half an answer.
    private let inventory = Mutex<Read?>(nil)
    private let bundles: [DictionaryBundle]
    private let phrases: @Sendable (DictionaryBundle) -> [String: String]

    private struct Read {
        let spans: PhraseSpans
        /// Phrase to its meaning, for the phrases a dictionary explains. **Held rather than re-read**: a
        /// lookup must not open a file to say what a phrase means, and the whole of NOAD's is 632 KB.
        let meanings: [String: String]
    }

    /// `phrases` supplies the phrases the key index does not hold, **each with its meaning** — the sub-entry
    /// labels, which `PhraseInventory` reads from the body in about seven seconds per dictionary. Injected
    /// rather than read here so the matcher can be tested without a licensed dictionary on disk, and so a
    /// reader whose body cannot be read still gets the keys.
    public init(bundles: [DictionaryBundle],
                phrases: @escaping @Sendable (DictionaryBundle) -> [String: String] = { _ in [:] }) {
        self.bundles = bundles
        self.phrases = phrases
    }

    /// An inventory already in hand. For a caller that built one, and for tests, which must be able to
    /// assert the mapping from a sentence to a span without a licensed dictionary on disk.
    public convenience init(phrases: Set<String>, meanings: [String: String] = [:]) {
        self.init(bundles: [])
        let built = PhraseSpans(phrases: phrases)
        inventory.withLock { $0 = Read(spans: built, meanings: meanings) }
    }

    /// What one reading found. **Returned rather than logged inside**, because a reader whose dictionaries
    /// could not be read gets a detector that finds nothing and looks exactly like one standing on ordinary
    /// words: green is not evidence that anything happened.
    public struct Reading: Sendable, Equatable {
        public let phrases: Int
        /// How many of them the dictionaries also explain. **Counted apart from `phrases`**: the key index
        /// contributes spellings without definitions, so the two numbers differ by design and a collapse of
        /// `explained` to zero is a body walk that stopped happening.
        public let explained: Int
        public let read: [String]
        public let failed: [String]
    }

    public var isReady: Bool { inventory.withLock { $0 != nil } }

    /// What the phrase means, from the dictionary that knows it.
    ///
    /// **The half the live sense path cannot reach.** `EntryDocument` walks `x_xd0`/`x_xd1` and a sub-entry is
    /// `x_xo<N>`, so the framework answering `take something into account` hands over *account*'s six noun
    /// senses and not one of them is *consider something along with other factors before reaching a
    /// decision*. The body walk already put it here.
    ///
    /// Nil for a phrase that came from the key index, which carries spellings and no definitions.
    public func meaning(of phrase: String) -> String? {
        inventory.withLock { $0?.meanings[phrase] }
    }

    /// Reads the inventory. **Call this off the reply path.**
    ///
    /// Measured on the development Mac, 2026-09-29: **7 English-indexing dictionaries, 232,373 phrases,
    /// 10–16 s**, of which about 2 s is building the template index and the rest is decompressing the key
    /// indexes. Per dictionary it is 1.16 s for NOAD and 0.13 s for the thesaurus.
    ///
    /// So this is not a cost a lookup can absorb, and it is not one an argument makes smaller: filtering out
    /// the keys that cannot match English prose — the Korean dictionary contributes **1** English key out of
    /// 28,522 — saves 0.3 s of the 12, because `PhraseSpans` already drops every single-word key and most of
    /// those are single words. The cost is the reading itself. A reader's lookups in the first dozen seconds
    /// after the service launches therefore answer `.notReady`, which is said rather than disguised; a cache
    /// on disk is what would remove the window, and that is not this stage.
    ///
    /// One dictionary failing does not stop the others: a reader with three English dictionaries and one
    /// unreadable file still gets the phrases from the two that read. The failure is named, not swallowed.
    @discardableResult public func read() -> Reading {
        var found = Set<String>()
        var meanings: [String: String] = [:]
        var read: [String] = [], failed: [String] = []
        for bundle in bundles {
            for (phrase, meaning) in phrases(bundle) {
                let key = phrase.lowercased()
                guard key.contains(" ") else { continue }
                found.insert(key)
                // **The first dictionary to explain a phrase keeps it**, in the reader's own dictionary
                // order — not a judgement this type is in a position to make.
                if meanings[key] == nil { meanings[key] = meaning }
            }
            do {
                found.formUnion(try PhraseSpans.keys(in: bundle.url))
                read.append(bundle.displayName)
            } catch {
                failed.append(bundle.displayName)
            }
        }
        let built = PhraseSpans(phrases: found)
        inventory.withLock { $0 = Read(spans: built, meanings: meanings) }
        return Reading(phrases: built.phrases.count, explained: meanings.count,
                       read: read, failed: failed)
    }

    public func phrase(in sentence: String, at term: NSRange) -> PhraseSpan? {
        guard let inventory = inventory.withLock({ $0 }) else { return nil }
        let words = Lemmatizer.lemmas(in: sentence)
        guard let hovered = Self.word(covering: term, among: words),
              let match = inventory.spans.match(in: words.map(\.lemma.text), containing: hovered)
        else { return nil }
        // Back from word indices to the reader's own text. **The span's ends, not the matched words' own
        // ranges joined** — a gap belongs inside the span, because that is what the reader sees.
        let first = words[match.words.lowerBound].range
        let last = words[match.words.upperBound].range
        return PhraseSpan(
            phrase: match.phrase,
            location: first.location, length: last.location + last.length - first.location,
            separation: Self.separation(match.separation),
            definition: inventory.meanings[match.phrase])
    }

    /// Which word the captured range is on.
    ///
    /// **Overlap, not equality.** The capture's range covers the surface as it was found, which is not
    /// always a whole word — `Lemmatizer` documents the same thing: *temper* captured in "justice tempered
    /// with mercy" is a range over `temper` inside `tempered`. A range that matched only exactly would find
    /// nothing there, and the phrase would be missed for a reason that has nothing to do with phrases.
    static func word(covering term: NSRange, among words: [LemmatizedWord]) -> Int? {
        words.firstIndex { NSIntersectionRange($0.range, term).length > 0 }
    }

    /// The wire's three-valued separation from the matcher's. Two spellings of one fact, because the module
    /// that crosses the XPC boundary may not bind the one that reads `KeyText.data`.
    static func separation(_ found: PhraseSpans.Separation) -> PhraseSeparation {
        switch found {
        case .none: .none
        case .marked(let words): .marked(words)
        case .inferred(let words): .inferred(words)
        }
    }
}
