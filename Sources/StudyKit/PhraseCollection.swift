import DictionaryModel
import Foundation

/// **A phrase the reader asked to keep as a card** — the owner's decision of 2026-10-05, ADR-0049.
///
/// Until then a phrase was explained and never studied: the inventory reads a phrase's meaning and keys
/// nothing. The reader may now press *Save This Phrase*, and that one gesture is the **only** way a phrase
/// card is made — never automatically, never inferred from a lookup, never from the sense ladder.
///
/// **And one phrase is one card.** A phrase with an entry of its own can be a card already as that entry's
/// meaning — automatic keeping keeps the sense the ladder chose, and the ladder may choose the phrase's
/// (ADR-0028). That is an entry's sense, never a phrase card, and it stands for the phrase: a save then
/// writes nothing, and automatic keeping keeps no meaning of the own entry of a phrase already saved.
///
/// **What it is keyed by** is ADR-0029's: the study dictionary and the dictionary's own spelling, issued by
/// `PhraseInventory` — `.phrase(dictionary:text:)` under `KeyIssuer.inventory` — and never the parent word's
/// entry id, which is already the word's own note. The filings are where the meaning was found, recorded as
/// `StudyLocator`s; evidence, never a key.
public struct PhraseCollection: Sendable, Equatable {
    /// The study dictionary the card belongs to: its key is the note's namespace, and its version is
    /// stamped on the answer.
    public let dictionary: DictionaryIdentity
    /// The dictionary's own spelling, **exactly as the phrase inventory files it** — the note's identity.
    /// Never the reader's text and never a normalised guess: either would make one phrase two notes.
    public let spelling: String
    /// What the card reveals: the meaning the card showed, **where it was this dictionary's**. Nil where it
    /// showed none of this dictionary's, and the card waits for the reader's own words rather than carrying
    /// another dictionary's text under this one's name.
    public let answer: String?
    /// Where this dictionary files the phrase — **this dictionary's filings only**, chosen here so no caller
    /// can attach another's parent and block to a card they do not describe. Empty for a phrase with an
    /// entry of its own, which has no block to record.
    public let filings: [PhraseFiling]
    /// **This dictionary's own entries for the phrase**, by `DictionaryEntry.entryKey` — empty for a phrase
    /// filed inside another word's. Never a key of this note: what lets a save see that a meaning of one of
    /// these entries is already a card, so one phrase is never two (`collectPhrase`).
    public let ownEntryKeys: [String]
    /// Whether the card drew the phrase or its meaning as a guess: an inferred split, or a meaning the
    /// selector proposed. **The card's standing is what is saved** (ADR-0030), so a guess is saved
    /// unconfirmed and is not asked until the reader agrees.
    public let isProposal: Bool

    /// `ownEntryKeys` has no default: a caller that left it out would save a second card beside a phrase's
    /// own-entry meaning without anything noticing.
    public init(dictionary: DictionaryIdentity, spelling: String, answer: String?, filings: [PhraseFiling],
                ownEntryKeys: [String], isProposal: Bool) {
        self.dictionary = dictionary
        self.spelling = spelling
        self.answer = answer
        self.filings = filings.filter { $0.dictionary.key == dictionary.key }
        self.ownEntryKeys = ownEntryKeys
        self.isProposal = isProposal
    }

    /// The note this saves to.
    public var target: StudyTarget { .phrase(dictionary: dictionary.key, text: spelling) }

    /// **Whether `spelling` is one the phrase inventory could have issued.** It files phrases lowercased and
    /// multi-word only, trims its labels, and skips any key holding a tab or a newline
    /// (`PhraseSpans.keys`, `PhraseInventory.subEntries`, `PhraseInventory.encoded`). Anything else is the
    /// reader's text or a normalised guess — and keyed by it, the same phrase saved twice is two notes.
    ///
    /// **A run of spaces inside is allowed, because the inventory issues them**: measured 2026-10-05 over
    /// the three stored inventories on the development Mac, 71 of 115,128 spellings hold one — `a   and a
    /// half`, a key with its slot word missing — and this rule refuses none of the 115,128.
    static func isInventorySpelling(_ spelling: String) -> Bool {
        spelling.split(separator: " ").count > 1
            && spelling.first != " " && spelling.last != " "
            && !spelling.contains { $0.isWhitespace && $0 != " " }
            && spelling == spelling.lowercased()
    }
}

/// What saving a phrase did. **Four answers**, because a second save is ordinary and says so rather than
/// failing, a phrase already a card as its entry's meaning is one card, not two, and a reading the reader
/// put away is not an error either.
public enum PhraseCollectOutcome: Sendable, Equatable {
    /// A new note, with its card.
    case collected(StudyNote)
    /// The phrase was saved already: the same note, now evidenced by this reading too.
    case alreadyCollected(StudyNote)
    /// **The phrase has an entry of its own here, and a meaning of that entry is a card already** — kept
    /// automatically when the ladder read the sentence as the phrase (ADR-0028), or saved from a lookup of
    /// the phrase itself. That card stands for the phrase, and nothing is written: not a second card, and
    /// not a link, which would make the phrase's meaning the meaning this reading's word is kept under.
    case savedAsItsEntry(StudyNote)
    /// The reading was discarded, and nothing was written — the rule `keep` follows.
    case readingDiscarded

    /// The note the save reached, where it reached one.
    public var note: StudyNote? {
        switch self {
        case .collected(let note), .alreadyCollected(let note), .savedAsItsEntry(let note): note
        case .readingDiscarded: nil
        }
    }
}

