import CryptoKit
import Foundation

/// How precisely a sense can be addressed — the capture-quality invariant applied to sense
/// extraction: a weaker claim must read as one (`dev-docs/dictionary-markup.md` §9).
///
/// Decided per sense, not per dictionary. That is measured rather than assumed: the Oxford American
/// Writer's Thesaurus carries publisher ids on some entries and not on others — *fine*'s first entry
/// has none, its second has `t_en_gb0005669.001`.
public enum SenseKeyKind: String, Codable, Sendable, CaseIterable, Comparable {
    /// The dictionary marks senses with nothing a parser can key to — the sideloaded conversions
    /// whose sense boundary is a colour change. Entry level only.
    case none
    /// The entry has sense structure but this sense carries no id, so it is addressed by where it
    /// sits. Stable until Apple ships a content update, which is what `textHash` is for.
    case position
    /// The publisher's own sense id: `m_en_gbus0000030.005` in NOAD, `b-en-zh_hans0037106.002` in
    /// 牛津英汉汉英.
    case publisher

    private var rung: Int {
        switch self {
        case .none: 0
        case .position: 1
        case .publisher: 2
        }
    }

    public static func < (a: SenseKeyKind, b: SenseKeyKind) -> Bool { a.rung < b.rung }
}

/// Where a sense sits in its entry. Numbering restarts inside an entry — *hold* in 牛津英汉汉英 runs
/// ①–㉙ for the transitive verb, then ①–⑧ for the intransitive, then again for the noun, where 货舱
/// is ⑧ — so a bare ordinal is meaningless without the block it belongs to
/// (`dev-docs/study-unit.md` §1).
public struct SensePath: Codable, Sendable, Equatable, Hashable {
    /// Which part-of-speech block, from 1, in document order.
    public let block: Int
    /// The sense's place within that block, from 1.
    public let ordinal: Int

    public init(block: Int, ordinal: Int) {
        self.block = block
        self.ordinal = ordinal
    }
}

/// One sense of one entry, read from the structural layer the dictionaries share.
public struct DictionarySense: Codable, Sendable, Equatable {
    public let path: SensePath
    /// The publisher's id when the sense has one, otherwise its position written as
    /// `block.ordinal`. Nil only when there is no sense to key at all.
    public let key: String?
    public let keyKind: SenseKeyKind
    /// The sense's primary definition or translation (`d:def`), where the dictionary marks one.
    public let definition: String?
    /// The whole sense as text — its definition, its examples and any subsenses hanging under it.
    /// This is what the sense selector compares the reader's sentence against, and it is structural,
    /// so it needs no per-dictionary adapter.
    public let text: String
    /// A hash of `text`. Under a position key it is the only way to notice an Apple content update
    /// moving a sense, rather than silently re-pointing the reader's history at another meaning
    /// (`dev-docs/study-unit.md` §5.2).
    public let textHash: String

    public init(path: SensePath, key: String?, keyKind: SenseKeyKind, definition: String?, text: String) {
        self.path = path
        self.key = key
        self.keyKind = keyKind
        self.definition = definition
        self.text = text
        self.textHash = Self.hash(text)
    }

    /// Truncated to 16 hex characters: enough that two senses of one entry colliding is not a
    /// practical concern, and short enough to read in a ledger row.
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// What the reader sees in the sidebar: the definition where there is one, else the start of
    /// the sense's own text. Never empty, and never a promise the sense cannot keep.
    public var label: String {
        let source = definition ?? text
        guard source.count > 64 else { return source }
        return source.prefix(63).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// One part-of-speech block — `x_xd0` — and the senses inside it.
public struct SenseBlock: Codable, Sendable, Equatable {
    /// 1-based, in document order.
    public let number: Int
    /// The text of the block's `d:pos`: "adjective", "noun". Nil when the block names none.
    public let partOfSpeech: String?
    public let senses: [DictionarySense]

    public init(number: Int, partOfSpeech: String?, senses: [DictionarySense]) {
        self.number = number
        self.partOfSpeech = partOfSpeech
        self.senses = senses
    }
}
