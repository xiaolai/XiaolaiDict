import DictionaryModel
import Foundation

/// **Which extractor produced the identifiers a note is keyed by.**
///
/// A sense key from the index and a sense key from the live path are not interchangeable, and a phrase's
/// parent and block ids come from a third reader again. Two of them in one ledger, indistinguishable,
/// orphans every study item the reader has the first time an extractor is swapped — and the provenance of
/// a key already written cannot be recovered afterwards, which is why this is stored from the first
/// migration rather than added when it is first needed (ADR-0028).
///
/// **It is part of the identity, not a note beside it.** Recording the issuer while comparing addresses
/// without it is the same defect wearing a label: the same `(dictionary, entry, sense)` string from two
/// issuers would resolve to one target and silently inherit its schedule. Two issuers make two targets
/// until an equivalence is *measured*; a duplicate is visible and repairable, a false merge is neither.
public enum KeyIssuer: String, Codable, Sendable, CaseIterable {
    /// The private DictionaryServices path — `DictionaryBridge`, through `EntryDocument`.
    case live
    /// `DictionaryIndex`, built by `EntryIndexer`.
    case index
    /// `PhraseInventory`'s body walk, which is the only reader of a sub-entry's parent and block ids.
    case inventory
}

/// What one note is *about*: the learning target, as something that can be compared.
///
/// Three rungs, and the third is new. `sense` and `entry` are `study-unit.md`'s two layers. `phrase` exists
/// because a phrase filed inside another word's entry has no identity among the other two: its only
/// available key was its parent's entry id, **which is already the identity of the parent word at the entry
/// rung**, so enrolling `take something into account` and the word *account* would have collided.
public enum StudyTarget: Sendable, Equatable, Hashable {
    /// One sense of one entry: the finest rung, and only where the dictionary keys its senses.
    case sense(dictionary: String, entryID: String, senseKey: String, senseKeyKind: SenseKeyKind)
    /// One entry, sense unresolved — which still separates *fine* the penalty from *fine* the adjective,
    /// and is what every dictionary that marks no senses can offer.
    case entry(dictionary: String, entryID: String)
    /// A phrase filed inside another word's entry, keyed by the dictionary's own spelling of it.
    ///
    /// **The text is the label, and the locators are evidence.** `StudyLocator` records where the meaning
    /// was found — parent, block, content version, extraction version — and a phrase may have several.
    /// None of them is a sense key and none may be stored as one.
    case phrase(dictionary: String, text: String)
    /// Something the reader wrote themselves (C07): a word, a phrase, a collocation the dictionary
    /// does not file.
    ///
    /// **A kind of its own, not a `phrase` with no locators.** A phrase is the publisher's spelling
    /// and can be traced to their markup; this is the reader's, and nothing about it is a claim about
    /// a dictionary. Sharing a kind would make an invention indistinguishable from a citation the
    /// moment anything reads the row.
    ///
    /// Still namespaced by dictionary, because study state belongs to one: a custom card made while
    /// studying from NOAD is part of that collection and does not follow the reader elsewhere.
    case custom(dictionary: String, text: String)

    /// The dictionary this target belongs to. Study state belongs to one dictionary: switching the primary
    /// starts it over, and two dictionaries' senses are never the same target.
    public var dictionary: String {
        switch self {
        case .sense(let dictionary, _, _, _), .entry(let dictionary, _), .phrase(let dictionary, _),
             .custom(let dictionary, _):
            dictionary
        }
    }

    /// The stored discriminator. Its spelling is a schema value: changing it re-keys every row.
    /// The words this target *is*, where it has them of its own: a phrase's own spelling, a
    /// custom card's cue. Nil for a sense or an entry, whose word comes from the reading.
    ///
    /// **A note without a lookup still has a name.** Everything on-screen derived the word from
    /// the newest reading, so a custom card — which needs no lookup at all (C07) — drew as an
    /// empty row in the library and an empty label in the inspector.
    public var ownText: String? {
        switch self {
        case .phrase(_, let text), .custom(_, let text): text
        case .sense, .entry: nil
        }
    }

    public var kind: Kind {
        switch self {
        case .sense: .sense
        case .entry: .entry
        case .phrase: .phrase
        case .custom: .custom
        }
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case sense, entry, phrase, custom
    }

    /// The `StudyItem` this target is, for the two rungs that have one.
    ///
    /// Nil for a phrase, and that is the point: `StudyItem` cannot name one without colliding with its
    /// parent word, which is why `StudyTarget` exists. A caller that wants "the study items the reader has
    /// met" is asking about senses and entries.
    public var item: StudyItem? {
        switch self {
        case .sense(let dictionary, let entryID, let senseKey, let kind):
            StudyItem(dictionary: dictionary, entryID: entryID, senseKey: senseKey, senseKeyKind: kind)
        case .entry(let dictionary, let entryID):
            StudyItem(dictionary: dictionary, entryID: entryID, senseKey: nil, senseKeyKind: .none)
        case .phrase, .custom:
            nil
        }
    }
}

