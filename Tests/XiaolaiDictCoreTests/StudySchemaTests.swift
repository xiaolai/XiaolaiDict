import DictionaryModel
import Foundation
import SQLite3
import Testing
@testable import XiaolaiDictCore

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

    private func path() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-study-\(UUID().uuidString).sqlite").path
    }

    private func remove(_ path: String) {
        for suffix in ["", "-wal", "-shm", ".schema7.backup"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

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
    private func windBackToSeven(_ path: String) throws {
        let ledger = try Ledger(path: path)
        try ledger.execute("""
            DROP TABLE study_note_lookups;
            DROP TABLE study_locators;
            DROP TABLE study_notes;
            ALTER TABLE sense_encounters DROP COLUMN key_issuer;
            PRAGMA user_version = 7;
            """)
    }

    @Test func themigrationPreservesEveryLookupAndAddsNoNote() throws {
        let path = path()
        defer { remove(path) }
        do {
            let ledger = try Ledger(path: path)
            for lemma in ["fine", "hold", "bank"] { _ = try ledger.record(lookup(lemma)) }
        }
        try windBackToSeven(path)

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
        try windBackToSeven(path)
        _ = try Ledger(path: path)

        let backup = path + ".schema7.backup"
        #expect(FileManager.default.fileExists(atPath: backup), "no copy was taken before the migration")
        // The copy opens as a ledger of its own — which is what "restorable" means — and it still holds
        // the reader's lookups. Opening it migrates *it* to 8, which is exactly what restoring would do.
        let restored = try Ledger(path: backup)
        #expect(try restored.studyList(limit: 10).map(\.lemma).sorted() == ["fine", "hold"])
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: backup + suffix) }
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
}
