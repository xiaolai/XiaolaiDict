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
            -- 'sense' | 'entry' | 'phrase'. No 'custom' yet: C07's reader-authored card is what will
            -- write one, and a kind nothing constructs is a value no test can reach.
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
            readiness       TEXT NOT NULL,
            created_at      REAL NOT NULL,
            CHECK (target_kind IN ('sense', 'entry', 'phrase')),
            CHECK (issuer IN ('live', 'index', 'inventory')),
            CHECK (enrollment IN ('candidate', 'active', 'ignored', 'archived')),
            CHECK (readiness IN ('ready', 'needsConfirmation', 'needsRepair')),
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

    // MARK: - Notes

    /// Records a note. Throws where the schema refuses it — a duplicate target, or a shape no branch
    /// allows — rather than reporting success over a row that was not written.
    public func add(_ note: StudyNote) throws {
        let fields = Self.columns(of: note.target)
        try run(
            """
            INSERT INTO study_notes
                (id, target_kind, issuer, language, dictionary, entry_id, sense_key, sense_key_kind,
                 phrase_text, enrollment, readiness, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: [.text(note.id.uuidString), .text(note.target.kind.rawValue),
                   .text(note.issuer.rawValue), .text(note.language), .text(note.target.dictionary),
                   .text(fields.entryID), .text(fields.senseKey), .text(fields.senseKeyKind),
                   .text(fields.phraseText), .text(note.enrollment.rawValue),
                   .text(note.readiness.rawValue),
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

    private func notes(where clause: String, bind values: [SQLiteValue]) throws -> [StudyNote] {
        var found: [StudyNote] = []
        try run(
            """
            SELECT id, target_kind, issuer, language, dictionary, entry_id, sense_key, sense_key_kind,
                   phrase_text, enrollment, readiness, created_at
            FROM study_notes \(clause) ORDER BY created_at, id
            """,
            bind: values
        ) { row in
            // A row whose stored value this build does not know is **skipped, not guessed at**. It can
            // only come from a newer build writing a kind this one has never heard of, and inventing a
            // target for it would put a card in front of the reader that nothing here understands.
            guard let kind = StudyTarget.Kind(rawValue: try row.text(1)),
                  let issuer = KeyIssuer(rawValue: try row.text(2)),
                  let enrollment = StudyEnrollment(rawValue: try row.text(9)),
                  let readiness = StudyReadiness(rawValue: try row.text(10)),
                  let id = UUID(uuidString: try row.text(0))
            else { return }
            // Every column read before the target is built: a throwing call inside the expression
            // would have to be spelled once per branch, and the branch that forgot would read a
            // column the projection does not have.
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
                }
            guard let target else { return }
            found.append(StudyNote(
                id: id, target: target, issuer: issuer, language: try row.text(3),
                enrollment: enrollment, readiness: readiness,
                createdAt: Date(timeIntervalSince1970: row.real(11))))
        }
        return found
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
        case .phrase(_, let text):
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
