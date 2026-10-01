import DictionaryModel
import Foundation
import SQLite3

/// **Schema 8 — the study system's durable entities.** WI-001 of the card plan: what a target *is*, where
/// its meaning was found, and which lookups evidence it. Nothing here schedules, grades or presents
/// anything; a card and a review event arrive with the scheduler that writes them, because a table nothing
/// writes is a model nothing calls.
///
/// **Identity is the part that cannot be repaired later**, which is why it is the part the schema enforces
/// rather than the caller. Three properties, each of which was a defect waiting in the first draft:
///
/// - **Every column in the uniqueness key is `NOT NULL` with an explicit sentinel.** SQLite NULL never
///   equals NULL, so a nullable column in a unique index admits unlimited duplicates that all look
///   distinct. An unrecorded language is the string `unknown`, and a field a branch does not use is `''`.
/// - **Each branch has a `CHECK` saying which fields it uses.** A partial index on `target_kind = 'sense'`
///   constrains no column by itself: two sense rows with no sense key are, to that index, two different
///   things. The checks are what make the uniqueness mean what it says.
/// - **The issuer is part of the key, not an annotation beside it.** Recording which extractor produced a
///   key while comparing keys without it would let the same address string from two extractors resolve to
///   one target and inherit its schedule — the silent merge the project's own rule says orphans every
///   study item. Two issuers make two visible notes until an equivalence is measured (ADR-0028).
extension Ledger {
    /// The tables, exactly as schema 8 creates them.
    ///
    /// Kept as one literal so the migration and any future rebuild cannot drift apart, and so the shape
    /// can be read in one place rather than assembled from a diff.
    static let studySchema = """
        CREATE TABLE study_notes (
            id              TEXT PRIMARY KEY,
            -- 'sense' | 'entry' | 'phrase' | 'custom'. The last is the reader's own words and is a
            -- kind of its own, so an invention is never indistinguishable from a citation.
            target_kind     TEXT NOT NULL,
            -- Which extractor produced the identifiers below. Part of the identity, not a note beside it.
            issuer          TEXT NOT NULL,
            -- The reader language namespace. `unknown` is a real value: NULL would defeat the uniqueness.
            language        TEXT NOT NULL,
            dictionary      TEXT NOT NULL,
            -- '' where the branch does not use the field, never NULL, for the same reason.
            entry_id        TEXT NOT NULL,
            sense_key       TEXT NOT NULL,
            sense_key_kind  TEXT NOT NULL,
            phrase_text     TEXT NOT NULL,
            enrollment      TEXT NOT NULL,
            -- When the reader accepted this as the target they met. NULL is a proposal nobody has
            -- agreed with. **Readiness is not stored**: every fact it rests on changes elsewhere.
            confirmed_at    REAL,
            created_at      REAL NOT NULL,
            CHECK (target_kind IN ('sense', 'entry', 'phrase', 'custom')),
            CHECK (issuer IN ('live', 'index', 'inventory')),
            CHECK (enrollment IN ('candidate', 'active', 'ignored', 'archived')),
            CHECK (language <> '' AND dictionary <> ''),
            -- The branch shapes. Each says what its kind uses *and* what it must leave empty, so a row
            -- cannot carry a field belonging to another branch and slip past that branch's uniqueness.
            CHECK (
                (target_kind = 'sense'
                    AND entry_id <> '' AND sense_key <> '' AND sense_key_kind <> '' AND phrase_text = '')
             OR (target_kind = 'entry'
                    AND entry_id <> '' AND sense_key = '' AND phrase_text = '')
             OR (target_kind = 'phrase'
                    AND entry_id = '' AND sense_key = '' AND sense_key_kind = '' AND phrase_text <> '')
             OR (target_kind = 'custom'
                    AND entry_id = '' AND sense_key = '' AND sense_key_kind = '' AND phrase_text <> '')
            )
        );
        -- One note per target, per issuer, per language namespace. Every column is NOT NULL, so this is a
        -- plain unique index rather than four partial ones — there is no NULL left for it to trip over.
        CREATE UNIQUE INDEX study_notes_identity ON study_notes (
            target_kind, issuer, language, dictionary, entry_id, sense_key, sense_key_kind, phrase_text
        );
        CREATE INDEX study_notes_by_dictionary ON study_notes (dictionary, enrollment);

        -- Where a meaning was found, in which build, read by which extraction. An occurrence, never a
        -- name: a note may have several, and none of them is a sense key.
        CREATE TABLE study_locators (
            id              TEXT PRIMARY KEY,
            note_id         TEXT NOT NULL REFERENCES study_notes (id) ON DELETE CASCADE,
            content_version TEXT NOT NULL,
            format_version  TEXT NOT NULL,
            parent_entry_id TEXT NOT NULL,
            block_id        TEXT NOT NULL,
            -- The definitions as they read at enrollment, one per line. **Local only.**
            definitions     TEXT NOT NULL,
            recorded_at     REAL NOT NULL
        );
        CREATE INDEX study_locators_by_note ON study_locators (note_id);

        -- Which lookups evidence a note. **The link, not the evidence**: deleting a lookup removes the
        -- link and leaves the note, because the reader enrolled a target rather than a moment, and
        -- tidying reading history must not delete study progress as a side effect.
        CREATE TABLE study_note_lookups (
            note_id     TEXT NOT NULL REFERENCES study_notes (id) ON DELETE CASCADE,
            lookup_id   INTEGER NOT NULL REFERENCES lookups (id) ON DELETE CASCADE,
            recorded_at REAL NOT NULL,
            PRIMARY KEY (note_id, lookup_id)
        );
        CREATE INDEX study_note_lookups_by_lookup ON study_note_lookups (lookup_id);
        """

