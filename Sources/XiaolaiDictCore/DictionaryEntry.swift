/// One dictionary's entry for a term, as Dictionary.app renders it.
public struct DictionaryEntry: Codable, Sendable, Equatable {
    /// How the entry's headword relates to the term that was looked up.
    public enum Match: String, Codable, Sendable {
        /// The headword is the term, up to case.
        case exact
        /// The headword is the term's dictionary form: "running" answered with "run".
        case dictionaryForm
        /// Another headword altogether — a near match. Said so in the panel, so it is never
        /// mistaken for the term's own entry.
        case otherHeadword
        /// The dictionary did not say which headword it answered with.
        case headwordUnknown
    }

    /// Which dictionary answered — by identifier where it has one, not only by the display name,
    /// which changes with the interface language.
    public let dictionary: DictionaryIdentity
    /// The headword the dictionary answered with; the term itself when it did not say (`match`
    /// is then `.headwordUnknown`).
    public let headword: String
    public let match: Match
    /// A complete XHTML document with the dictionary's own stylesheet inlined — renderable as is,
    /// with nothing to fetch from disk.
    public let html: String
    /// `d:entry`'s id — the homograph distinction that tells *fine* the penalty from *fine* the
    /// adjective, and the key a study card hangs on (`dev-docs/study-unit.md` §3). Nil when the
    /// document declared none: unknown, never guessed.
    public let entryID: String?
    /// The dictionary's own homograph number for this entry — NOAD's *fine¹ fine² fine³ fine⁴*.
    /// Nil where the dictionary does not number them; the panel then tells its entries apart by
    /// part of speech rather than by an ordinal XiaolaiDict made up.
    public let homograph: String?
    /// The entry's part-of-speech blocks and the senses in them. Empty for a dictionary with no
    /// sense structure — the sideloaded conversions whose sense boundary is a colour change — which
    /// is an entry-level entry, and says so.
    public let blocks: [SenseBlock]
    /// The pronunciations the entry prints (`d:prn`).
    public let pronunciations: [String]

    /// Every sense in the entry, across its blocks.
    public var senses: [DictionarySense] { blocks.flatMap(\.senses) }
    /// "Sense 47 of 49" needs both halves; this is the second.
    public var senseCount: Int { blocks.reduce(0) { $0 + $1.senses.count } }
    /// How precisely this entry's senses can be addressed at best — the quality signal a card must
    /// carry, so a positional claim never reads as a publisher's.
    public var senseKeyKind: SenseKeyKind { senses.map(\.keyKind).max() ?? SenseKeyKind.none }

    /// What a ledger row and a study card hang on — **not** `entryID`.
    ///
    /// Where the dictionary's ids are the publisher's, that id is the key. Where they are generated
    /// by whatever tool converted the bundle — every sideloaded conversion — they change on the
    /// reader's next import, so a ledger keyed to them survives only by luck
    /// (`dev-docs/dictionary-markup.md` §7). Those key by headword instead, marked `headword:` for
    /// the same reason `DictionaryIdentity.key` marks a display name: a row keyed by a headword must
    /// never be mistaken for one keyed by a publisher id, and a dictionary that later gains a bundle
    /// identifier must not silently merge with its own older rows. The homograph joins the key where
    /// the dictionary numbers them, because a headword alone merges *fine* the penalty with *fine*
    /// the adjective.
    ///
    /// Nil only where the ids *are* stable and this entry declared none. That is a malformed entry
    /// rather than a dictionary without ids, and the id was the thing separating the homographs —
    /// so there is nothing to fall back to. Unknown, never guessed.
    public var entryKey: String? {
        guard dictionary.hasStableEntryIDs else {
            guard let homograph, !homograph.isEmpty else { return "headword:\(headword)" }
            return "headword:\(headword)#\(homograph)"
        }
        return entryID
    }

    /// `term` is what was looked up; the match is worked out from it rather than asserted.
    ///
    /// `document` is `html` already parsed. It is passed in rather than parsed here because a
    /// 625 KB entry costs a quarter of a second to walk — measured on Longman's *hold* — and the
    /// service has already walked it once to check the styled form. One walk per record is the
    /// difference between a lookup inside its 1 s budget and one at twice it.
    public init(
        dictionary: DictionaryIdentity, headword: String?, lookedUp term: String, html: String,
        document: EntryDocument?
    ) {
        self.dictionary = dictionary
        self.headword = headword ?? term
        self.match = Self.match(of: headword, for: term)
        self.html = html
        self.entryID = document?.entryID
        self.homograph = document?.homograph
        self.blocks = document?.blocks ?? []
        self.pronunciations = document?.pronunciations ?? []
    }

    /// One entry per entry id, in the order the records arrived.
    ///
    /// A dictionary indexes one entry under several headwords, and
    /// `DCSCopyRecordsForSearchString` answers with a record for each — NOAD gives *cougher* two
    /// records, both `m_en_gbus0224890`, headed *cough* and *cougher*; the Writer's Thesaurus
    /// gives *run* two, both `t_en_gb0012791`, headed *run* and *-run*; 譯典通 gives 的 three,
    /// all `z_id009726`, one per reading. The documents are the same entry: for 的 byte-identical,
    /// for the others differing only in the `aria-label` naming the index form that matched.
    ///
    /// **Measured 2026-09-21 across a 300-word sweep: 14 of the 219 words that had entries.** This
    /// is not the several-records case the service exists to preserve — *fine* really is four
    /// entries in NOAD, each with its own id, and every one of them still reaches the reader. It
    /// is one entry arriving more than once, which every reader of an entry id reads as ambiguity:
    /// the panel drew the entry twice, `SenseResolver` refused a chosen sense whose key "two"
    /// entries held, and `PrimaryDictionary.encounter` recorded nothing because the primary had
    /// answered with more than one entry. A reader whose primary is the thesaurus got no mark and
    /// no ledger row for *run*, with no reason shown.
    ///
    /// The copy kept is the one whose headword best answers the term, not the first: NOAD lists
    /// *cough* before *cougher*, and titling the panel *cough* names a word the reader did not
    /// read. It keeps the position of the first copy, so a dictionary's entries stay contiguous
    /// and in the reader's order. An entry that declared no id is unknown rather than equal to
    /// every other unknown, and is never merged.
    public static func collapsingRepeatedRecords(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        var kept: [DictionaryEntry] = []
        var placeOf: [RecordIdentity: Int] = [:]
        for entry in entries {
            guard let id = entry.entryID else {
                kept.append(entry)
                continue
            }
            let identity = RecordIdentity(dictionary: entry.dictionary, entryID: id)
            guard let place = placeOf[identity] else {
                placeOf[identity] = kept.count
                kept.append(entry)
                continue
            }
            if entry.answersTheTerm < kept[place].answersTheTerm { kept[place] = entry }
        }
        return kept
    }

