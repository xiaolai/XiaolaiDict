import CryptoKit
import Foundation

/// Where a sense sits in its entry's own declared structure.
///
/// **This exists so that a content key does not depend on its siblings.** The first scheme disambiguated
/// two identically-worded senses by appending `:<ordinal>`, counting prior collisions — which made every
/// key a function of how many siblings happened to share its wording. Measured:
///
///     definitions ["stop"]          -> ["6c45cb72a36e"]
///     definitions ["stop", "stop"]  -> ["6c45cb72a36e:0", "6c45cb72a36e:1"]
///
/// The first key *changed* when a second sense was added, and document order decided which sibling owned
/// `:0`, so reordering two identically-worded sub-entries swapped their identities. Every step that
/// recovers more definitions would have silently renamed senses a reader had already studied.
///
/// **The fix is to disambiguate on position rather than on order.** Each field below is something the
/// markup *declares* about the sense, not something the reader counts. Two identically worded senses then
/// differ because their declared positions differ, and neither key depends on the other sense existing.
///
/// Every field is optional because most dictionaries declare only some of them: 27 of 84 mark no sense
/// number at all, and a main sense has no sub-entry label by definition. An absent field and an empty one
/// are deliberately the same value — a dictionary that prints an empty sense-number span has not
/// numbered that sense.
public struct SensePosition: Sendable, Equatable, Hashable, Codable {
    /// The sub-entry's own label — a phrasal verb or idiom's headword, `x_xoh` in Apple's markup.
    /// Nil for a main sense, which is what keeps recovering sub-entries from renaming main senses.
    public let subEntry: String?
    /// The part-of-speech block's label, as `x_xd0` declares it. `fine` the noun and `fine` the verb are
    /// different senses of one entry even when a publisher words them alike.
    public let partOfSpeech: String?
    /// The number the dictionary prints against this sense — `class="sn"`, so "1", "2", "a".
    public let senseNumber: String?

    /// A sense whose dictionary declares no structure at all. Not a placeholder: 23 dictionaries are
    /// like this throughout, and for them the definition's own wording is the whole of its identity.
    public static let unplaced = SensePosition()

    /// **A field that normalises to nothing is stored as nothing.** `SensePosition(senseNumber: "")`
    /// produced a value that compared unequal to `.unplaced`, hashed differently, and reported
    /// `isUnplaced == false` — while yielding an identical digest. Canonicalising here makes the type's
    /// equality agree with the key it produces instead of contradicting it.
    public init(subEntry: String? = nil, partOfSpeech: String? = nil, senseNumber: String? = nil) {
        func kept(_ field: String?) -> String? {
            guard let field, !SenseKey.normalise(field).isEmpty else { return nil }
            return field
        }
        self.subEntry = kept(subEntry)
        self.partOfSpeech = kept(partOfSpeech)
        self.senseNumber = kept(senseNumber)
    }

    /// Whether the markup declared anything about where this sense sits.
    public var isUnplaced: Bool { self == .unplaced }

    /// **Decoding goes through the canonicalising initialiser too.** The synthesized `Decodable` assigned
    /// the stored properties directly, so `{"senseNumber":""}` decoded to a value that compared unequal to
    /// `.unplaced` and reported `isUnplaced == false` while producing an identical key — reintroducing by the
    /// back door exactly the inconsistency the initialiser removes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(subEntry: try container.decodeIfPresent(String.self, forKey: .subEntry),
                  partOfSpeech: try container.decodeIfPresent(String.self, forKey: .partOfSpeech),
                  senseNumber: try container.decodeIfPresent(String.self, forKey: .senseNumber))
    }

    /// The fields that go into the digest, normalised the same way a definition is, in a fixed order.
    /// Order is part of the scheme: swapping two fields here would rename every positioned sense.
    var digestFields: [String] {
        [subEntry, partOfSpeech, senseNumber].map { SenseKey.normalise($0 ?? "") }
    }
}

/// One definition together with where the markup says it sits — the pair a content key is computed from.
///
/// Both halves are needed and neither is sufficient: the wording alone collides between two senses that
/// a publisher worded alike, and the position alone changes whenever the publisher renumbers.
public struct PositionedDefinition: Sendable, Equatable {
    public let definition: String
    public let position: SensePosition

    public init(definition: String, position: SensePosition = .unplaced) {
        self.definition = definition
        self.position = position
    }
}