    /// Schema 9's addition, kept apart from schema 8's so an upgrade applies exactly what it is missing.
    /// A database created now runs both; one created at 8 runs only this.
    static let studyAnswerSchema = """
        -- What the card reveals. One per note: a second answer is a revision, and revisions arrive with
        -- the editing surface that makes them (K02).
        CREATE TABLE study_answers (
            note_id            TEXT PRIMARY KEY REFERENCES study_notes (id) ON DELETE CASCADE,
            -- 'dictionary' text is the publisher's and is local only; 'reader' text is the reader's own.
            origin             TEXT NOT NULL,
            text               TEXT NOT NULL,
            dictionary_version TEXT,
            -- The sense's text hash at enrollment, so a content update that moves it is detectable.
            sense_hash         TEXT,
            recorded_at        REAL NOT NULL,
            -- **Swift's verdict, stored.** SQL's `trim()` removes ordinary spaces and nothing
            -- else, while `.whitespacesAndNewlines` removes tabs, newlines and the ideographic
            -- space — so an answer of only those was blank to one judge and usable to the other,
            -- and a card with nothing on its back reached the queue. The rule has one owner and
            -- SQL reads its answer rather than approximating it.
            is_usable          INTEGER NOT NULL,
            CHECK (origin IN ('dictionary', 'reader')),
            CHECK (is_usable IN (0, 1))
        );
        """

    /// Schema 10: the scheduled card and its review history.
    ///
    /// **A card is a question about a note, not the note itself.** One note can grow a second question
    /// later — recognise it, produce it — with its own schedule, which is why the schedule does not live
    /// on `study_notes`. Only the receptive question exists today; `prompt` is what lets the second one
    /// arrive without re-keying the first.
    /// Schema 12. A second prompt needs nothing new — `UNIQUE (note_id, prompt)` already gives it
    /// its own schedule — but tags do.
    static let studyOrganisationSchema = """
        -- The reader's own labels. Flat, because a hierarchy is a thing to maintain and a filter
        -- over flat tags is what the library actually asks for.
        CREATE TABLE study_tags (
            note_id TEXT NOT NULL REFERENCES study_notes (id) ON DELETE CASCADE,
            tag     TEXT NOT NULL,
            PRIMARY KEY (note_id, tag),
            CHECK (trim(tag) <> '')
        );
        CREATE INDEX study_tags_by_tag ON study_tags (tag);

        -- **"Already know" is a declaration about a word, not a note about it.** Inventing a study
        -- target for a word the reader just told us to stop offering would be answering "I know
        -- this" with a question about it. A lemma, a language and the date they said so — and
        -- reversible by deleting the row, because changing their mind is ordinary.
        CREATE TABLE study_ignored_lemmas (
            lemma      TEXT NOT NULL,
            language   TEXT NOT NULL,
            ignored_at REAL NOT NULL,
            PRIMARY KEY (lemma, language)
        );
        """