/// Whether the reader wants to study this target. **Not whether it is ready, and not where its schedule
/// has got to** — one status enum mixing those three answers cannot express "enrolled but unreviewable".
public enum StudyEnrollment: String, Codable, Sendable, CaseIterable {
    /// Suggested by the reading, not yet taken up. Carries no obligation and no schedule.
    case candidate
    /// The reader asked to study it.
    case active
    /// The reader said they already know it, or does not want it suggested again. Reversible, and it
    /// suppresses suggestions without erasing any history.
    case ignored
    /// Kept with its evidence and its schedule, out of the way.
    case archived
}

/// Whether the note's cue, identity and answer can support a graded question.
///
/// **Separate from enrollment, because active does not imply gradable.** A sense whose key no longer
/// resolves, an entry-level draft with no reader-confirmed answer, and a note whose reading the reader has
/// deleted are all enrolled and none may be graded — and a card that grades one of them teaches the reader
/// something wrong.
///
/// **Derived, never stored.** Schema 8 kept it in a column and that was wrong: every fact it rests on
/// changes somewhere else. Deleting the last lookup that evidences a note leaves it with no cue, and a
/// stored value would go on saying `ready` with nothing having touched the row — the stale-derived-value
/// failure this project spends its time removing. `Ledger.readiness(of:)` computes it from the facts.
public enum StudyReadiness: String, Codable, Sendable, CaseIterable {
    case ready
    /// A model proposed the sense and the reader has not accepted it. A proposal is a hypothesis; grading
    /// one records the reader's memory of a guess.
    case needsConfirmation
    /// The identity or the answer stopped resolving — a dictionary removed, a content update that moved a
    /// positional sense, an extractor whose issuer no longer matches.
    case needsRepair
}

/// One learning target the reader keeps, with what it is about and whether it can be asked.
///
/// **The id is internal and stable; the target is how it is found.** Keying rows by the target directly
/// would mean a re-mastered dictionary renames every row that references it, and the reader's own history
/// would move with the publisher's spelling.
public struct StudyNote: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let target: StudyTarget
    /// Which extractor produced the identifiers in `target`.
    public let issuer: KeyIssuer
    /// The reader language this target was enrolled under. **An explicit `unknown`, never a guess**: a row
    /// whose language was not recorded must not merge with rows for a language someone inferred later.
    public let language: String
    public let enrollment: StudyEnrollment
    /// When the reader accepted this target as the one they met, where they have.
    ///
    /// **Nil is a model's proposal nobody has agreed with.** A sense the selector picked is a hypothesis;
    /// grading one records the reader's memory of a guess. A sense the reader tapped, and an entry with
    /// only one sense, are confirmed as they are enrolled — there was nothing to doubt.
    public let confirmedAt: Date?
    public let createdAt: Date

    /// The sentinel for a language that was not recorded. A real value, because SQLite NULL does not
    /// participate in uniqueness: two notes with an unknown language and the same target must collide.
    public static let unknownLanguage = "unknown"

    public init(id: UUID = UUID(), target: StudyTarget, issuer: KeyIssuer,
                language: String = StudyNote.unknownLanguage,
                enrollment: StudyEnrollment = .candidate, confirmedAt: Date? = nil,
                createdAt: Date) {
        self.id = id
        self.target = target
        self.issuer = issuer
        self.language = language
        self.enrollment = enrollment
        self.confirmedAt = confirmedAt
        self.createdAt = createdAt
    }
}

/// Where a phrase note's meaning was found, and in which build of which dictionary.
///
/// **An occurrence, not a name.** Apple re-masters these: a block id is where a definition sat in the bytes
/// this was read from, so it is stored beside the `contentVersion` it was true for and the
/// `PhraseInventory.formatVersion` that read it — the extraction can change while the dictionary's bytes do
/// not, and `contentVersion` cannot see that.
///
/// A note may have several: `blow a fuse` is filed under *blow* and under *fuse*, meaning different things.
/// Keeping both is what lets a later reading prefer the one whose parent answered the reader's lookup.
public struct StudyLocator: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let noteID: UUID
    /// `DictionaryBundle.contentVersion()` — which build of the dictionary this was read from.
    public let contentVersion: String
    /// `PhraseInventory.formatVersion` — which extraction read it.
    public let formatVersion: String
    /// The entry the block is filed in.
    public let parentEntryID: String
    /// The block's own publisher id, empty where the dictionary marks none.
    public let blockID: String
    /// The definitions as they read when the reader enrolled. **Local only — never shipped, published or
    /// sent to a remote service**, the same rule `SenseEncounter.gloss` carries.
    public let definitions: [String]
    public let recordedAt: Date

    public init(id: UUID = UUID(), noteID: UUID, contentVersion: String, formatVersion: String,
                parentEntryID: String, blockID: String, definitions: [String], recordedAt: Date) {
        self.id = id
        self.noteID = noteID
        self.contentVersion = contentVersion
        self.formatVersion = formatVersion
        self.parentEntryID = parentEntryID
        self.blockID = blockID
        self.definitions = definitions
        self.recordedAt = recordedAt
    }
}

