import CryptoKit
import Foundation

/// A durable name for one sense, whether or not its publisher supplied one.
///
/// **Why this exists.** 27 of the 84 readable Apple dictionaries carry no sense id at all — among them
/// 譯典通, 现代汉语规范词典, the Cantonese colloquialisms, Duden and Sanseido's 大辞林 (measured
/// 2026-09-27). A study card or ledger row pointing at "the third sense of entry X" breaks the moment
/// the publisher re-orders, and Apple re-masters these: 牛津英汉汉英's own copyright reads
/// "© 2010, 2025".
///
/// **The scheme.** Namespace by dictionary and entry, then address the sense by the content of its
/// definition:
///
///     <dictionary identifier>/<d:entry id>#<sha256(normalised definition) first 12 hex>
///     …:<ordinal>   appended only when that key repeats inside one entry
///
/// **Validated where the truth is known, through the indexer that ships.** Across every dictionary
/// that carries publisher ids — 75,401 sense pairs from 50 dictionaries — the mapping between a
/// publisher key and a content key is **exact in both directions, 100.00%**. Forward exactness says the
/// key is a function of the sense; reverse exactness says the ordinal does its job, since two senses in
/// one entry worded identically would otherwise collide.
///
/// Both figures are over **full keys, entry included**. An earlier measurement compared bare digests and
/// reported 97.55% reverse — but a digest is only unique within its entry by construction, so comparing
/// them across entries measured nothing the scheme claims.
///
/// **Measured through `EntryIndexer`, not a side probe, and that distinction earned its place.** A
/// Python probe first reported 100.00% over 29,065 pairs; re-measured through the real extraction path
/// the same claim was **98.45%**, because the indexer emitted one sense per `d:def` and a sense block
/// can hold several — the extras being cross-references like "American English = rappel". All 1,112
/// failures were inside a single entry, none across entries. Fixing the extractor restored exactness
/// over a set two and a half times larger.
///
/// **The namespace is load-bearing, not decoration.** Keyed globally instead of per dictionary the
/// forward figure was 99.39%: sense ids repeat *across* dictionaries, and 537 pairs collided for that
/// reason alone.
///
/// **What it deliberately does not survive.** Rewording a definition changes the key. That is correct:
/// the sense itself changed, and silently re-pointing a reader's card at edited content would be
/// worse than losing it. A key that outlived its own meaning would be the bug.
public struct SenseKey: Sendable, Equatable, Hashable, Codable {
    /// How this key was arrived at. A content-derived key must never read as a publisher's — the same
    /// distinction `SenseKeyKind` draws for positional claims.
    public enum Origin: String, Sendable, Equatable, Codable {
        /// The publisher's own id, carried in `id` or `lexid`.
        case publisher
        /// Derived from the definition's text, because the publisher supplied none.
        case content
    }

    public let dictionary: String
    public let entry: String
    public let value: String
    public let origin: Origin

    public var description: String { "\(dictionary)/\(entry)#\(value)" }

    public init(dictionary: String, entry: String, value: String, origin: Origin) {
        self.dictionary = dictionary
        self.entry = entry
        self.value = value
        self.origin = origin
    }

    /// The publisher's key, when the dictionary supplies one.
    public static func publisher(
        dictionary: String, entry: String, id: String
    ) -> SenseKey {
        SenseKey(dictionary: dictionary, entry: entry, value: id, origin: .publisher)
    }

    /// A content key for one sense. `ordinal` is nil unless the same definition appears twice in the
    /// entry; `keys(for:)` below applies that rule so a caller cannot forget it.
    public static func content(
        dictionary: String, entry: String, definition: String, ordinal: Int? = nil
    ) -> SenseKey {
        var value = digest(of: definition)
        if let ordinal { value += ":\(ordinal)" }
        return SenseKey(dictionary: dictionary, entry: entry, value: value, origin: .content)
    }

    /// Keys for every sense of one entry, in document order, disambiguating repeats.
    ///
    /// The ordinal is appended **only** to members of a colliding group, so the common case — every
    /// definition distinct — produces keys that do not depend on sense order at all. That is the whole
    /// point: reordering the senses of an entry must not rename them.
    public static func keys(
        dictionary: String, entry: String, definitions: [String]
    ) -> [SenseKey] {
        let digests = definitions.map(digest(of:))
        var counts: [String: Int] = [:]
        for d in digests { counts[d, default: 0] += 1 }
        var used: [String: Int] = [:]
        return digests.map { d in
            guard counts[d, default: 0] > 1 else {
                return SenseKey(dictionary: dictionary, entry: entry, value: d, origin: .content)
            }
            let n = used[d, default: 0]
            used[d] = n + 1
            return SenseKey(dictionary: dictionary, entry: entry, value: "\(d):\(n)", origin: .content)
        }
    }

    /// First 12 hex of SHA-256 over the normalised definition. 12 hex is 48 bits; within one entry,
    /// which holds tens of senses rather than millions, accidental collision is not the failure mode —
    /// *identical wording* is, and that is handled explicitly above rather than by widening the digest.
    static func digest(of definition: String) -> String {
        let data = Data(normalise(definition).utf8)
        return SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// NFC, lowercased, whitespace collapsed, and the punctuation dictionaries vary on trimmed from
    /// both ends — including the CJK forms, since a definition ending in `。` and the same one ending
    /// in `.` are the same definition.
    static func normalise(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping.lowercased()
        let collapsed = folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " .;,:!?·。，；：、！？"))
    }
}
