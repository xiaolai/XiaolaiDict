import XiaolaiDictCore

/// The panel's sidebar: dictionary → entry → sense (decision D1).
///
/// A dictionary answers with one record per homograph, so *fine* arrives as four entries from NOAD
/// and two from 牛津英汉汉英, and each of those entries has its own senses — 49 of them for
/// 牛津英汉汉英's *hold*, where 货舱 is the 47th. The flat list the lookup carries is the truth; this
/// is the shape the reader reads it in, and every node keeps the flat index it came from so
/// selecting a row still names exactly one entry to render.
public struct EntryOutline: Equatable {
    public let dictionaries: [DictionaryNode]

    public init(entries: [DictionaryEntry]) {
        var groups: [DictionaryNode] = []
        for (index, entry) in entries.enumerated() {
            let node = EntryNode(
                index: index, headword: entry.headword, homograph: entry.homograph, note: entry.matchNote,
                senseKeyKind: entry.senseKeyKind,
                senses: entry.senses.map { SenseNode(entryIndex: index, sense: $0) })
            // Grouped by runs, not by name: the bridge already returns a dictionary's records
            // together, and a dictionary that somehow appeared twice is two groups rather than a
            // silent merge of entries that arrived apart.
            if var last = groups.last, last.identity == entry.dictionary {
                last.entries.append(node)
                groups[groups.count - 1] = last
            } else {
                groups.append(DictionaryNode(identity: entry.dictionary, entries: [node]))
            }
        }
        dictionaries = groups
    }
}

/// One dictionary and the entries it answered with.
public struct DictionaryNode: Equatable, Identifiable {
    public let identity: DictionaryIdentity
    public var entries: [EntryNode]

    public var name: String { identity.name }

    /// The first entry's place in the flat list. A name would collide if a dictionary appeared
    /// twice; an index cannot.
    public var id: Int { entries.first?.index ?? -1 }
}

/// One entry — one record — under its dictionary.
public struct EntryNode: Equatable, Identifiable {
    /// Where this entry sits in the flat list the lookup carries.
    public let index: Int
    public let headword: String
    /// NOAD's *fine¹ fine² fine³ fine⁴*, where the dictionary numbers its homographs.
    public let homograph: String?
    /// When this entry is not headed by the term itself. It belongs to the entry rather than to the
    /// dictionary: with several entries per dictionary, "its dictionary form" is a fact about one.
    public let note: String?
    /// How precisely this entry's senses can be addressed. `.none` means the dictionary marks
    /// senses with nothing a parser can key to, and the sidebar shows no sense rows rather than
    /// inventing them.
    public let senseKeyKind: SenseKeyKind
    public let senses: [SenseNode]

    public var id: Int { index }

    /// The headword, with its homograph number raised the way the dictionary prints it. A marker
    /// that is not a plain number is shown as it is rather than mangled into a superscript that
    /// silently drops the characters it has no glyph for.
    public var label: String {
        guard let homograph else { return headword }
        guard let raised = Self.raised(homograph) else { return "\(headword) (\(homograph))" }
        return headword + raised
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
    ]

    private static func raised(_ marker: String) -> String? {
        guard !marker.isEmpty else { return nil }
        var raised = ""
        for character in marker {
            guard let glyph = superscripts[character] else { return nil }
            raised.append(glyph)
        }
        return raised
    }
}

/// One sense under its entry — the rung a study card stands on when the dictionary has one.
public struct SenseNode: Equatable, Identifiable {
    public let entryIndex: Int
    public let sense: DictionarySense

    public var id: OutlineSelection { .sense(entry: entryIndex, key: sense.key ?? "\(sense.path.block).\(sense.path.ordinal)") }
    public var label: String { sense.label }
    /// A position key is a weaker claim than a publisher's and has to read as one.
    public var keyKind: SenseKeyKind { sense.keyKind }
}

/// What the reader has selected in the sidebar. A sense selection still names its entry, because
/// the pane always renders a whole entry — decision D2 is to *mark* a sense, never to jump to it.
public enum OutlineSelection: Hashable {
    case entry(Int)
    case sense(entry: Int, key: String)

    public var entryIndex: Int {
        switch self {
        case .entry(let index): index
        case .sense(let index, _): index
        }
    }

    public var senseKey: String? {
        switch self {
        case .entry: nil
        case .sense(_, let key): key
        }
    }
}