    static let studyCardSchema = """
        CREATE TABLE study_cards (
            id                 TEXT PRIMARY KEY,
            note_id            TEXT NOT NULL REFERENCES study_notes (id) ON DELETE CASCADE,
            -- Which question this card asks. 'meaning' is the receptive one: the reader's own sentence
            -- on the front, what it meant there on the back.
            prompt             TEXT NOT NULL,
            phase              TEXT NOT NULL,
            -- **Absent until the first real grade, never zero.** A stability of 0 is a claim about the
            -- reader's memory; "no attempt yet" is not one, and saving an answer is not an attempt.
            stability          REAL,
            difficulty         REAL,
            last_review        REAL,
            due                REAL,
            -- Eligibility, which is not memory: pausing and hiding change what is asked, never `S`.
            paused             INTEGER NOT NULL DEFAULT 0,
            hidden_until       REAL,
            -- Compare-and-swap. A grade computed against one state and written over another is the
            -- lost-update the review window's retries can produce.
            revision           INTEGER NOT NULL DEFAULT 0,
            scheduler_version  TEXT NOT NULL,
            created_at         REAL NOT NULL,
            CHECK (phase IN ('new', 'learning', 'review', 'relearning')),
            CHECK (paused IN (0, 1)),
            -- A card either has both halves of a memory state or neither. One of the two is a state
            -- nothing can be computed from, and it would reach the scheduler as a crash or a guess.
            CHECK ((stability IS NULL) = (difficulty IS NULL)),
            CHECK ((phase = 'new') = (stability IS NULL))
        );
        CREATE UNIQUE INDEX study_cards_question ON study_cards (note_id, prompt);
        CREATE INDEX study_cards_by_due ON study_cards (due);

        -- **Immutable.** A review is something that happened; undo marks it void and never deletes it,
        -- because a history with holes cannot be replayed and replay is how a parameter change is
        -- applied honestly.
        CREATE TABLE review_events (
            -- The caller's idempotency key. A retry after a failure it could not see must not grade
            -- the card twice, and this is what makes the second attempt return the first result.
            id                 TEXT PRIMARY KEY,
            card_id            TEXT NOT NULL REFERENCES study_cards (id) ON DELETE CASCADE,
            grade              INTEGER NOT NULL,
            reviewed_at        REAL NOT NULL,
            -- The complete state either side, so the event can be replayed and undone without
            -- recomputing anything from today's parameters.
            before_phase       TEXT NOT NULL,
            before_stability   REAL,
            before_difficulty  REAL,
            before_last_review REAL,
            before_due         REAL,
            after_phase        TEXT NOT NULL,
            after_stability    REAL NOT NULL,
            after_difficulty   REAL NOT NULL,
            after_due          REAL NOT NULL,
            -- Which scheduler said so. A replay must use the model that was in force, not today's.
            scheduler_version  TEXT NOT NULL,
            retention          REAL NOT NULL,
            card_revision      INTEGER NOT NULL,
            -- **A practice attempt is not a review.** Recorded, because it happened and it affects
            -- the reader's real memory; it changes no schedule and enters no retention figure —
            -- FSRS then has incomplete information, which is a known cost said out loud rather
            -- than a gap papered over with an invented grade.
            kind               TEXT NOT NULL DEFAULT 'graded',
            -- Undone, not deleted. Excluded from every count and from any retention figure.
            voided_at          REAL,
            CHECK (grade BETWEEN 1 AND 4),
            CHECK (kind IN ('graded', 'practice'))
        );
        CREATE INDEX review_events_by_card ON review_events (card_id, reviewed_at);
        """

    // MARK: - Notes