/// What the card reveals, and where the words came from.
///
/// **The origin is load-bearing, not provenance decoration.** A dictionary's own text is the publisher's
/// and is local-only — never exported, never sent to a remote model — while the reader's own words are
/// theirs to take anywhere. And an entry-rung target carrying the dictionary's text is not yet a
/// sense-specific answer: the whole entry is too broad for "what does this mean here?", so it waits for
/// the reader to narrow it.
public struct StudyAnswer: Sendable, Equatable {
    public enum Origin: String, Codable, Sendable, CaseIterable {
        /// A snapshot of what the dictionary said. **Local only**, the same rule `SenseEncounter.gloss`
        /// carries.
        case dictionary
        /// The reader's own words.
        case reader
    }

    public let origin: Origin
    public let text: String
    /// Which build of the dictionary the text was taken from, where it came from one.
    public let dictionaryVersion: String?
    /// The sense's own text hash at enrollment. **What notices a content update moving the sense** under
    /// a positional key, rather than silently re-pointing the reader's card at a different meaning.
    public let senseHash: String?

    public init(origin: Origin, text: String, dictionaryVersion: String? = nil,
                senseHash: String? = nil) {
        self.origin = origin
        self.text = text
        self.dictionaryVersion = dictionaryVersion
        self.senseHash = senseHash
    }

    /// Whether there is anything to reveal. Whitespace is nothing: a card whose back is blank is the
    /// "empty graded answer" the feature ledger's K04 refuses.
    public var isUsable: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension StudyReadiness {
    /// The facts a verdict is made of, gathered wherever the caller can gather them.
    ///
    /// **Split from the decision on purpose.** The verdict is wanted in three places — one note at a
    /// time, a page of a hundred in the library, and a SQL predicate the queue cannot leave to Swift —
    /// and three copies of the *rule* is how they come to disagree. The rule is `of(_:)`; the
    /// gathering is whatever each caller can afford. The SQL spelling is the one copy that cannot be
    /// avoided, and `thequeueAndReadinessAgree` is what holds it to this.
    public struct Facts: Sendable, Equatable {
        public let isConfirmed: Bool
        public let hasUsableAnswer: Bool
        /// Whether the answer is the dictionary's text rather than the reader's own.
        public let answerIsPublishers: Bool
        public let isEntryRung: Bool
        /// Whether any reading still evidences it. A note whose readings the reader deleted has no cue.
        public let hasReading: Bool
        /// Whether a reading is *required*. **False for a card the reader wrote themselves** — its
        /// cue is their own words, and demanding a lookup for it would make C07 unusable the moment
        /// it was built.
        public let needsReading: Bool
        /// Whether the sense's text has changed under a stored key. **Only ever true on evidence**: a
        /// dictionary that could not be asked has said nothing.
        public let senseMoved: Bool

        public init(isConfirmed: Bool, hasUsableAnswer: Bool, answerIsPublishers: Bool,
                    isEntryRung: Bool, hasReading: Bool, senseMoved: Bool,
                    needsReading: Bool = true) {
            self.isConfirmed = isConfirmed
            self.hasUsableAnswer = hasUsableAnswer
            self.answerIsPublishers = answerIsPublishers
            self.isEntryRung = isEntryRung
            self.hasReading = hasReading
            self.senseMoved = senseMoved
            self.needsReading = needsReading
        }
    }

    /// The one place the verdict is decided.
    public static func of(_ facts: Facts) -> StudyReadiness {
        guard facts.hasUsableAnswer else { return .needsRepair }
        if facts.senseMoved { return .needsRepair }
        guard facts.hasReading || !facts.needsReading else { return .needsRepair }
        guard facts.isConfirmed else { return .needsConfirmation }
        // The dictionary's whole entry is too broad for "what does this mean here?", so an entry rung
        // carrying it waits for the reader to narrow it.
        if facts.isEntryRung, facts.answerIsPublishers { return .needsConfirmation }
        return .ready
    }
}
