import CaptureModel
import DictionaryModel
import Foundation
import ReviewKit
import SQLite3
import Testing
@testable import XiaolaiDictCore
import XiaolaiDictTestSupport

/// **Schema 8: the study system's durable entities, and nothing that grades anything yet.**
///
/// WI-001 of the card plan. What it has to get right is identity, because identity is the part that cannot
/// be repaired later: a note keyed by something ambiguous cannot be told apart from its neighbour once the
/// rows exist, and the evidence needed to separate them is not recorded anywhere else.
///
/// Three failures this suite exists to prevent, each of which returns a plausible answer rather than an
/// error — two of them found by attacking the design before it was written (ADR-0028):
///
/// 1. A phrase enrolled under its parent's entry id, which is already the parent word's own note.
/// 2. Two extractors' keys resolving to one target, so a schedule is inherited across a swap nobody
///    measured.
/// 3. A partial unique index that a malformed row walks straight past, because `target_kind = 'sense'`
///    constrains no column by itself.
struct StudySchemaTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ledger() throws -> Ledger { try Ledger(path: ":memory:") }

    private func note(_ target: StudyTarget, issuer: KeyIssuer = .live,
                      language: String = "en") -> StudyNote {
        StudyNote(target: target, issuer: issuer, language: language, createdAt: now)
    }

    // MARK: - The migration

    @Test func theStudyTablesArriveEmpty() throws {
        let ledger = try ledger()
        #expect(Ledger.schemaVersion >= 8)
        #expect(try ledger.notes().isEmpty, "a migration must not invent a note")
    }

    /// **A lookup written before the study system existed is untouched by it.** The migration is additive:
    /// no card is backfilled, no confirmation inferred, and no historical row re-read.
    @Test func themigrationLeavesTheReadingHistoryAlone() throws {
        let ledger = try ledger()
        let record = LookupRecord(
            surface: "fine", lemma: "fine", context: "He paid the fine.", lemmaBasis: .tagger,
            language: "en", contextRange: NSRange(location: 12, length: 4),
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari", document: nil,
                                page: nil, title: nil, rawTitle: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService,
            quality: .accessibility(.accessibilityTextMarkers, context: .complete))
        _ = try ledger.record(record)
        #expect(try ledger.history(of: "fine").count == 1)
        #expect(try ledger.notes().isEmpty, "a lookup is not an enrollment")
    }

    // MARK: - Identity

    @Test func anoteSurvivesBeingWrittenAndRead() throws {
        let ledger = try ledger()
        let written = note(.sense(dictionary: "noad", entryID: "e1", senseKey: "e1.001",
                                  senseKeyKind: .publisher))
        try ledger.add(written)
        #expect(try ledger.notes() == [written])
        #expect(try ledger.note(for: written.target, issuer: .live, language: "en") == written)
    }

    /// The same target twice is one note, not two. This is C03 — three encounters with one sense enrich a
    /// single target — enforced in the schema rather than by whoever calls it.
    @Test func thesameTargetTwiceIsOneNote() throws {
        let ledger = try ledger()
        let target = StudyTarget.sense(dictionary: "noad", entryID: "e1", senseKey: "e1.001",
                                       senseKeyKind: .publisher)
        try ledger.add(note(target))
        #expect(throws: (any Error).self) { try ledger.add(self.note(target)) }
        #expect(try ledger.notes().count == 1)
    }

    /// **The collision this whole target design exists to stop.** `take something into account` is filed
    /// inside `account`'s entry, so before `StudyTarget.phrase` the only identity available to it was
    /// `(noad, account, no sense)` — which is exactly the identity of the word *account* at the entry rung.
    @Test func aphraseDoesNotCollideWithItsParentWordsEntry() throws {
        let ledger = try ledger()
        try ledger.add(note(.entry(dictionary: "noad", entryID: "m_en_gbus0005190")))
        try ledger.add(note(.phrase(dictionary: "noad", text: "take something into account"),
                            issuer: .inventory))
        #expect(try ledger.notes().count == 2, "the phrase and the word it is filed in are two targets")
    }

    /// A sense and its entry are different rungs of the same entry, and two different notes.
    @Test func asenseAndItsEntryAreDifferentTargets() throws {
        let ledger = try ledger()
        try ledger.add(note(.entry(dictionary: "noad", entryID: "e1")))
        try ledger.add(note(.sense(dictionary: "noad", entryID: "e1", senseKey: "e1.001",
                                   senseKeyKind: .publisher)))
        #expect(try ledger.notes().count == 2)
    }

    /// Study state belongs to one dictionary: the same spelling in two dictionaries is two targets, and
    /// switching the primary starts study over rather than carrying progress across.
    @Test func twoDictionariesAreTwoTargets() throws {
        let ledger = try ledger()
        try ledger.add(note(.sense(dictionary: "noad", entryID: "e1", senseKey: "s", senseKeyKind: .publisher)))
        try ledger.add(note(.sense(dictionary: "oxford", entryID: "e1", senseKey: "s", senseKeyKind: .publisher)))
        #expect(try ledger.notes().count == 2)
    }

    /// **Two issuers are two targets until an equivalence is measured.** The same address string from the
    /// live path and from the index is not evidence that they mean the same sense — that is the swap the
    /// project's own rule says orphans every study item — so resolution is issuer-aware and a second
    /// issuer creates a second, visible note rather than silently inheriting the first one's schedule.
    @Test func thesameAddressFromTwoIssuersDoesNotResolveToOneTarget() throws {
        let ledger = try ledger()
        let target = StudyTarget.sense(dictionary: "noad", entryID: "e1", senseKey: "e1.001",
                                       senseKeyKind: .publisher)
        try ledger.add(note(target, issuer: .live))
        try ledger.add(note(target, issuer: .index))
        #expect(try ledger.notes().count == 2)
        #expect(try ledger.note(for: target, issuer: .live, language: "en")?.issuer == .live)
        #expect(try ledger.note(for: target, issuer: .index, language: "en")?.issuer == .index)
    }

    /// **An unrecorded language is its own group, not a wildcard.** Stored as a sentinel rather than NULL
    /// because SQLite NULL never equals NULL: under a nullable column two notes with an unknown language
    /// and the same target would both be admitted, and the uniqueness the schema claims would be decoration.
    @Test func anUnknownLanguageIsItsOwnGroupAndStillCollides() throws {
        let ledger = try ledger()
        let target = StudyTarget.entry(dictionary: "noad", entryID: "e1")
        try ledger.add(note(target, language: StudyNote.unknownLanguage))
        try ledger.add(note(target, language: "en"))
        #expect(try ledger.notes().count == 2, "unknown and English are different namespaces")
        #expect(throws: (any Error).self) {
            try ledger.add(self.note(target, language: StudyNote.unknownLanguage))
        }
    }

    // MARK: - Shapes the schema must refuse

    /// One row, spelled out, so a malformed shape can be written that no Swift value can express.
    private static func insert(
        _ id: String, kind: String, issuer: String = "live", language: String = "en",
        dictionary: String = "noad", entry: String = "", senseKey: String = "",
        senseKeyKind: String = "", phrase: String = ""
    ) -> String {
        let values = [id, kind, issuer, language, dictionary, entry, senseKey, senseKeyKind, phrase,
                      "candidate", "ready"]
        let quoted = values.map { "'\($0)'" }.joined(separator: ", ")
        return """
            INSERT INTO study_notes (id, target_kind, issuer, language, dictionary, entry_id,             sense_key, sense_key_kind, phrase_text, enrollment, readiness, created_at)             VALUES (\(quoted), 0)
            """
    }

    /// **A partial index does not constrain the columns its branch does not mention.** `target_kind =
    /// 'sense'` says nothing about `sense_key` being present, so without explicit branch checks two
    /// malformed sense rows sit side by side and the index they were supposed to collide in never sees
    /// them. Written as raw SQL because no Swift value can express the malformed row — which is the
    /// point: the constraint has to live in the database, not in the type that usually writes it.
    @Test func amalformedRowIsRefusedByTheSchema() throws {
        let refused: [(String, String)] = [
            ("a sense with no sense key",
             Self.insert("a", kind: "sense", entry: "e1", senseKeyKind: "publisher")),
            ("a sense with no entry",
             Self.insert("b", kind: "sense", senseKey: "e1.001", senseKeyKind: "publisher")),
            ("a phrase carrying an entry id",
             Self.insert("c", kind: "phrase", issuer: "inventory", entry: "e1",
                         phrase: "take into account")),
            ("a phrase with no text",
             Self.insert("d", kind: "phrase", issuer: "inventory")),
            ("a kind this build does not know",
             Self.insert("e", kind: "nonsense", entry: "e1", senseKeyKind: "none")),
            ("an issuer this build does not know",
             Self.insert("f", kind: "entry", issuer: "nonsense", entry: "e1", senseKeyKind: "none")),
            ("an empty language, which NULL-like sentinels must never become",
             Self.insert("g", kind: "entry", language: "", entry: "e1", senseKeyKind: "none")),
        ]
        for (what, sql) in refused {
            let ledger = try ledger()
            #expect(throws: (any Error).self, "the schema accepted \(what)") {
                try ledger.execute(sql)
            }
            #expect(try ledger.notes().isEmpty)
        }
    }

    /// And the positive control: the well-formed shape of each branch is accepted, so the checks above
    /// are refusing the defect rather than everything.
    @Test func awellFormedRowOfEachKindIsAccepted() throws {
        let ledger = try ledger()
        try ledger.add(note(.sense(dictionary: "noad", entryID: "e1", senseKey: "e1.001",
                                   senseKeyKind: .publisher)))
        try ledger.add(note(.entry(dictionary: "noad", entryID: "e2")))
        try ledger.add(note(.phrase(dictionary: "noad", text: "kick the bucket"), issuer: .inventory))
        #expect(try ledger.notes().count == 3)
    }

    // MARK: - Locators

    /// A phrase note keeps **where** its meaning was found, in which build, read by which extraction — and
    /// more than one of them, because a phrase is filed under more than one parent.
    @Test func aphraseNoteKeepsEveryLocator() throws {
        let ledger = try ledger()
        let note = note(.phrase(dictionary: "noad", text: "blow a fuse"), issuer: .inventory)
        try ledger.add(note)
        for (parent, definition) in [("blow", "lose one's temper"),
                                     ("fuse", "use too much power in an electrical circuit")] {
            try ledger.add(StudyLocator(
                noteID: note.id, contentVersion: "v1", formatVersion: "phrases/6",
                parentEntryID: parent, blockID: "\(parent).01", definitions: [definition],
                recordedAt: now))
        }
        let found = try ledger.locators(of: note.id)
        #expect(found.count == 2)
        #expect(found.map(\.parentEntryID).sorted() == ["blow", "fuse"])
        #expect(found.flatMap(\.definitions).count == 2)
    }

    /// Several definitions in one block survive as several, in order — the loss ADR-0028 closed upstream
    /// must not be reintroduced by the storage that keeps it.
    @Test func alocatorKeepsEveryDefinitionInOrder() throws {
        let ledger = try ledger()
        let note = note(.phrase(dictionary: "noad", text: "give up"), issuer: .inventory)
        try ledger.add(note)
        let definitions = ["stop trying", "surrender", "devote", "abandon", "renounce"]
        try ledger.add(StudyLocator(
            noteID: note.id, contentVersion: "v1", formatVersion: "phrases/6",
            parentEntryID: "give", blockID: "give.041", definitions: definitions, recordedAt: now))
        #expect(try ledger.locators(of: note.id).first?.definitions == definitions)
    }

    /// A locator belonging to no note is refused, and deleting a note takes its locators with it —
    /// asserted rather than assumed, because `PRAGMA foreign_keys` is off by default and per connection,
    /// so a schema full of references can be decoration.
    @Test func alocatorCannotOutliveItsNote() throws {
        let ledger = try ledger()
        let orphan = StudyLocator(
            noteID: UUID(), contentVersion: "v1", formatVersion: "phrases/6",
            parentEntryID: "p", blockID: "p.01", definitions: ["x"], recordedAt: now)
        #expect(throws: (any Error).self) { try ledger.add(orphan) }

        let note = note(.phrase(dictionary: "noad", text: "kick the bucket"), issuer: .inventory)
        try ledger.add(note)
        try ledger.add(StudyLocator(
            noteID: note.id, contentVersion: "v1", formatVersion: "phrases/6",
            parentEntryID: "kick", blockID: "kick.01", definitions: ["die"], recordedAt: now))
        try ledger.remove(noteID: note.id)
        #expect(try ledger.locators(of: note.id).isEmpty)
    }

    // MARK: - The evidence a note rests on

    /// **A note is linked to the encounters that evidence it, and the link is not the evidence.** Deleting
    /// a lookup removes its encounters; the note stays, because the reader enrolled a target rather than a
    /// moment. Losing the note with the lookup would delete study progress as a side effect of tidying
    /// reading history — two operations the ledger must keep separate (D02).
    @Test func removingAlookupDoesNotRemoveTheNoteItEvidenced() throws {
        let ledger = try ledger()
        let record = LookupRecord(
            surface: "fine", lemma: "fine", context: "He paid the fine.", lemmaBasis: .tagger,
            language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: nil, name: nil, document: nil, page: nil, title: nil,
                                rawTitle: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil)
        let lookupID = try ledger.record(record)
        let note = note(.entry(dictionary: "noad", entryID: "e1"))
        try ledger.add(note)
        try ledger.link(noteID: note.id, toLookup: lookupID, at: now)
        #expect(try ledger.lookupIDs(evidencing: note.id) == [lookupID])

        try ledger.delete(lookup: lookupID)
        #expect(try ledger.notes().count == 1, "the target survives the moment that introduced it")
        #expect(try ledger.lookupIDs(evidencing: note.id).isEmpty, "and the link goes with the lookup")
    }
}