    /// Records a note. Throws where the schema refuses it — a duplicate target, or a shape no branch
    /// allows — rather than reporting success over a row that was not written.
    public func add(_ note: StudyNote) throws {
        let fields = Self.columns(of: note.target)
        try run(
            """
            INSERT INTO study_notes
                (id, target_kind, issuer, language, dictionary, entry_id, sense_key, sense_key_kind,
                 phrase_text, enrollment, confirmed_at, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: [.text(note.id.uuidString), .text(note.target.kind.rawValue),
                   .text(note.issuer.rawValue), .text(note.language), .text(note.target.dictionary),
                   .text(fields.entryID), .text(fields.senseKey), .text(fields.senseKeyKind),
                   .text(fields.phraseText), .text(note.enrollment.rawValue),
                   .optionalReal(note.confirmedAt?.timeIntervalSince1970),
                   .real(note.createdAt.timeIntervalSince1970)]) { _ in }
    }

    /// Every note, oldest first.
    public func notes() throws -> [StudyNote] {
        try notes(where: "", bind: [])
    }

    /// The note for one target, as issued by one extractor, in one language namespace.
    ///
    /// **All three are required.** A lookup by target alone would answer with whichever row happened to
    /// match first, which is the merge across issuers this schema exists to prevent.
    public func note(for target: StudyTarget, issuer: KeyIssuer, language: String) throws -> StudyNote? {
        let fields = Self.columns(of: target)
        return try notes(
            where: """
                WHERE target_kind = ? AND issuer = ? AND language = ? AND dictionary = ? \
                AND entry_id = ? AND sense_key = ? AND sense_key_kind = ? AND phrase_text = ?
                """,
            bind: [.text(target.kind.rawValue), .text(issuer.rawValue), .text(language),
                   .text(target.dictionary), .text(fields.entryID), .text(fields.senseKey),
                   .text(fields.senseKeyKind), .text(fields.phraseText)]).first
    }

    /// Removes a note and, by cascade, its locators and its links to lookups. **Never the lookups.**
    public func remove(noteID: UUID) throws {
        try run("DELETE FROM study_notes WHERE id = ?", bind: [.text(noteID.uuidString)]) { _ in }
    }

    func notes(where clause: String, bind values: [SQLiteValue]) throws -> [StudyNote] {
        var found: [StudyNote] = []
        try run(
            """
            SELECT id, target_kind, issuer, language, dictionary, entry_id, sense_key, sense_key_kind,
                   phrase_text, enrollment, confirmed_at, created_at
            FROM study_notes \(clause) ORDER BY created_at, id
            """,
            bind: values
        ) { row in
            if let note = try Self.note(from: row) { found.append(note) }
        }
        return found
    }

    /// One `StudyNote` out of the twelve columns every note query projects first.
    ///
    /// **One builder**, so the library and `notes(where:)` cannot come to disagree about what a row
    /// means — the same reason the reading projection has one.
    ///
    /// A row whose stored value this build does not know is **skipped, not guessed at**. It can only
    /// come from a newer build writing a kind this one has never heard of, and inventing a target for
    /// it would put a card in front of the reader that nothing here understands.
    static func note(from row: Row) throws -> StudyNote? {
        guard let kind = StudyTarget.Kind(rawValue: try row.text(1)),
              let issuer = KeyIssuer(rawValue: try row.text(2)),
              let enrollment = StudyEnrollment(rawValue: try row.text(9)),
              let id = UUID(uuidString: try row.text(0))
        else { return nil }
        let dictionary = try row.text(4), entryID = try row.text(5)
        let senseKey = try row.text(6), storedKind = try row.text(7), phraseText = try row.text(8)
        let target: StudyTarget? =
            switch kind {
            case .sense:
                SenseKeyKind(rawValue: storedKind).map {
                    .sense(dictionary: dictionary, entryID: entryID, senseKey: senseKey,
                           senseKeyKind: $0)
                }
            case .entry: .entry(dictionary: dictionary, entryID: entryID)
            case .phrase: .phrase(dictionary: dictionary, text: phraseText)
            case .custom: .custom(dictionary: dictionary, text: phraseText)
            }
        guard let target else { return nil }
        return StudyNote(
            id: id, target: target, issuer: issuer, language: try row.text(3),
            enrollment: enrollment,
            confirmedAt: row.isNull(10) ? nil : Date(timeIntervalSince1970: row.real(10)),
            createdAt: Date(timeIntervalSince1970: row.real(11)))
    }

    /// The columns a target occupies, and the ones it must leave empty. **One place**, so the insert and
    /// the lookup cannot disagree about which field a kind uses — if they did, a note would be written
    /// under one key and searched for under another, and every enrollment would look like the first.
    static func columns(
        of target: StudyTarget
    ) -> (entryID: String, senseKey: String, senseKeyKind: String, phraseText: String) {
        switch target {
        case .sense(_, let entryID, let senseKey, let kind):
            (entryID, senseKey, kind.rawValue, "")
        case .entry(_, let entryID):
            // `sense_key_kind` stays meaningful at the entry rung: `none` is what a dictionary that marks
            // no senses can offer, and it is what `StudyItem` carries for the same target.
            (entryID, "", SenseKeyKind.none.rawValue, "")
        case .phrase(_, let text), .custom(_, let text):
            ("", "", "", text)
        }
    }

    // MARK: - Locators

    public func add(_ locator: StudyLocator) throws {
        try run(
            """
            INSERT INTO study_locators
                (id, note_id, content_version, format_version, parent_entry_id, block_id, definitions,
                 recorded_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: [.text(locator.id.uuidString), .text(locator.noteID.uuidString),
                   .text(locator.contentVersion), .text(locator.formatVersion),
                   .text(locator.parentEntryID), .text(locator.blockID),
                   .text(Self.joined(locator.definitions)),
                   .real(locator.recordedAt.timeIntervalSince1970)]) { _ in }
    }

    public func locators(of noteID: UUID) throws -> [StudyLocator] {
        var found: [StudyLocator] = []
        try run(
            """
            SELECT id, note_id, content_version, format_version, parent_entry_id, block_id, definitions,
                   recorded_at
            FROM study_locators WHERE note_id = ? ORDER BY recorded_at, id
            """,
            bind: [.text(noteID.uuidString)]
        ) { row in
            guard let id = UUID(uuidString: try row.text(0)),
                  let note = UUID(uuidString: try row.text(1)) else { return }
            found.append(StudyLocator(
                id: id, noteID: note, contentVersion: try row.text(2), formatVersion: try row.text(3),
                parentEntryID: try row.text(4), blockID: try row.text(5),
                definitions: Self.split(try row.text(6)),
                recordedAt: Date(timeIntervalSince1970: row.real(7))))
        }
        return found
    }

    /// Definitions, one per line.
    ///
    /// **A newline inside one is flattened, not escaped** — the same rule and the same reason as the
    /// phrase inventory's own file: no measured definition contains one, and an escape scheme for a case
    /// that does not arise is a parser nobody has tested. An empty list stores an empty string and reads
    /// back as an empty list.
    static func joined(_ definitions: [String]) -> String {
        definitions.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n")
    }

    static func split(_ stored: String) -> [String] {
        stored.isEmpty ? [] : stored.components(separatedBy: "\n")
    }

    // MARK: - The lookups that evidence a note

    /// Links a note to a lookup that evidences it. Idempotent: the same pair twice is one row, because a
    /// retry after a failure the caller could not see must not double-count the reader's encounters.
    public func link(noteID: UUID, toLookup lookupID: Int, at when: Date) throws {
        try run(
            """
            INSERT OR IGNORE INTO study_note_lookups (note_id, lookup_id, recorded_at) VALUES (?, ?, ?)
            """,
            bind: [.text(noteID.uuidString), .integer(lookupID),
                   .real(when.timeIntervalSince1970)]) { _ in }
    }

    public func lookupIDs(evidencing noteID: UUID) throws -> [Int] {
        var found: [Int] = []
        try run(
            "SELECT lookup_id FROM study_note_lookups WHERE note_id = ? ORDER BY recorded_at, lookup_id",
            bind: [.text(noteID.uuidString)]) { found.append($0.integer(0)) }
        return found
    }
}

/// **Enrollment: making one trustworthy study target out of a lookup.** WI-002.
///
/// The hard part is not saving. It is refusing to present, as a question with a known answer, something
/// that is a guess, a draft, or a card whose cue the reader has since deleted — while still *keeping* all
/// three, because the reader asked for them. Enrollment says what the reader wants; `readiness(of:)` says
/// what may be asked; and the two are computed from different facts on purpose.
extension Ledger {
    /// Saves a target the reader met, or returns the one they already have.
    ///
    /// **Idempotent by identity, not by call.** Tapping a sense you already study is an ordinary thing to
    /// do, and the honest answer is the note you already have with one more reading attached to it — not
    /// a second card, and not an error the caller has to interpret.
    ///
    /// `chosenBy` is how the sense came to be this one. `.model` enrols **unconfirmed**: a hypothesis is
    /// not a question. `.reader` and `.onlySense` are confirmed as they are saved, because there was
    /// nothing to doubt. `nil` — an entry rung, where no sense was chosen at all — is confirmed too: what
    /// holds that target back is its answer, not its identity.
    @discardableResult
    public func enroll(_ target: StudyTarget, issuer: KeyIssuer, language: String,
                       chosenBy: SenseChoice?, answer: StudyAnswer?, lookupID: Int,
                       at when: Date, explicitly: Bool = true) throws -> StudyNote {
        let existing = try note(for: target, issuer: issuer, language: language)
        let note = existing ?? StudyNote(
            target: target, issuer: issuer, language: language, enrollment: .active,
            confirmedAt: chosenBy == .model ? nil : when, createdAt: when)
        // **One transaction, because half an enrollment is worse than none.** A note with no link is a
        // card with no cue; a link with no note cannot exist at all. `SAVEPOINT`, not `BEGIN`, for the
        // same reason a lookup and its sense use one: this can be called inside another.
        try execute("SAVEPOINT enroll")
        do {
            if existing == nil { try add(note) }
            if explicitly { try explicitlyKeep(noteID: note.id) }
            try link(noteID: note.id, toLookup: lookupID, at: when)
            // **The first answer stays.** A later save does not overwrite what the card already reveals:
            // rewriting an answer the reader has been reviewing against changes the question under them,
            // and replacing it is an edit they make deliberately (K02).
            if let answer, try self.answer(of: note.id) == nil {
                try setAnswer(answer, of: note.id, at: when)
            }
            // **The card exists from the moment the target does, and it is `new`.** Not scheduled:
            // saving a meaning is not a review of it, and a first interval invented here would be a
            // grade the reader never gave. The queue decides when a `new` card is first asked.
            try card(of: note.id, at: when)
            try execute("RELEASE enroll")
        } catch {
            try? execute("ROLLBACK TO enroll")
            try? execute("RELEASE enroll")
            throw error
        }
        return note
    }