extension Ledger {
    /// **Saves a phrase as a card, or answers with the one already saved** — one savepoint, idempotent by
    /// identity, loud on a row it cannot read.
    ///
    /// - The note is `.phrase(dictionary:text:)` under `KeyIssuer.inventory`, in `language`; the card is
    ///   created `new` with it. Saving is not a review.
    /// - It is explicit (the keep metadata says `manual`), so tidying the reading leaves it.
    /// - The answer is the publisher's, `origin: .dictionary` — local only, never exported (ADR-0036) — and
    ///   **the first answer stays**: a second save does not rewrite what the card reveals.
    /// - Every filing is recorded once as a `StudyLocator`, evidence of where the meaning was found.
    /// - A proposal is saved unconfirmed; a plain save confirms, which is what agreeing with a proposal is.
    /// - The reading is linked, never written: a phrase saved from a lookup is a note, not a new reading.
    /// - **One phrase, one card**: where no phrase card exists yet and a meaning of one of the phrase's own
    ///   entries here is a card already, that card stands for it and nothing is written (`savedAsItsEntry`).
    @discardableResult
    public func collectPhrase(_ phrase: PhraseCollection, language: String, lookupID: Int,
                              at when: Date) throws -> PhraseCollectOutcome {
        guard PhraseCollection.isInventorySpelling(phrase.spelling) else {
            throw LedgerError.notAnInventorySpelling(phrase.spelling)
        }
        switch try disposition(ofLookup: lookupID) {
        case .kept?: break
        case .discarded?: return .readingDiscarded
        case nil: throw LedgerError.lookupGone(lookupID)
        }
        var outcome: PhraseCollectOutcome?
        try inOneTransaction("collectPhrase") {
            // Decoded, so a damaged row throws here rather than reading as no note and gaining a twin.
            let existing = try note(for: phrase.target, issuer: .inventory, language: language)
            if existing == nil, let standing = try ownEntryCard(of: phrase, language: language) {
                outcome = .savedAsItsEntry(standing)
                return
            }
            let note = try enroll(
                phrase.target, issuer: .inventory, language: language,
                chosenBy: phrase.isProposal ? .model : .reader,
                answer: phrase.answer.map {
                    StudyAnswer(origin: .dictionary, text: $0, dictionaryVersion: phrase.dictionary.version)
                },
                lookupID: lookupID, at: when, explicitly: true)
            if existing == nil {
                try run("UPDATE study_keep_metadata SET source = 'manual', creation_lookup = ? WHERE note_id = ?",
                        bind: [.integer(lookupID), .text(note.id.uuidString)]) { _ in }
            }
            if !phrase.isProposal { try confirm(noteID: note.id, at: when) }
            try record(phrase.filings, asLocatorsOf: note.id, at: when)
            guard let stored = try self.note(for: phrase.target, issuer: .inventory, language: language) else {
                throw LedgerError.corruptRow("study_notes \(note.id.uuidString)")
            }
            outcome = existing == nil ? .collected(stored) : .alreadyCollected(stored)
        }
        guard let outcome else { throw LedgerError.corruptRow("study_notes \(phrase.spelling)") }
        return outcome
    }

    /// **A meaning of one of the phrase's own entries that is a card already**, oldest first — a live note on
    /// that entry in this dictionary and language, at the sense rung or the entry's. The entry is the one the
    /// reply named as the phrase's own (ADR-0028), so this is an observed relation, not an inferred merge
    /// (ADR-0029): no note is rewritten, and none is made.
    ///
    /// **Every row on those entries is decoded before it is judged**, so one this build cannot read throws
    /// rather than reading as no card and gaining a twin; the issuer and the rung are asked of the decoded
    /// note, never filtered in SQL, where a damaged value would read as "not this kind".
    func ownEntryCard(of phrase: PhraseCollection, language: String) throws -> StudyNote? {
        guard !phrase.ownEntryKeys.isEmpty else { return nil }
        return try notes(
            where: "WHERE dictionary = ? AND language = ? AND entry_id IN (SELECT value FROM json_each(?))",
            bind: [.text(phrase.dictionary.key), .text(language), .text(Self.jsonArray(of: phrase.ownEntryKeys))]
        ).first { note in
            switch note.target {
            case .sense, .entry: note.issuer == .live
            case .phrase, .custom: false
            }
        }
    }

    /// **The card the reader saved for a phrase, if they did** — what automatic keeping asks before it keeps
    /// a meaning of that phrase's own entry, so the phrase is not made a second card without a gesture.
    public func phraseCard(_ spelling: String, dictionary: String, language: String) throws -> StudyNote? {
        try note(for: .phrase(dictionary: dictionary, text: spelling), issuer: .inventory, language: language)
    }

    /// Each filing once: a second save of the same phrase from the same build records nothing new, and one
    /// from a re-mastered dictionary records where the meaning is now.
    private func record(_ filings: [PhraseFiling], asLocatorsOf noteID: UUID, at when: Date) throws {
        var recorded = try locators(of: noteID)
        for filing in filings {
            let already = recorded.contains {
                $0.contentVersion == filing.contentVersion && $0.formatVersion == filing.formatVersion
                    && $0.parentEntryID == filing.parentEntryID && $0.blockID == filing.blockID
            }
            guard !already else { continue }
            let locator = StudyLocator(
                noteID: noteID, contentVersion: filing.contentVersion, formatVersion: filing.formatVersion,
                parentEntryID: filing.parentEntryID, blockID: filing.blockID, definitions: filing.definitions,
                recordedAt: when)
            try add(locator)
            recorded.append(locator)
        }
    }
}
