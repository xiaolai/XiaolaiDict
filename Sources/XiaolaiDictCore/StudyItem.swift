import Foundation

/// What XiaolaiDict studies: a sense where the dictionary marks one, an entry where it does not
/// (`dev-docs/study-unit.md` §3). One kind of item with an optional sense, not two kinds of row —
/// which rung it stands on is visible from `senseKey` and `senseKeyKind`, so a card can always say
/// how precisely it knows what it is testing.
///
/// The dictionary is part of the key because an entry id is only unique *within* a dictionary —
/// asserted against the live dictionaries, not assumed.
public struct StudyItem: Codable, Sendable, Equatable, Hashable {
    /// `DictionaryIdentity.key`: the bundle identifier, or the display name marked as such.
    public let dictionary: String
    public let entryID: String
    /// Nil means "this entry, sense unresolved" — the word rung, reached honestly.
    public let senseKey: String?
    public let senseKeyKind: SenseKeyKind

    public init(dictionary: String, entryID: String, senseKey: String?, senseKeyKind: SenseKeyKind) {
        self.dictionary = dictionary
        self.entryID = entryID
        self.senseKey = senseKey
        self.senseKeyKind = senseKeyKind
    }

    /// Which rung of `study-unit.md` §3 this item stands on.
    public var rung: Rung { senseKey == nil ? .entry : .sense }

    public enum Rung: String, Codable, Sendable {
        /// Keyed to one sense of one entry.
        case sense
        /// Keyed to the entry alone — which still separates *fine* the penalty from *fine* the
        /// adjective, and is 100% available across every installed dictionary.
        case entry
    }
}

/// How a sense came to be the one recorded. A sense the model picked is a hypothesis; one the
/// reader tapped is a fact. **They must never merge in the ledger** (`dev-docs/study-unit.md` §5.2).
public enum SenseChoice: String, Codable, Sendable, CaseIterable {
    /// The reader tapped it.
    case reader
    /// The sense selector proposed it. A card built on this says so.
    case model
    /// The entry has exactly one sense, so nothing was chosen and nothing can be wrong.
    case onlySense
}

/// One meeting with one sense, hung off the lookup that produced it — a sense is always an
/// encounter, never a standalone fact (`dev-docs/study-unit.md` §5.2).
public struct SenseEncounter: Sendable, Equatable {
    public let dictionary: DictionaryIdentity
    /// Required: the entry *is* the homograph distinction.
    public let entryID: String
    /// Nil means "this entry, sense unresolved".
    public let senseKey: String?
    public let senseKeyKind: SenseKeyKind
    /// Which block and which ordinal — a bare ordinal is meaningless, because numbering restarts
    /// per part-of-speech block.
    public let sensePath: SensePath?
    /// "Sense 47 of 49" needs both halves; this is the second. It also gives word coverage —
    /// "you have met 3 of 49".
    public let entrySenseCount: Int
    /// A hash of the sense's text: under a position key, the only way to notice an Apple content
    /// update moving the sense rather than silently re-pointing the reader's history.
    public let senseHash: String?
    /// A short snapshot of the sense, so the ledger stays readable when a dictionary is updated or
    /// removed. **Local only — never shipped, published or sent to a remote service.**
    public let gloss: String?
    /// Nil when no sense was chosen at all: an entry-level encounter chose nothing, so there is
    /// nothing to attribute.
    public let chosenBy: SenseChoice?
    /// The sense often arrives after the lookup.
    public let chosenAt: Date?

    public init(
        dictionary: DictionaryIdentity, entryID: String, senseKey: String?, senseKeyKind: SenseKeyKind,
        sensePath: SensePath?, entrySenseCount: Int, senseHash: String?, gloss: String?,
        chosenBy: SenseChoice?, chosenAt: Date?
    ) {
        self.dictionary = dictionary
        self.entryID = entryID
        self.senseKey = senseKey
        self.senseKeyKind = senseKeyKind
        self.sensePath = sensePath
        self.entrySenseCount = entrySenseCount
        self.senseHash = senseHash
        self.gloss = gloss
        self.chosenBy = chosenBy
        self.chosenAt = chosenAt
    }

    /// The study item this encounter is a meeting with.
    public var studyItem: StudyItem {
        StudyItem(dictionary: dictionary.key, entryID: entryID, senseKey: senseKey, senseKeyKind: senseKeyKind)
    }
}

/// A sense met for the first time under a lemma the reader had already looked up — the query
/// `study-unit.md` §4 calls the point of the whole design, and the one a word-level unit cannot
/// express because the word is already marked known.
public struct NewlyMetSense: Sendable, Equatable {
    public let lemma: String
    public let dictionary: String
    public let entryID: String
    public let senseKey: String?
    public let gloss: String?
    public let metAt: Date

    public init(lemma: String, dictionary: String, entryID: String, senseKey: String?, gloss: String?, metAt: Date) {
        self.lemma = lemma
        self.dictionary = dictionary
        self.entryID = entryID
        self.senseKey = senseKey
        self.gloss = gloss
        self.metAt = metAt
    }
}

/// One earlier meeting with a word: when, and where. **Never what it meant.**
///
/// An earlier encounter says *you should know this*; an earlier gloss answers the question and
/// destroys the retrieval that makes the encounter worth anything (`feature-ledger-ux.md` C2).
/// There is deliberately no definition, gloss or sense text on this type — the omission is the
/// feature, so it is enforced by what the type cannot hold rather than by remembering not to show it.
public struct PriorEncounter: Sendable, Equatable {
    public let at: Date
    /// The app it was read in, by name where the ledger has one.
    public let `where`: String?
    /// The page or document title, where the app could say.
    public let title: String?

    public init(at: Date, where source: String?, title: String?) {
        self.at = at
        self.where = source
        self.title = title
    }
}

/// Everything the panel is allowed to remember about a word from before this lookup.
public struct PriorEncounters: Sendable, Equatable {
    /// Newest first.
    public let occasions: [PriorEncounter]
    /// The study items already met — so a sense the reader has read before can be marked in the
    /// entry (`feature-ledger-ux.md` C3), which no surveyed dictionary does.
    public let met: Set<StudyItem>

    public init(occasions: [PriorEncounter] = [], met: Set<StudyItem> = []) {
        self.occasions = occasions
        self.met = met
    }

    /// Which lookup this is, counting the one in hand: 1 on a first lookup.
    public var occasion: Int { occasions.count + 1 }

    /// **Absent on a first lookup** — no empty state, no "0 previous". A first lookup has nothing
    /// to remember, and an empty memory strip is noise on the commonest case (C4).
    public var isWorthShowing: Bool { occasion >= 2 }
}
