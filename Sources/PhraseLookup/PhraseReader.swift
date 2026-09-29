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
    private let phrases: @Sendable (DictionaryBundle) -> PhraseInventory?

    private struct Read {
        let spans: PhraseSpans
        /// Whether any dictionary was read at all. **False is not an empty inventory**: a detector over
        /// nothing answers `.none` to every sentence, which tells a reader there is no phrase here when the
        /// truth is that nothing could be looked in.
        let readAnything: Bool
        /// Phrase to every dictionary's filing of it. **Held rather than re-read**: a lookup must not
        /// open a file to say what a phrase means, and all three of them are 2,080 KB.
        let filings: [String: [PhraseFiling]]
    }

    /// `phrases` supplies one dictionary's whole inventory — its multi-word search keys **and** the sub-entry
    /// labels with their meanings. Nil for a dictionary that cannot be read.
    ///
    /// **Nothing here touches `KeyText.data`.** Re-deriving the keys on every launch cost 2.24 s of a 2.8 s
    /// start-up for an answer the stored inventory already has. Injected rather than read so the matcher can
    /// be tested without a licensed dictionary on disk.
    /// **`phrases` has no default.** One that returned nil made a call with real bundles compile and then
    /// read nothing from any of them — a detector that finds no phrase in any sentence, for a reason the
    /// signature invited. The convenience initialiser above supplies the empty provider where that is meant.
    public init(bundles: [DictionaryBundle],
                phrases: @escaping @Sendable (DictionaryBundle) -> PhraseInventory?) {
        self.bundles = bundles
        self.phrases = phrases
    }

    /// An inventory already in hand. For a caller that built one, and for tests, which must be able to
    /// assert the mapping from a sentence to a span without a licensed dictionary on disk.
    public convenience init(phrases: Set<String>, filings: [String: [PhraseFiling]] = [:]) {
        self.init(bundles: [], phrases: { _ in nil })
        let built = PhraseSpans(phrases: phrases)
        inventory.withLock { $0 = Read(spans: built, readAnything: true, filings: filings) }
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

    /// **False until something has actually been read.** It was true as soon as `read()` returned, so a reader
    /// whose every dictionary failed got a detector that answered "no phrase here" to every sentence — the
    /// failure rendering exactly as confidently as a success, with the reason only in the log. Where nothing
    /// could be read this stays false and the service answers `.notReady`, which is true.
    public var isReady: Bool { inventory.withLock { $0?.readAnything == true } }

    /// A read finished and no dictionary could be read. Distinct from not having read yet.
    public var isUnavailable: Bool { inventory.withLock { $0?.readAnything == false } }

    /// What the phrase means, from the dictionary that knows it.
    ///
    /// **The half the live sense path cannot reach.** `EntryDocument` walks `x_xd0`/`x_xd1` and a sub-entry is
    /// `x_xo<N>`, so the framework answering `take something into account` hands over *account*'s six noun
    /// senses and not one of them is *consider something along with other factors before reaching a
    /// decision*. The body walk already put it here.
    ///
    /// Nil for a phrase that came from the key index, which carries spellings and no definitions.
    public func filings(of phrase: String) -> [PhraseFiling] {
        inventory.withLock { $0?.filings[phrase] } ?? []
    }

    /// Reads the inventory from the store. **Call this off the reply path.**
    ///
    /// The first read of a dictionary walks its body once — seconds, and the cost is per dictionary version;
    /// every launch after that reads a file. Until it has read something a lookup answers `.notReady`, which
    /// is a different fact from "no phrase here" and is said as one. The measurements are in
    /// `dev-docs/wiring-phrase-lookup.md`.
    ///
    /// One dictionary failing does not stop the others: a reader with three English dictionaries and one
    /// unreadable file still gets the phrases from the two that read. The failure is named, not swallowed.
    @discardableResult public func read() -> Reading {
        var found = Set<String>()
        var filings: [String: [PhraseFiling]] = [:]
        var read: [String] = [], failed: [String] = []
        for bundle in bundles {
            guard let inventory = phrases(bundle) else {
                failed.append(bundle.displayName)
                continue
            }
            found.formUnion(inventory.phrases)
            // **Every dictionary's filing is kept, and each says which dictionary it is.** This merged
            // `{ first, _ in first }` until 2026-09-29, in `DictionaryLocator.installed()` order — by
            // identifier, which is nobody's preference — so where two dictionaries explained a phrase
            // differently one answer was discarded and the survivor could not be attributed. Choosing
            // between them needs the reader's sentence, which this type cannot see.
            let identity = DictionaryIdentity(name: bundle.displayName, identifier: bundle.identifier,
                                              version: bundle.declaredVersion)
            for (phrase, explanations) in inventory.explanations {
                filings[phrase, default: []].append(contentsOf: explanations.map {
                    PhraseFiling(dictionary: identity, parentEntryID: $0.parentEntryID,
                                 blockID: $0.blockID, definitions: $0.definitions)
                })
            }
            read.append(bundle.displayName)
        }
        let built = PhraseSpans(phrases: found)
        inventory.withLock { $0 = Read(spans: built, readAnything: !read.isEmpty, filings: filings) }
        return Reading(phrases: built.phrases.count, explained: filings.count,
                       read: read, failed: failed)
    }

    public func phrases(in sentence: String, at term: NSRange) -> [PhraseSpan] {
        guard let inventory = inventory.withLock({ $0 }) else { return [] }
        // **`forms`, not `lemmas`.** A dictionary files `by all accounts` with the plural and
        // `keep a tight rein on` with the lemma, so one chosen form loses 36,766 phrases of 116,122. Each
        // position offers both and the keys decide.
        let words = Lemmatizer.forms(in: sentence)
        guard let hovered = Self.word(covering: term, among: words) else { return [] }
        // Back from word indices to the reader's own text. **The span's ends, not the matched words' own
        // ranges joined** — a gap belongs inside the span, because that is what the reader sees.
        return inventory.spans.matches(in: words.map(\.candidates), containing: hovered).map { match in
            let first = words[match.words.lowerBound].range
            let last = words[match.words.upperBound].range
            return PhraseSpan(
                phrase: match.phrase,
                location: first.location, length: last.location + last.length - first.location,
                separation: Self.separation(match.separation),
                filings: inventory.filings[match.phrase] ?? [])
        }
    }

    /// The leading phrase, for a caller that wants one — the same order `phrases(in:at:)` returns.
    public func phrase(in sentence: String, at term: NSRange) -> PhraseSpan? {
        phrases(in: sentence, at: term).first
    }

    /// Which word the captured range is on.
    ///
    /// **Overlap, not equality.** The capture's range covers the surface as it was found, which is not
    /// always a whole word — `Lemmatizer` documents the same thing: *temper* captured in "justice tempered
    /// with mercy" is a range over `temper` inside `tempered`. A range that matched only exactly would find
    /// nothing there, and the phrase would be missed for a reason that has nothing to do with phrases.
    static func word(covering term: NSRange, among words: [WordForms]) -> Int? {
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