/// The keys for one entry's senses, together with the cases the scheme could not separate on its own.
///
/// **`ordinalled` is why this is a struct and not an array.** Two senses identical in wording *and* in
/// declared position carry no information that could tell them apart, so the last resort is still an
/// ordinal — and an ordinal reintroduces order dependence for exactly those senses. That is a fact a
/// caller is entitled to know, so it is returned rather than hidden: `keys` alone would have made the
/// residual case silent, which is the property the whole redesign was meant to remove.
public struct SenseKeyAssignment: Sendable, Equatable {
    public let keys: [SenseKey]
    /// Indices into `keys` that needed an ordinal because an earlier sense in the same entry had both the
    /// same definition and the same declared position. Empty in the intended case.
    public let ordinalled: [Int]

    public init(keys: [SenseKey], ordinalled: [Int]) {
        self.keys = keys
        self.ordinalled = ordinalled
    }

    /// Whether the scheme had to fall back to order for any sense of this entry.
    public var neededOrdinals: Bool { !ordinalled.isEmpty }
}

/// A durable name for one sense, whether or not its publisher supplied one.
///
/// **Why this exists.** 23 of the 84 readable Apple dictionaries carry no sense id at all — among them
/// 譯典通, 现代汉语规范词典, the Cantonese colloquialisms, Duden and Sanseido's 大辞林 (measured
/// 2026-09-27; the earlier figure of 27 came from a probe that looked for the attribute in the markup,
/// and `DICTIONARIES.md` records the measured count). A study card or ledger row pointing at "the third sense of entry X" breaks the moment
/// the publisher re-orders, and Apple re-masters these: 牛津英汉汉英's own copyright reads
/// "© 2010, 2025".
///
/// **The scheme.** Namespace by dictionary and entry, then address the sense by its own content *and its
/// declared position*:
///
///     <dictionary identifier>/<d:entry id>#<sha256(definition + position) first 12 hex>
///     …:<n>   appended only to the nth repeat of one definition at one position
///
/// `SensePosition` explains why the position is in the digest rather than an ordinal appended after it:
/// an ordinal counts siblings, so it renames a sense when a neighbour is added.
///
/// **Validated where the truth is known, through the indexer that ships.** Across every dictionary
/// that carries publisher ids — 75,401 sense pairs from 50 dictionaries — the mapping between a
/// publisher key and a content key is **exact in both directions, 100.00%**.
///
/// **That catalogue figure predates this scheme and has not been re-measured under it.** It was taken while
/// disambiguation was an appended `:ordinal`; the digest input changed when position moved inside it, so
/// every content key changed with it. Re-measured on the 9 readable dictionaries this Mac has: **4,777
/// pairs, forward and reverse 100.00%** — the same result, over a set 16 times smaller. One gated run
/// against the full catalogue refreshes the larger number. Forward exactness says the
/// key is a function of the sense; reverse exactness says two senses one entry words alike still get
/// distinct names.
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
/// worse than losing it. A key that outlived its own meaning would be the bug. A publisher renumbering
/// its senses changes keys for the same reason, and is why a publisher id is preferred wherever one
/// exists — content addressing cannot have it both ways.
public struct SenseKey: Sendable, Equatable, Hashable, Codable {
    /// How this key was arrived at. A content-derived key must never read as a publisher's — the same
    /// distinction `SenseKeyKind` draws for positional claims.
    public enum Origin: String, Sendable, Equatable, Codable {
        /// The publisher's own id, carried in `id` or `lexid`.
        case publisher
        /// Derived from the definition's text and position, because the publisher supplied none.
        case content
    }

    public let dictionary: String
    public let entry: String
    public let value: String
    public let origin: Origin

    /// A string that identifies this key and **nothing else**.
    ///
    /// **Origin is part of it, and the components are length-prefixed.** The readable form
    /// `dictionary/entry#value` lost two distinctions: a publisher id that happens to read like a digest
    /// produced the same string as the content key with that digest, and `(entry: "e#a", value: "b")`
    /// serialised identically to `(entry: "e", value: "a#b")`. `SenseKeyValidityTests` keys its forward and
    /// reverse maps on this string, so a collision here would show up as exactness the scheme had not
    /// earned.
    public var description: String {
        // **Precomposed first.** Swift compares `"é"` and `"e\u{0301}"` as equal, so two keys that *are*
        // equal produced different byte lengths and therefore different identities — a map keyed on this
        // string would have counted them apart while `==` counted them together.
        ([origin.rawValue, dictionary, entry, value]
            .map { $0.precomposedStringWithCanonicalMapping }
            .map { "\($0.utf8.count):\($0)" }).joined()
    }

