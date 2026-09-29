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

    /// What the phrase means, where the dictionary that knows it explains it.
    ///
    /// **Carried with the span, because the finder is the only thing that has it.** A phrase filed as a
    /// sub-entry is answered by the framework with its *parent's* entry, whose senses are not the phrase's,
    /// so the definition cannot be recovered downstream — it has to travel from the body walk that read it.
    public let definition: String?

    public init(phrase: String, location: Int, length: Int,
                separation: PhraseSeparation, definition: String? = nil) {
        self.phrase = phrase
        self.location = location
        self.length = length
        self.separation = separation
        self.definition = definition
    }
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