    /// The reader agreed that this is the target they met.
    ///
    /// **A new fact on the note, never an edit to the evidence.** The selector's own `chosen_by = model`
    /// row stays as it is: a proposal later agreed with is not the same history as a sense the reader
    /// picked unaided, and the ledger has to be able to tell them apart.
    /// **The first confirmation stands.** A bulk confirm reaches every selected note, including
    /// ones the reader confirmed weeks ago, and this overwrote their timestamps with today's —
    /// rewriting when they said it, which is the one thing a record of what they said must not
    /// do. Confirming an already-confirmed note is now a no-op rather than an edit.
    /// Confirms several notes in **one transaction**, for the reason the bulk pause and archive
    /// helpers have one: a failure part-way through a loop of separate commits leaves a subset
    /// changed and nothing on screen says which.
    public func confirm(noteIDs ids: [UUID], at when: Date) throws {
        guard !ids.isEmpty else { return }
        try inOneTransaction("bulkConfirm") { for id in ids { try self.confirm(noteID: id, at: when) } }
    }

    public func confirm(noteID: UUID, at when: Date) throws {
        try run("UPDATE study_notes SET confirmed_at = ? WHERE id = ? AND confirmed_at IS NULL",
                bind: [.real(when.timeIntervalSince1970), .text(noteID.uuidString)]) { _ in }
    }