/// **The 7 → 8 migration, on a ledger with a reader's history already in it.**
///
/// Separate from the schema suite because it needs a file: the risk a migration carries is not that the
/// new tables are wrong but that the old rows move, and `:memory:` cannot express the failure — nor can
/// it express the backup, which is the part a reader relies on when they want the upgrade undone.
struct StudyMigrationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// In a directory of its own, removed whole. The suffix list here named `.schema7.backup` and not
    /// `.schema8.backup`, nor the backup of a backup a test makes by opening the copy — so those stayed.
    private func path() -> String { ScratchFile.path("study") }

    private func remove(_ path: String) { ScratchFile.remove(path) }

    private func lookup(_ lemma: String) -> LookupRecord {
        LookupRecord(
            surface: lemma, lemma: lemma, context: "A sentence holding \(lemma).", lemmaBasis: .tagger,
            language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari", document: nil,
                                page: nil, title: nil, rawTitle: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil)
    }

    /// Winds a real schema-8 ledger back to 7 and reopens it, so the migration step runs against rows
    /// written by the shipping code rather than against a hand-built fixture that may not resemble them.
    /// The tables one schema constant creates, read from the constant itself.
    static func tablesCreated(by schema: String) -> [String] {
        schema.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("CREATE TABLE ") else { return nil }
            return trimmed.dropFirst("CREATE TABLE ".count)
                .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                .description
        }
    }

    /// Winds a real ledger back to an earlier schema and leaves it there, so a migration runs against
    /// rows written by the shipping code rather than a hand-built fixture that may not resemble them.
    ///
    /// **One cascade, not one helper per version.** Three schemas in a row shipped with this lagging
    /// behind — each time, the migration test failed on a table the unwind did not know to drop, and
    /// each time the fix was to add a line to a copy. A new schema adds one case here and the older
    /// paths get it for free.
    ///
    /// **And to the shape that version created, not today's minus a column** (audit-fix round 2). A table
    /// whose `CREATE` changed — a `CHECK` widened, a column added with a constraint — is rebuilt from the
    /// historic statement, because `DROP COLUMN` cannot take a column a `CHECK` names and a dropped
    /// column leaves today's `CHECK`s behind. Winding back to 8 by dropping `confirmed_at` and adding a
    /// constraint-free `readiness` is how a migration that failed on every real schema-8 ledger passed.
    /// The historic statements are below, verbatim but for comments, from the commits that shipped them,
    /// and the migration was run against real ledgers built from each of those commits' own SQL as well
    /// (review-module-plan §13, audit-fix round 2).
    private func windBack(to version: Int, at path: String) throws {
        let ledger = try Ledger(path: path)
        // **Off, or a rebuild deletes the children.** Dropping a parent table with foreign keys on is a
        // `DELETE` that cascades; this connection is gone once the statements below have run.
        var statements: [String] = ["PRAGMA foreign_keys = OFF;"]
        if version < 13 {
            statements += ["DROP TRIGGER remember_removed_target;", "DROP TRIGGER study_keep_new_note;",
                "DROP TABLE lookup_disposition_receipts;", "DROP TABLE lookup_disposition_operations;",
                "DROP TABLE study_keep_metadata;", "DROP TABLE removed_keep_targets;", "DROP TABLE keep_backfill;",
                "DROP INDEX lookups_archive;", "ALTER TABLE lookups DROP COLUMN disposition;",
                "ALTER TABLE lookups DROP COLUMN disposition_revision;", "ALTER TABLE lookups DROP COLUMN primary_dictionary;",
                "ALTER TABLE lookups DROP COLUMN keep_policy;"]
        }
        if version < 12 {
            // **Read out of the schema, not repeated here.** This branch listed its tables by hand
            // and fell behind three times — each new table meant a migration test failing on
            // "already exists", and each time the fix was to add a line to a copy. Adding a table
            // to `studyOrganisationSchema` now updates this automatically, which is the only
            // version of this that stays true.
            statements += Self.tablesCreated(by: Ledger.studyOrganisationSchema)
                .map { "DROP TABLE \($0);" }
        }
        // `kind` came with 12 for a database that already had the table; one made at 10 or 11 never
        // had it — nor its `CHECK`, which is also why the column cannot simply be dropped.
        if version < 10 {
            statements += ["DROP TABLE review_events;", "DROP TABLE study_cards;"]
        } else if version < 12 {
            statements += Self.rebuild("review_events", as: Self.reviewEventsAtTenAndEleven,
                                       columns: Self.reviewEventColumnsAtTen)
        }
        // `is_usable` came with 11, under a `CHECK`.
        if version < 9 {
            statements += ["DROP TABLE study_answers;"]
        } else if version < 11 {
            statements += Self.rebuild("study_answers", as: Self.studyAnswersAtNineAndTen,
                                       columns: Self.studyAnswerColumnsAtNine)
        }
        if version < 8 {
            statements += ["DROP TABLE study_note_lookups;", "DROP TABLE study_locators;",
                           "DROP TABLE study_notes;",
                           "ALTER TABLE sense_encounters DROP COLUMN key_issuer;"]
        } else if version == 8 {
            // Readiness stored, under a `CHECK`, and no confirmation: what 9 corrected. Every row was
            // `ready` or one of two others; which is unknowable now, and the migration drops it anyway.
            statements += Self.rebuild("study_notes", as: Self.studyNotesAtEight,
                                       columns: Self.studyNoteColumnsBeforeTwelve,
                                       adding: ("readiness", "'ready'"))
        } else if version < 12 {
            // No `custom` before 12: the kind and its branch shape both came with it.
            statements += Self.rebuild("study_notes", as: Self.studyNotesAtNineToEleven,
                                       columns: Self.studyNoteColumnsBeforeTwelve + ["confirmed_at"])
        }
        statements.append("PRAGMA user_version = \(version);")
        try ledger.execute(statements.joined(separator: "\n"))
    }

    /// One table put back to a historic `CREATE`, its rows kept: the shared columns copied through a
    /// temporary table, and `adding` filled with a constant where the old shape had a column today's
    /// does not.
    static func rebuild(_ table: String, as ddl: String, columns: [String],
                        adding extra: (column: String, value: String)? = nil) -> [String] {
        let shared = columns.joined(separator: ", ")
        let into = extra.map { shared + ", " + $0.column } ?? shared
        let from = extra.map { shared + ", " + $0.value } ?? shared
        return ["DROP TABLE IF EXISTS temp.wound_back;",
                "CREATE TEMP TABLE wound_back AS SELECT \(shared) FROM \(table);",
                "DROP TABLE \(table);", ddl,
                "INSERT INTO \(table) (\(into)) SELECT \(from) FROM temp.wound_back;",
                "DROP TABLE temp.wound_back;"]
    }

    static let studyNoteColumnsBeforeTwelve = [
        "id", "target_kind", "issuer", "language", "dictionary", "entry_id", "sense_key", "sense_key_kind",
        "phrase_text", "enrollment", "created_at",
    ]

    /// `study_notes` as 6369857 created it (schema 8).
    static let studyNotesAtEight = """
        CREATE TABLE study_notes (
            id              TEXT PRIMARY KEY,
            target_kind     TEXT NOT NULL,
            issuer          TEXT NOT NULL,
            language        TEXT NOT NULL,
            dictionary      TEXT NOT NULL,
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
            CHECK (
                (target_kind = 'sense'
                    AND entry_id <> '' AND sense_key <> '' AND sense_key_kind <> '' AND phrase_text = '')
             OR (target_kind = 'entry'
                    AND entry_id <> '' AND sense_key = '' AND phrase_text = '')
             OR (target_kind = 'phrase'
                    AND entry_id = '' AND sense_key = '' AND sense_key_kind = '' AND phrase_text <> '')
            )
        );
        CREATE UNIQUE INDEX study_notes_identity ON study_notes (
            target_kind, issuer, language, dictionary, entry_id, sense_key, sense_key_kind, phrase_text
        );
        CREATE INDEX study_notes_by_dictionary ON study_notes (dictionary, enrollment);
        """

    /// `study_notes` as 2bce356, bb1e57d and 405d14f created it (schemas 9, 10 and 11).
    static let studyNotesAtNineToEleven = """
        CREATE TABLE study_notes (
            id              TEXT PRIMARY KEY,
            target_kind     TEXT NOT NULL,
            issuer          TEXT NOT NULL,
            language        TEXT NOT NULL,
            dictionary      TEXT NOT NULL,
            entry_id        TEXT NOT NULL,
            sense_key       TEXT NOT NULL,
            sense_key_kind  TEXT NOT NULL,
            phrase_text     TEXT NOT NULL,
            enrollment      TEXT NOT NULL,
            confirmed_at    REAL,
            created_at      REAL NOT NULL,
            CHECK (target_kind IN ('sense', 'entry', 'phrase')),
            CHECK (issuer IN ('live', 'index', 'inventory')),
            CHECK (enrollment IN ('candidate', 'active', 'ignored', 'archived')),
            CHECK (language <> '' AND dictionary <> ''),
            CHECK (
                (target_kind = 'sense'
                    AND entry_id <> '' AND sense_key <> '' AND sense_key_kind <> '' AND phrase_text = '')
             OR (target_kind = 'entry'
                    AND entry_id <> '' AND sense_key = '' AND phrase_text = '')
             OR (target_kind = 'phrase'
                    AND entry_id = '' AND sense_key = '' AND sense_key_kind = '' AND phrase_text <> '')
            )
        );
        CREATE UNIQUE INDEX study_notes_identity ON study_notes (
            target_kind, issuer, language, dictionary, entry_id, sense_key, sense_key_kind, phrase_text
        );
        CREATE INDEX study_notes_by_dictionary ON study_notes (dictionary, enrollment);
        """

    static let studyAnswerColumnsAtNine = [
        "note_id", "origin", "text", "dictionary_version", "sense_hash", "recorded_at",
    ]

    /// `study_answers` as 2bce356 and bb1e57d created it (schemas 9 and 10): no stored verdict.
    static let studyAnswersAtNineAndTen = """
        CREATE TABLE study_answers (
            note_id            TEXT PRIMARY KEY REFERENCES study_notes (id) ON DELETE CASCADE,
            origin             TEXT NOT NULL,
            text               TEXT NOT NULL,
            dictionary_version TEXT,
            sense_hash         TEXT,
            recorded_at        REAL NOT NULL,
            CHECK (origin IN ('dictionary', 'reader'))
        );
        """

    static let reviewEventColumnsAtTen = [
        "id", "card_id", "grade", "reviewed_at", "before_phase", "before_stability", "before_difficulty",
        "before_last_review", "before_due", "after_phase", "after_stability", "after_difficulty", "after_due",
        "scheduler_version", "retention", "card_revision", "voided_at",
    ]

    /// `review_events` as bb1e57d and 405d14f created it (schemas 10 and 11): no kind.
    static let reviewEventsAtTenAndEleven = """
        CREATE TABLE review_events (
            id                 TEXT PRIMARY KEY,
            card_id            TEXT NOT NULL REFERENCES study_cards (id) ON DELETE CASCADE,
            grade              INTEGER NOT NULL,
            reviewed_at        REAL NOT NULL,
            before_phase       TEXT NOT NULL,
            before_stability   REAL,
            before_difficulty  REAL,
            before_last_review REAL,
            before_due         REAL,
            after_phase        TEXT NOT NULL,
            after_stability    REAL NOT NULL,
            after_difficulty   REAL NOT NULL,
            after_due          REAL NOT NULL,
            scheduler_version  TEXT NOT NULL,
            retention          REAL NOT NULL,
            card_revision      INTEGER NOT NULL,
            voided_at          REAL,
            CHECK (grade BETWEEN 1 AND 4)
        );
        CREATE INDEX review_events_by_card ON review_events (card_id, reviewed_at);
        """

    @Test func themigrationPreservesEveryLookupAndAddsNoNote() throws {
        let path = path()
        defer { remove(path) }
        do {
            let ledger = try Ledger(path: path)
            for lemma in ["fine", "hold", "bank"] { _ = try ledger.record(lookup(lemma)) }
        }
        try windBack(to: 7, at: path)

        let migrated = try Ledger(path: path)
        #expect(try migrated.studyList(limit: 10).map(\.lemma).sorted() == ["bank", "fine", "hold"])
        #expect(try migrated.history(of: "fine").count == 1)
        #expect(try migrated.notes().isEmpty, "a migration must not enrol anything")
    }

    /// **A copy of the ledger, taken before its shape changed**, so an upgrade the reader wants undone is
    /// undoable. Through the backup API and not a file copy: a database separated from its write-ahead
    /// log loses every write SQLite has not folded in.
    @Test func themigrationLeavesARestorableBackup() throws {
        let path = path()
        defer { remove(path) }
        do {
            let ledger = try Ledger(path: path)
            for lemma in ["fine", "hold"] { _ = try ledger.record(lookup(lemma)) }
        }
        try windBack(to: 7, at: path)
        _ = try Ledger(path: path)

        let backup = path + ".schema7.backup"
        #expect(FileManager.default.fileExists(atPath: backup), "no copy was taken before the migration")
        // The copy opens as a ledger of its own — which is what "restorable" means — and it still holds
        // the reader's lookups. Opening it migrates *it* to 8, which is exactly what restoring would do.
        let restored = try Ledger(path: backup)
        #expect(try restored.studyList(limit: 10).map(\.lemma).sorted() == ["fine", "hold"])
    }

    /// A ledger already at this version is not copied: the backup marks a change of shape, and taking one
    /// on every launch would leave the reader's support directory filling with duplicates of their history.
    @Test func anUpToDateLedgerIsNotBackedUp() throws {
        let path = path()
        defer { remove(path) }
        _ = try Ledger(path: path)
        _ = try Ledger(path: path)
        #expect(!FileManager.default.fileExists(atPath: path + ".schema7.backup"))
        #expect(!FileManager.default.fileExists(atPath: path + ".schema8.backup"))
    }
    /// **The 8 → 9 correction, on a ledger that already has notes in it.** Schema 8 stored `readiness`,
    /// which was wrong: every fact it rests on changes elsewhere, so the column could only ever be right
    /// at the moment it was written. Dropping it must not take the notes with it.
    @Test func themigrationToNineKeepsTheNotesAndDropsTheStoredReadiness() throws {
        let path = path()
        defer { remove(path) }
        let target = StudyTarget.sense(dictionary: "noad", entryID: "e1", senseKey: "e1.001",
                                       senseKeyKind: .publisher)
        let id: UUID
        do {
            let ledger = try Ledger(path: path)
            let lookupID = try ledger.record(lookup("fine"))
            let note = try ledger.enroll(target, issuer: .live, language: "en", chosenBy: .reader,
                                         answer: StudyAnswer(origin: .reader, text: "a penalty"),
                                         lookupID: lookupID, at: now)
            id = note.id
        }
        try windBack(to: 8, at: path)

        let migrated = try Ledger(path: path)
        let notes = try migrated.notes()
        #expect(notes.count == 1, "the correction must not take the reader's targets with it")
        #expect(notes.first?.id == id)
        #expect(notes.first?.target == target)
        // The answer lived in the table schema 9 adds, so winding back removed it: the note is kept and
        // is not askable, which is the honest state for a card with nothing to reveal.
        #expect(try migrated.readiness(of: id) == .needsRepair)
        #expect(notes.first?.confirmedAt == nil, "a column that did not exist is unknown, never guessed")
    }

    // MARK: - Every older schema, to today's shape (audit-fix round 2)

    /// **A ledger migrated from any schema this build still upgrades is the ledger a fresh one is** —
    /// the same columns, constraints, foreign keys, indexes and triggers, read from SQLite. Each step
    /// that altered a table rather than creating it is a place the two could part, and they had: a
    /// schema-9 ledger reached 13 without `is_usable`, so writing an answer, the library and the queue
    /// all failed on the missing column; 8 to 11 kept a `CHECK` that refuses a card the reader wrote;
    /// and every real schema-8 ledger failed its upgrade outright, because `DROP COLUMN` cannot take a
    /// column a `CHECK` names. Reproduced on ledgers built from each version's own SQL before this
    /// existed (the plan's round-2 entry).
    @Test(arguments: [7, 8, 9, 10, 11, 12])
    func aLedgerMigratedFromAnOlderSchemaHasTheShapeOfAFreshOne(version: Int) throws {
        let fresh = path(), old = path()
        defer { remove(fresh); remove(old) }
        _ = try Ledger(path: fresh)
        do {
            let ledger = try Ledger(path: old)
            _ = try ledger.record(lookup("fine"))
        }
        try windBack(to: version, at: old)
        let migrated = try Self.shape(of: try Ledger(path: old))
        let expected = try Self.shape(of: try Ledger(path: fresh))
        for table in Set(expected.keys).union(migrated.keys).sorted() {
            #expect(migrated[table] == expected[table], """
                from schema \(version), \(table) is \(migrated[table].map(String.init(describing:)) ?? "missing") \
                where a fresh ledger has \(expected[table].map(String.init(describing:)) ?? "nothing")
                """)
        }
    }

    /// **And keeps every row while it gets there**, the study rows above all: a table rebuilt with its
    /// parent's foreign keys enforced cascades, and the reader's notes, answers, schedules and histories
    /// would go with it. Written by the shipping code, wound back, migrated, and counted.
    @Test(arguments: [8, 9, 10, 11, 12])
    func themigrationFromAnOlderSchemaKeepsEveryRow(version: Int) throws {
        let path = path()
        defer { remove(path) }
        let usable: UUID, blank: UUID
        do {
            let ledger = try Ledger(path: path)
            let fine = try ledger.record(lookup("fine"))
            let hold = try ledger.record(lookup("hold"))
            usable = try ledger.enroll(
                .sense(dictionary: "noad", entryID: "e1", senseKey: "e1.001", senseKeyKind: .publisher),
                issuer: .live, language: "en", chosenBy: .reader,
                answer: StudyAnswer(origin: .reader, text: "a penalty"), lookupID: fine, at: now).id
            // **Blank to Swift and not to SQL's `trim()`**: the answer the stored verdict exists for. A
            // migration that judged it by default would put a card with nothing on its back in the queue.
            blank = try ledger.enroll(
                .sense(dictionary: "noad", entryID: "e2", senseKey: "e2.001", senseKeyKind: .publisher),
                issuer: .live, language: "en", chosenBy: .reader,
                answer: StudyAnswer(origin: .reader, text: "\t\n\u{3000}"), lookupID: hold, at: now).id
            let card = try #require(try ledger.existingCard(of: usable))
            _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: card.revision,
                                 at: now, using: try MemoryScheduler())
        }
        let before = try Self.rowCounts(at: path)
        try windBack(to: version, at: path)
        let wound = try Self.rowCounts(at: path)
        let migrated = try Ledger(path: path)
        let after = try Self.rowCounts(at: path)
        for (table, count) in wound where count > 0 {
            #expect(after[table] == count, "from schema \(version), \(table) held \(count) rows and now \(after[table] ?? 0)")
        }
        #expect(after["study_notes"] == before["study_notes"], "a note was lost on the way back or forward")
        #expect(try migrated.lookupIDs(evidencing: usable).count == 1, "the note's reading was unlinked")
        // Readable by every query that reads the verdict — the library, the queue and the reading — and
        // the verdict is Swift's.
        let rows = try migrated.library(LibraryQuery())
        #expect(Set(rows.map(\.id)) == [usable, blank])
        _ = try migrated.sittingCandidates(dictionary: nil, introducedSince: now)
        _ = try migrated.reading(ofLookup: 1)
        if version >= 9 {
            #expect(rows.first { $0.id == usable }?.readiness == .ready)
            #expect(rows.first { $0.id == blank }?.readiness == .needsRepair,
                    "an answer of tabs, newlines and an ideographic space was judged usable")
        }
        // A card the reader writes needs the `custom` branch 8 to 11 did not have.
        try migrated.add(StudyNote(target: .custom(dictionary: "noad", text: "my own words"), issuer: .live,
                                   language: "en", createdAt: now))
        try migrated.setReaderAnswer("a fine paid", of: usable, at: now)
    }

    /// Rows per table, read on a connection of its own so nothing is migrated by counting.
    static func rowCounts(at path: String) throws -> [String: Int] {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw LedgerError.sqlite(code: SQLITE_CANTOPEN, message: "cannot open \(path)")
        }
        var tables: [String] = []
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
                           -1, &statement, nil)
        while sqlite3_step(statement) == SQLITE_ROW { tables.append(String(cString: sqlite3_column_text(statement, 0))) }
        sqlite3_finalize(statement)
        var counts: [String: Int] = [:]
        for table in tables {
            sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM \"\(table)\"", -1, &statement, nil)
            if sqlite3_step(statement) == SQLITE_ROW { counts[table] = Int(sqlite3_column_int64(statement, 0)) }
            sqlite3_finalize(statement)
        }
        return counts
    }

    /// What one table *is*, as SQLite reports it: its columns, the `CHECK`s in its definition, its
    /// foreign keys, and the indexes and triggers on it. Order-free, so a column added by `ALTER` at the
    /// end compares equal to the same column declared in place — which is all this schema relies on.
    struct TableShape: Equatable, CustomStringConvertible {
        var columns: Set<String> = []
        var checks: Set<String> = []
        var foreignKeys: Set<String> = []
        var indexes: Set<String> = []
        var triggers: Set<String> = []
        var description: String {
            "columns \(columns.sorted()), checks \(checks.sorted()), foreign keys \(foreignKeys.sorted()), "
                + "indexes \(indexes.sorted()), triggers \(triggers.sorted())"
        }
    }

    static func shape(of ledger: Ledger) throws -> [String: TableShape] {
        var shapes: [String: TableShape] = [:]
        var objects: [(type: String, name: String, table: String, sql: String?)] = []
        try ledger.run("SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
                       bind: []) { row in
            objects.append((try row.text(0), try row.text(1), try row.text(2), row.optionalText(3)))
        }
        for object in objects where object.type == "table" {
            var shape = TableShape()
            try ledger.run("SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_xinfo(?)",
                           bind: [.text(object.name)]) { row in
                shape.columns.insert([try row.text(0), try row.text(1), String(row.integer(2)),
                                      row.optionalText(3) ?? "-", String(row.integer(4))].joined(separator: " "))
            }
            try ledger.run("SELECT \"table\", \"from\", \"to\", on_delete FROM pragma_foreign_key_list(?)",
                           bind: [.text(object.name)]) { row in
                shape.foreignKeys.insert([try row.text(0), try row.text(1), row.optionalText(2) ?? "-",
                                          try row.text(3)].joined(separator: " "))
            }
            shape.checks = Set(checks(in: object.sql ?? ""))
            shapes[object.name] = shape
        }
        for object in objects where object.type == "index" || object.type == "trigger" {
            guard let sql = object.sql else { continue }
            if object.type == "index" { shapes[object.table, default: TableShape()].indexes.insert(normalised(sql)) }
            else { shapes[object.table, default: TableShape()].triggers.insert(normalised(sql)) }
        }
        return shapes
    }

    /// Comments out, whitespace collapsed, and no space inside a parenthesis — so two spellings of one
    /// statement compare equal and two statements never do.
    static func normalised(_ sql: String) -> String {
        sql.split(separator: "\n").map { line in
            line.range(of: "--").map { String(line[..<$0.lowerBound]) } ?? String(line)
        }
        .joined(separator: " ")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        .replacingOccurrences(of: "( ", with: "(").replacingOccurrences(of: " )", with: ")")
    }

    /// Every `CHECK (…)` in a table's definition, table-level and column-level alike, as its expression.
    static func checks(in sql: String) -> [String] {
        let text = normalised(sql)
        var found: [String] = []
        var rest = text[...]
        // A keyword, not a substring: `checked_at` is a column, not a constraint.
        while let check = rest.firstMatch(of: /(?i)\bCHECK ?\(/) {
            rest = rest[check.range.upperBound...]
            rest = text[text.index(before: rest.startIndex)...]
            var depth = 0
            var expression = ""
            for character in rest {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                expression.append(character)
                if depth == 0 { break }
            }
            found.append(expression)
            rest = rest.dropFirst(expression.count)
        }
        return found
    }
}