    /// The readable form, for a log line or an error message. Never used as an identity — `description` is.
    public var displayForm: String { "\(dictionary)/\(entry)#\(value)" }

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

    /// A content key for one sense at one position.
    ///
    /// `ordinal` is the last resort `keys(dictionary:entry:senses:)` applies, and a caller keying a
    /// single sense should leave it nil — an ordinal chosen without seeing the entry's other senses
    /// cannot be the right one.
    public static func content(
        dictionary: String, entry: String, definition: String,
        position: SensePosition = .unplaced, ordinal: Int? = nil
    ) -> SenseKey {
        var value = digest(of: definition, at: position)
        if let ordinal { value += ":\(ordinal)" }
        return SenseKey(dictionary: dictionary, entry: entry, value: value, origin: .content)
    }

    /// Keys for every sense of one entry, in document order.
    ///
    /// **A key depends on its own sense and on nothing else.** Inserting, deleting or reordering senses
    /// leaves every other key untouched, because the digest is over the definition and the declared
    /// position — neither of which mentions a sibling.
    ///
    /// The one residue is two senses identical in *both*. There is nothing left to tell them apart, so
    /// the first keeps the bare digest and each later repeat takes `:1`, `:2`. First-keeps-bare is
    /// deliberate over numbering the whole group: appending a repeat then leaves the earlier sense's key
    /// alone, where numbering everything would rename it. Every index that needed one comes back in
    /// `SenseKeyAssignment.ordinalled`, so the fallback is reported rather than silent.
    public static func keys(
        dictionary: String, entry: String, senses: [PositionedDefinition]
    ) -> SenseKeyAssignment {
        var seen: [String: Int] = [:]
        var keys: [SenseKey] = []
        var ordinalled: [Int] = []
        keys.reserveCapacity(senses.count)
        for (index, sense) in senses.enumerated() {
            let d = digest(of: sense.definition, at: sense.position)
            let repeats = seen[d, default: 0]
            seen[d] = repeats + 1
            if repeats == 0 {
                keys.append(SenseKey(dictionary: dictionary, entry: entry, value: d, origin: .content))
            } else {
                keys.append(SenseKey(dictionary: dictionary, entry: entry,
                                     value: "\(d):\(repeats)", origin: .content))
                ordinalled.append(index)
            }
        }
        return SenseKeyAssignment(keys: keys, ordinalled: ordinalled)
    }

    /// First 12 hex of SHA-256 over the normalised definition and position. 12 hex is 48 bits; within one
    /// entry, which holds tens of senses rather than millions, accidental collision is not the failure
    /// mode — *identical wording at an identical position* is, and that is handled explicitly above
    /// rather than by widening the digest.
    static func digest(of definition: String, at position: SensePosition = .unplaced) -> String {
        let data = Data(digestInput(definition, position).utf8)
        return SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The bytes that are hashed: each field as `<utf8 length>:<field>`, concatenated.
    ///
    /// **Length-prefixed rather than separated by a delimiter**, because a normalised definition can
    /// contain any character internally — a separator would let a definition ending in the separator and
    /// a position beginning with it produce the same input as a different pair. Length prefixes make that
    /// unrepresentable instead of unlikely.
    static func digestInput(_ definition: String, _ position: SensePosition) -> String {
        ([normalise(definition)] + position.digestFields)
            .map { "\($0.utf8.count):\($0)" }
            .joined()
    }

    /// NFC, lowercased, whitespace collapsed, and the punctuation dictionaries vary on trimmed from
    /// both ends — including the CJK forms, since a definition ending in `。` and the same one ending
    /// in `.` are the same definition.
    static func normalise(_ text: String) -> String {
        // **Lowercase first, then precompose.** The other order lets case folding undo the normalisation:
        // `"J\u{030C}"` has no precomposed uppercase form, so NFC leaves it decomposed and lowercasing gives
        // `j` + U+030C, while the same word written `"\u{01F0}"` stays composed — two spellings of one
        // definition, two keys.
        let folded = text.lowercased().precomposedStringWithCanonicalMapping
        let collapsed = folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " .;,:!?·。，；：、！？"))
    }
}