    /// Clears a note's confirmation. **For tests**: there is no reader-facing route to unconfirm,
    /// because a confirmation is something they said and taking it back for them is not.
    func unconfirmForTesting(noteID: UUID) throws {
        try run("UPDATE study_notes SET confirmed_at = NULL WHERE id = ?",
                bind: [.text(noteID.uuidString)]) { _ in }
    }

    /// Whether the reader wants this target. Every value is reachable from every other: a disposition is
    /// a declaration, and nothing here erases evidence.
    public func setEnrollment(_ enrollment: StudyEnrollment, of noteID: UUID) throws {
        try run("UPDATE study_notes SET enrollment = ? WHERE id = ?",
                bind: [.text(enrollment.rawValue), .text(noteID.uuidString)]) { _ in }
    }

    // MARK: - The answer

    public func setAnswer(_ answer: StudyAnswer, of noteID: UUID, at when: Date) throws {
        try run(
            """
            INSERT INTO study_answers (note_id, origin, text, dictionary_version, sense_hash,
                                       recorded_at, is_usable)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (note_id) DO UPDATE SET
                origin = excluded.origin, text = excluded.text,
                dictionary_version = excluded.dictionary_version, sense_hash = excluded.sense_hash,
                recorded_at = excluded.recorded_at, is_usable = excluded.is_usable
            """,
            bind: [.text(noteID.uuidString), .text(answer.origin.rawValue), .text(answer.text),
                   .optionalText(answer.dictionaryVersion), .optionalText(answer.senseHash),
                   .real(when.timeIntervalSince1970), .integer(answer.isUsable ? 1 : 0)]) { _ in }
    }

