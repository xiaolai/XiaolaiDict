import Foundation

/// One phrase span found in a sentence, before any dictionary has been asked about it.
///
/// Distinct from `PhraseHit`, which is this plus the entries and crosses the wire. Kept apart because
/// finding the span and asking the dictionaries are different jobs done by different modules, and a type
/// that carried both would force the finder to know about entries.
public struct PhraseSpan: Sendable, Equatable {
    /// The dictionary's own spelling, slots and all — `take something into account`. **What to look up**,
    /// not what the reader wrote.
    public let phrase: String
    /// Where the span sits in the sentence it was found in, UTF-16, gap included.
    public let location: Int
    public let length: Int
    public let separation: PhraseSeparation

    /// **Every** way the reader's dictionaries file and explain this phrase, each naming which one said it.
    ///
    /// **Carried with the span, because the finder is the only thing that has it.** A phrase filed as a
    /// sub-entry is answered by the framework with its *parent's* entry, whose senses are not the phrase's,
    /// so the definition cannot be recovered downstream — it has to travel from the body walk that read it.
    ///
    /// A list, and each entry attributed, because this was one unattributed string until 2026-09-29: every
    /// dictionary's meanings were merged first-identifier-wins, and a block's definitions beyond the first
    /// were dropped at the walk. Empty for a phrase from the key index, which no dictionary explains.
    public let filings: [PhraseFiling]

    public init(phrase: String, location: Int, length: Int,
                separation: PhraseSeparation, filings: [PhraseFiling] = []) {
        self.phrase = phrase
        self.location = location
        self.length = length
        self.separation = separation
        self.filings = filings
    }
}

/// One dictionary's filing of a phrase, and every definition it gives it.
///
/// **A wire copy of `AppleDictionaryFormat.PhraseExplanation`, plus who said it**, for the same reason
/// `PhraseSeparation` is a copy of `PhraseSpans.Separation`: `DictionaryModel` crosses the XPC boundary and
/// binds nothing but `XiaolaiDictBase`, while the format reader is the service's business.
///
/// The parent and block ids are the publisher's own — measured 2026-09-29, **9,762 of NOAD's 9,762**
/// sub-entry blocks carry one. They say *where this definition was found*. They are **not** a sense key and
/// must never be stored as one: the phrase inventory and the live sense path are different extractors, and
/// a study item keyed by one of them cannot be compared with the other.
public struct PhraseFiling: Codable, Sendable, Equatable {
    /// Which dictionary explained it. The half that used to be discarded: every dictionary's meanings were
    /// merged into one map in identifier order, so a card could not say whose answer it was showing.
    public let dictionary: DictionaryIdentity
    /// The entry the block is filed in — `account` for `take something into account`.
    public let parentEntryID: String
    /// The block's own publisher id, empty where the dictionary marks none.
    public let blockID: String
    /// Every definition in the block, in document order. `give up` has five.
    public let definitions: [String]

    public init(dictionary: DictionaryIdentity, parentEntryID: String, blockID: String,
                definitions: [String]) {
        self.dictionary = dictionary
        self.parentEntryID = parentEntryID
        self.blockID = blockID
        self.definitions = definitions
    }

    /// The leading definition, for a surface with room for one. **A choice, not the meaning** — a caller
    /// that can see the reader's sentence should choose better than this can.
    public var definition: String? { definitions.first }
}

/// Whether the reader is standing inside a phrase their dictionary knows.
///
/// **A seam, so `DictionaryBridge` never links a dictionary-format reader.** The bridge's subject is the
/// private DictionaryServices API, whose failure mode is a segfault; reading `KeyText.data` is a different
/// job with a different failure mode, and the two live in different modules. The service composes them.
/// A test supplies a fixture instead, which is what lets the wire be asserted without a dictionary.
public protocol PhraseFinding: Sendable {
    /// **False while the inventory is still being read, and that is not the same as "no phrase here."**
    /// Reading a dictionary's keys costs about a second, so the first lookup after the service launches can
    /// genuinely arrive first — and a card told `nil` would say there was nothing to find.
    var isReady: Bool { get }

    /// True once a read has finished and found nothing to read. **`isReady` false means one of two things**
    /// — not yet, or never — and a reader whose dictionaries all failed was told "not yet" for ever.
    var isUnavailable: Bool { get }

    /// **Every phrase covering `term`, best first** — empty where the reader is on an ordinary word.
    ///
    /// Plural because length must not choose the unit: `give up` and `give up the ghost` both cover the
    /// hovered word in "they give up the ghost", and which one the reader met is the selector's question.
    ///
    /// `term` is UTF-16, into `sentence`. Called only when `isReady`.
    func phrases(in sentence: String, at term: NSRange) -> [PhraseSpan]
}