    /// Which entry a record is a copy of. The whole `DictionaryIdentity`, not its `key`: an id is
    /// only an identity inside one version of one dictionary, and two records that reach this from
    /// different versions are not copies of each other. A typed key rather than the two fields
    /// joined by a separator, so no id containing that separator can collide with another pair.
    private struct RecordIdentity: Hashable {
        let dictionary: DictionaryIdentity
        let entryID: String
    }

    /// How well this record's headword answers the term that was looked up, smallest best. Used
    /// only to choose between records of one entry, where the content is the same and the headword
    /// is the whole difference.
    private var answersTheTerm: Int {
        switch match {
        case .exact: 0
        case .dictionaryForm: 1
        case .otherHeadword: 2
        case .headwordUnknown: 3
        }
    }

    private static func match(of headword: String?, for term: String) -> Match {
        guard let headword else { return .headwordUnknown }
        if term.lowercased() == headword.lowercased() { return .exact }
        // Only a differing headword needs the tagger.
        return Lemmatizer.lemma(of: term, in: nil).text == Lemmatizer.canonical(headword) ? .dictionaryForm : .otherHeadword
    }
}

/// What the app asks the dictionary service for. An envelope rather than a bare `LookupRequest`,
/// because the menu needs to list the enabled dictionaries and say what each can key, and that is
/// not a lookup.
public enum ServiceRequest: Codable, Sendable, Equatable {
    case lookup(LookupRequest)
    /// Every enabled dictionary, in the reader's order, with what each can address.
    case dictionaries
}

/// What the dictionary service answers with. Typed per request, so a reply can never be read as
/// the answer to a different question.
public enum ServiceReply: Codable, Sendable, Equatable {
    case lookup(LookupReply)
    case dictionaries([DictionaryCapability])
}

/// One enabled dictionary and the finest rung it can key a study item to — which is what makes
/// "choosing this one costs you sense-level study" sayable in the menu before the reader chooses.
public struct DictionaryCapability: Codable, Sendable, Equatable {
    public let identity: DictionaryIdentity
    /// The best rung reached on the words probed. `.none` means the dictionary marks senses with
    /// nothing a parser can key to, so it can only ever be studied at entry level.
    public let senseKeyKind: SenseKeyKind
    /// False when no probe word was found in this dictionary at all, so `senseKeyKind` is a floor
    /// rather than a measurement — said plainly instead of passed off as a finding.
    public let probed: Bool

    public init(identity: DictionaryIdentity, senseKeyKind: SenseKeyKind, probed: Bool) {
        self.identity = identity
        self.senseKeyKind = senseKeyKind
        self.probed = probed
    }

    /// What the menu prints beside the dictionary's name.
    public var note: String {
        guard probed else { return "not yet known" }
        switch senseKeyKind {
        case .publisher: return "senses"
        case .position: return "senses, by position"
        case .none: return "whole entries only"
        }
    }
}

/// App → dictionary service.
public struct LookupRequest: Codable, Sendable, Equatable {
    /// Longer than this, in characters, is a passage, not a word or phrase to look up. The app
    /// refuses such a selection; the service refuses such a request, because it cannot know that
    /// every caller did.
    public static let maximumLength = 80

    public let term: String

    public init(term: String) {
        self.term = term
    }
}

/// Dictionary service → app. A failure is a value rather than a dropped connection, so the app
/// can tell "the service answered, and found nothing" from "the service could not answer".
public enum LookupReply: Codable, Sendable, Equatable {
    /// At least one dictionary has the term. `unreadable` names dictionaries that also had it but
    /// whose entry could not be read — reported, not silently dropped.
    case entries(NonEmpty<DictionaryEntry>, unreadable: [String])
    /// No active dictionary has the term.
    case notFound
    case failure(LookupFailure)
}

/// Why the service could not answer. Typed, so a caller can treat a bad request differently from a
/// broken private API; `description` is the text for the reader.
public enum LookupFailure: Codable, Sendable, Equatable, CustomStringConvertible {
    /// The request itself was unusable: blank, or longer than `LookupRequest.maximumLength`.
    case invalidRequest(String)
    /// DictionaryServices, or one of its private symbols, is missing or answered with something
    /// this code does not understand — a macOS update changed it.
    case dictionaryServicesUnavailable(String)
    /// Dictionaries had the term, but not one of their entries could be read.
    case unreadableEntries(dictionaries: [String])

    public var description: String {
        switch self {
        case .invalidRequest(let why): "invalid request: \(why)"
        case .dictionaryServicesUnavailable(let why): "DictionaryServices unavailable: \(why)"
        case .unreadableEntries(let names): "entries found but unreadable in \(names.joined(separator: ", "))"
        }
    }
}