    public func answer(of noteID: UUID) throws -> StudyAnswer? {
        var found: StudyAnswer?
        try run(
            "SELECT origin, text, dictionary_version, sense_hash FROM study_answers WHERE note_id = ?",
            bind: [.text(noteID.uuidString)]
        ) { row in
            guard let origin = StudyAnswer.Origin(rawValue: try row.text(0)) else { return }
            found = StudyAnswer(origin: origin, text: try row.text(1),
                                dictionaryVersion: row.optionalText(2), senseHash: row.optionalText(3))
        }
        return found
    }

    // MARK: - What may be asked

    /// Whether this note can be put to the reader as a question with an answer behind it.
    ///
    /// **Computed from the facts every time, never read from a column.** The facts live in three places
    /// and change independently: the note's confirmation, its answer, and whether any reading still
    /// evidences it. A stored verdict would be right when written and wrong afterwards, with nothing
    /// having touched the row that claims it.
    ///
    /// `senseHashNow` is what the dictionary says *today*, where the caller could ask. A hash that
    /// differs from the one recorded at enrollment means the sense moved under a positional key and the
    /// card is no longer about what it was. **Nil is not evidence**: a dictionary that could not be asked
    /// has said nothing, and treating silence as a change would send every card into repair whenever a
    /// dictionary is unavailable.
    public func readiness(of noteID: UUID, senseHashNow: String? = nil) throws -> StudyReadiness {
        let notes = try notes(where: "WHERE id = ?", bind: [.text(noteID.uuidString)])
        guard let note = notes.first else { return .needsRepair }
        let answer = try answer(of: noteID)
        return StudyReadiness.of(StudyReadiness.Facts(
            isConfirmed: note.confirmedAt != nil,
            hasUsableAnswer: answer?.isUsable ?? false,
            answerIsPublishers: answer?.origin == .dictionary,
            isEntryRung: { if case .entry = note.target { return true } else { return false } }(),
            hasReading: try !lookupIDs(evidencing: noteID).isEmpty,
            senseMoved: {
                guard let senseHashNow, let recorded = answer?.senseHash else { return false }
                return senseHashNow != recorded
            }(),
            needsReading: { if case .custom = note.target { return false } else { return true } }()))
    }
}
