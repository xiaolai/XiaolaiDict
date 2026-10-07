import CaptureModel
import DictionaryModel
import Foundation
import SQLite3
import XiaolaiDictBase
import os

/// One lookup, as the ledger stores it (design note §9).
public struct LookupRecord: Equatable, Sendable {
    /// The word as it appeared on screen.
    public let surface: String
    /// Its dictionary form — what collapses running / ran / runs into one entry. Always in
    /// `Lemmatizer.canonical` form, so the same lemma is one entry however it was spelled.
    public let lemma: String
    /// The sentence it was read in; the selection itself when there was none (`quality` says).
    public let context: String
    /// What the lemma rests on — tagger, inferred, ambiguous or surface. It is computed at every
    /// lookup, and before schema 4 it was dropped: the study list grouped by a key that is
    /// sometimes a guess, with nothing recording which. Nil for rows written before schema 4.
    public let lemmaBasis: Lemma.Basis?
    /// The language of the word. A lemma alone collides across languages: *die*, *chat*, *pain*,
    /// *gift*. Nil for rows written before schema 4.
    public let language: String?
    /// How the word was being used, as the selector understood it at lookup time. Computed on
    /// every lookup and, before schema 5, thrown away — which left every history card guessing
    /// from the sentence. Nil for rows written before it, and for lookups where nothing committed.
    public let partOfSpeech: String?
    /// Where `surface` sits in `context`, UTF-16. Required by a card that marks or blanks the word
    /// in the reader's own sentence, and unrecoverable later: "The surprise was no surprise" has
    /// two. Nil when the capture did not know, or for rows written before schema 4.
    public let contextRange: NSRange?
    /// Where it was read, to whatever precision the app could say.
    public let place: ReadingPlace
    /// When the lookup was asked for — not when its answer arrived.
    public let lookedUpAt: Date
    public let result: LookupResult
    /// What answered. Nil only for lookups recorded before the ledger stored it (schemas 1 and 2).
    public let answeredBy: AnswerSource?
    /// The script `surface` is written in, so the drawer can be filtered to the scripts the reader
    /// studies. Nil where nothing could be classified — a number, punctuation, a script this does
    /// not enumerate — and for every row written before schema 7. Both mean unknown, and an
    /// unknown row is drawn.
    public let script: ProbeScript?
    /// How the word and its context were captured. Nil only for lookups recorded before the ledger
    /// stored it (schema 1): unknown, rather than guessed.
    public let quality: CaptureQuality?
    /// The single `source_url` column of schemas 1–3, which conflated a page with a file. Kept as
    /// it was found and never written again: the migration cannot know which of the two any old row
    /// held, and guessing would be worse than leaving it whole and unclaimed.
    public let legacySourceURL: String?
    /// Why no sense was marked, where the selector declined. Recorded from schema 6 on, and never
    /// before — which is why nil means "not recorded", not "a sense was marked". It is what keeps
    /// "the model declined this sentence" (`refused`) apart from "no model here" (`unavailable`).
    public let senseAbstention: Abstention?

    public init(
        surface: String, lemma: String, context: String, lemmaBasis: Lemma.Basis? = nil,
        language: String? = nil, contextRange: NSRange? = nil, partOfSpeech: String? = nil,
        place: ReadingPlace = ReadingPlace(),
        lookedUpAt: Date, result: LookupResult, answeredBy: AnswerSource?, quality: CaptureQuality?,
        legacySourceURL: String? = nil, senseAbstention: Abstention? = nil,
        script: ProbeScript? = nil
    ) {
        self.surface = surface
        self.lemma = Lemmatizer.canonical(lemma)
        self.context = context
        self.lemmaBasis = lemmaBasis
        self.language = language
        self.contextRange = contextRange
        self.partOfSpeech = partOfSpeech
        self.place = place
        self.lookedUpAt = lookedUpAt
        self.result = result
        self.answeredBy = answeredBy
        self.quality = quality
        self.legacySourceURL = legacySourceURL
        self.senseAbstention = senseAbstention
        self.script = script
    }
}

/// How often a lemma has been looked up: the study list's unit.
///
/// The language is part of the unit, not decoration. A lemma alone collides across languages —
/// *die*, *chat*, *pain*, *gift* — which is exactly why schema 4 records it; grouping without it
/// merged English *gift* and German *Gift* into one row of count 2. Found by audit.
public struct LemmaCount: Equatable, Sendable {
    public let lemma: String
    /// Nil for rows written before schema 4, which is *unknown*, and is kept as its own group
    /// rather than folded into any known language.
    public let language: String?
    public let count: Int
    public let lastLookedUpAt: Date

    public init(lemma: String, language: String?, count: Int, lastLookedUpAt: Date) {
        self.lemma = lemma
        self.language = language
        self.count = count
        self.lastLookedUpAt = lastLookedUpAt
    }
}

public enum LedgerError: Error, Equatable {
    case blankSurface
    case blankLemma
    /// A study list cannot have fewer than zero entries. (SQLite would read a negative limit as
    /// "no limit" and return everything.)
    case negativeLimit(Int)
    /// The file was written by a newer XiaolaiDict. Reading it could misinterpret its schema; writing to
    /// it could corrupt it. Refused either way.
    case newerSchema(found: Int, supported: Int)
    /// Opened for reading, the file is at a schema this build does not read: an older one only a
    /// migration — a write — would make readable, or a newer one (`Ledger(readingAt:)`).
    case anotherSchema(found: Int, supported: Int)
    /// A row holds a value this schema does not allow — the file was edited or damaged.
    case corruptRow(String)
    /// The lookup a `LookupIdentity` named is not at its id any more: deleted, and the id perhaps given
    /// to another reading. Nothing was read or written.
    case lookupGone(Int)
    /// A query asked for a column its `SELECT` does not project: a mistake in the query, and **never
    /// the reader's data**. Refused rather than answered from the NULL SQLite would hand back — see
    /// `Ledger.ProjectionFault`.
    case projection(String)
    /// A card asks a question this build has no presentation for. Nothing creates one — every
    /// caller passes `.meaning` — so it means a ledger from a later XiaolaiDict, or one edited.
    case unaskablePrompt(String)
    /// A phrase to save is not spelled as the phrase inventory spells what it files — lowercased, one space
    /// between words, more than one word. Keyed by it, one phrase would become two notes (ADR-0049).
    case notAnInventorySpelling(String)
    case sqlite(code: Int32, message: String)
}

/// Every lookup, one row each. The value is the frequency per lemma — how often the reader failed
/// to know a word — which ranks a study list better than anything starred by hand.
///
/// Not thread-safe: own one from a single actor.
/// An open SQLite handle and the only thing that closes it.
///
/// **This is the fix for a segfault that looked like a missing initialisation.** `Ledger.init` closed
/// its handle when a later step threw — a newer schema, a failed pragma — and Swift then ran `deinit`,
/// which closed it again. The second `sqlite3_close` writes into a connection already freed, and
/// when malloc handed that block to another test's new connection a moment later, the stale close had
/// zeroed it: `openDatabase` read `db->aDb` as null and stored the new B-tree through `0x8`. The
/// crash reports named `sqlite3BtreeOpen + 3104`, which disassembles to exactly that store; the
/// earlier explanation, a null VFS before `sqlite3_initialize` had finished, was the wrong struct.
/// Only reachable through the tests that open a ledger meant to fail, which is why it needed the
/// whole suite's load and came one run in nine.
///
/// A close owned by one object's `deinit` happens once, whatever path the ledger's initialiser takes,
/// so the double close is no longer something the code can express.
final class Connection {
    let handle: OpaquePointer

    init(_ handle: OpaquePointer) { self.handle = handle }

    deinit { sqlite3_close(handle) }
}

public final class Ledger {
    public static let schemaVersion = 13
    /// A mistake in this file's own SQL has to reach the log whatever a caller does with the thrown
    /// error — see `ProjectionFault`. Nothing reader-facing is written here: `XiaolaiDictCore` carries
    /// no display text (ADR-0025).
    static let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "ledger")
    /// How long a write waits for another connection — a second XiaolaiDict, a database browser — to
    /// release its lock before failing. SQLite's default is not to wait at all.
    static let busyTimeoutMilliseconds: Int32 = 2_000

    /// The one owner of the SQLite handle. **The ledger never closes it itself** — see `Connection`.
    private let connection: Connection
    private var db: OpaquePointer { connection.handle }

    /// SQLite's own start-up, run once and to completion before any database is opened.
    ///
    /// **Kept, but it was not the fix it was written as.** It was added for a segfault inside
    /// `openDatabase` — `EXC_BAD_ACCESS` at `0x8` — on the reasoning that `pVfs` was null before
    /// initialisation finished and `mxPathname` sits at offset 8 of `sqlite3_vfs`. The crash came
    /// back with this in place, one full run in nine, and disassembly placed it elsewhere:
    /// `sqlite3BtreeOpen + 3104` is `str x19, [x23]`, the store of the new B-tree through
    /// `&db->aDb[0].pBt`, which is `0x8` when `db->aDb` is null in a connection that had just set
    /// it. That is heap corruption, and its source was a double close — see `Connection`.
    ///
    /// Calling `sqlite3_initialize` once, explicitly, is still correct and costs nothing, so it
    /// stays; the note stays too, because an explanation that fitted the faulting address and was
    /// wrong is worth more written down than deleted.
    private static let sqliteReady: Int32 = sqlite3_initialize()

    /// `path` is a file, created if absent, or ":memory:" for a ledger that lives only as long as
    /// this object.
    public init(path: String) throws {
        guard Self.sqliteReady == SQLITE_OK else {
            throw LedgerError.sqlite(code: Self.sqliteReady, message: "SQLite failed to start")
        }
        let opened = try Self.connection(to: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        // **Nothing is closed on a throw below, and there is no `catch` to say so.** Once
        // `connection` is assigned the ledger is fully initialised, and Swift runs `deinit` for a
        // fully initialised instance even when its initialiser then throws — so a `catch` that
        // closed the handle closed it twice. Measured 2026-09-22: that pattern segfaults on the
        // first failed open under Guard Malloc, and closing once survives 200. `Connection` owns
        // the handle and releases it exactly once; a `catch` here that only rethrows is scaffolding
        // left from the version that did close, and reads as though cleanup were happening.
        connection = opened
        guard sqlite3_busy_timeout(db, Self.busyTimeoutMilliseconds) == SQLITE_OK else { throw error() }
        // Readers no longer block the writer, nor it them. A no-op for ":memory:".
        try run("PRAGMA journal_mode = WAL", bind: []) { _ in }
        try backUpBeforeMigrating(from: path)
        // **Off while the shape changes, then on and read back** (audit-fix round 2). A migration
        // rebuilds the tables whose `CREATE` changed, and dropping a parent table with foreign keys on
        // is a `DELETE` that cascades through its children — the reader's answers, schedules and
        // histories. `migrate()` proves every reference whole with `foreign_key_check` before it
        // commits. Off is SQLite's default; said here, not assumed.
        try run("PRAGMA foreign_keys = OFF", bind: []) { _ in }
        try migrate()
        try enforceForeignKeys()
    }

    /// **A ledger opened for reading, and for nothing else** (audit-fix round 2) — for an instrument
    /// that must change nothing, `--reminder-report` among them.
    ///
    /// One read-only connection, and the version read on it: a file that is not there is not made, one
    /// at another schema is refused rather than upgraded, and SQLite itself refuses every write — the
    /// journal mode, a migration's `BEGIN IMMEDIATE`, an `INSERT` — where the writable door checked the
    /// version and then opened again, so whatever was at the path by the second open was created or
    /// migrated.
    ///
    /// **A write-ahead-log ledger with no log beside it is opened immutable.** macOS's SQLite answers
    /// the first read of one read-only with `SQLITE_CANTOPEN` — measured; the `sqlite3` command line, a
    /// different build, opens it — and that is the shape a ledger has after a restore copies it back
    /// without its sidecars. With no log there is nothing outside the main file to read, so it is read
    /// as it stands: no lock taken, no sidecar made. The cost, said: a writer that opened the file
    /// after the log was found absent could be read mid-checkpoint. The instruments that use this run
    /// with the app stopped.
    public init(readingAt path: String) throws {
        guard Self.sqliteReady == SQLITE_OK else {
            throw LedgerError.sqlite(code: Self.sqliteReady, message: "SQLite failed to start")
        }
        let (opened, found) = try Self.readOnlyConnection(to: path)
        // The same single owner as the writable door: nothing below closes the handle on a throw.
        connection = opened
        guard found == Self.schemaVersion else {
            throw LedgerError.anotherSchema(found: found, supported: Self.schemaVersion)
        }
    }

    /// A read-only connection to `path` that has answered a read, and the schema version it answered.
    private static func readOnlyConnection(to path: String) throws -> (Connection, Int) {
        let plain = try connection(to: path, flags: SQLITE_OPEN_READONLY)
        do {
            return (plain, try userVersion(of: plain))
        } catch LedgerError.sqlite(let code, _) where code == SQLITE_CANTOPEN
                    && !FileManager.default.fileExists(atPath: path + "-wal") {
            let uri = URL(fileURLWithPath: path).absoluteString + "?immutable=1"
            let immutable = try connection(to: uri, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI)
            return (immutable, try userVersion(of: immutable))
        }
    }

    /// `PRAGMA user_version` on `opened`, with SQLite's reason where it fails.
    private static func userVersion(of opened: Connection) throws -> Int {
        func failure() -> LedgerError {
            .sqlite(code: sqlite3_errcode(opened.handle), message: String(cString: sqlite3_errmsg(opened.handle)))
        }
        guard sqlite3_busy_timeout(opened.handle, busyTimeoutMilliseconds) == SQLITE_OK else { throw failure() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(opened.handle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw failure()
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Foreign keys on, and **read back, because declaring them does not make it so.** Off by default
    /// in SQLite, which would make `sense_encounters`' reference to `lookups` decorative: a sense could be
    /// hung off a lookup that does not exist and nothing would say so. The pragma is per connection and
    /// SQLite says nothing when it is refused — the same one line away from decoration that `IndexStore`
    /// measured, where 10 of 12 constraint assertions passed with foreign keys quietly off. Every
    /// `ON DELETE CASCADE` in this schema rests on it.
    private func enforceForeignKeys() throws {
        try run("PRAGMA foreign_keys = ON", bind: []) { _ in }
        var foreignKeysOn = false
        try run("PRAGMA foreign_keys", bind: []) { foreignKeysOn = $0.integer(0) == 1 }
        guard foreignKeysOn else {
            throw LedgerError.sqlite(code: SQLITE_MISUSE, message: "foreign keys could not be enabled")
        }
    }

    /// Returns the row's id, so a sense encounter can be hung off the lookup that produced it.
    @discardableResult
    public func record(_ record: LookupRecord) throws -> Int {
        guard !record.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LedgerError.blankSurface
        }
        guard !record.lemma.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LedgerError.blankLemma
        }
        // `source_url` is not among these: schemas 1–3 conflated a page with a file in it, and
        // schema 4 writes the two apart. Old rows keep theirs, unclaimed.
        try run(
            """
            INSERT INTO lookups (surface, lemma, context, source_app, looked_up_at,
                                 result, answered_by, capture_source, capture_confidence, context_quality,
                                 lemma_basis, language, context_range_location, context_range_length,
                                 source_name, source_document, source_page, source_title, source_title_raw,
                                 source_precision, part_of_speech, sense_abstention, script)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: [
                .text(record.surface), .text(record.lemma), .text(record.context),
                .optionalText(record.place.bundleID),
                .real(record.lookedUpAt.timeIntervalSince1970), .text(record.result.rawValue),
                .optionalText(record.answeredBy?.rawValue),
                .optionalText(record.quality?.source.rawValue), .optionalReal(record.quality?.confidence),
                .optionalText(record.quality?.context.rawValue),
                .optionalText(record.lemmaBasis?.name), .optionalText(record.language),
                record.contextRange.map { SQLiteValue.integer($0.location) } ?? .null,
                record.contextRange.map { SQLiteValue.integer($0.length) } ?? .null,
                .optionalText(record.place.name), .optionalText(record.place.document),
                .optionalText(record.place.page), .optionalText(record.place.title),
                .optionalText(record.place.rawTitle), .text(record.place.precision.rawValue),
                .optionalText(record.partOfSpeech), .optionalText(record.senseAbstention?.rawValue),
                .optionalText(record.script?.rawValue),
            ]
        ) { _ in }
        return Int(sqlite3_last_insert_rowid(db))
    }

    /// One meeting with one sense, hung off the lookup that produced it.
    /// A lookup and the sense it met, written as **one transaction**.
    ///
    /// The two inserts used to be two calls with nothing around them, so an encounter that failed
    /// left the lookup persisted while the caller was told nothing had been recorded. The caller's
    /// answer to that is to drop the lookup id — and the id is what a reader's later tap would have
    /// been hung off, so the row survived unreachable, holding a lookup with no sense and no way to
    /// give it one. Actor isolation does not make two statements atomic; only a transaction does.
    ///
    /// `SAVEPOINT` rather than `BEGIN`, because `migrate()` already runs inside a transaction on
    /// the same connection and SQLite has no nested `BEGIN`. A savepoint nests, and rolls back to
    /// exactly this point.
    @discardableResult
    public func record(_ record: LookupRecord, with encounter: SenseEncounter?) throws -> Int {
        guard let encounter else { return try self.record(record) }
        try execute("SAVEPOINT lookup_with_sense")
        do {
            let lookup = try self.record(record)
            try self.record(encounter, for: lookup)
            try execute("RELEASE lookup_with_sense")
            return lookup
        } catch {
            // Rolled back *and* released: `ROLLBACK TO` rewinds the savepoint without removing it,
            // so a release that never came would leave it on the stack for the connection's life.
            try? execute("ROLLBACK TO lookup_with_sense")
            try? execute("RELEASE lookup_with_sense")
            throw error
        }
    }

    public func record(_ encounter: SenseEncounter, for lookupID: Int) throws {
        try run(
            """
            INSERT INTO sense_encounters (
                lookup_id, dictionary_id, dictionary_name, dictionary_version, entry_id,
                sense_key, sense_key_kind, sense_block, sense_ordinal, entry_sense_count,
                sense_hash, gloss, chosen_by, chosen_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: [
                .integer(lookupID), .text(encounter.dictionary.key), .text(encounter.dictionary.name),
                .optionalText(encounter.dictionary.version), .text(encounter.entryID),
                .optionalText(encounter.senseKey), .text(encounter.senseKeyKind.rawValue),
                encounter.sensePath.map { SQLiteValue.integer($0.block) } ?? .null,
                encounter.sensePath.map { SQLiteValue.integer($0.ordinal) } ?? .null,
                .integer(encounter.entrySenseCount), .optionalText(encounter.senseHash),
                .optionalText(encounter.gloss), .optionalText(encounter.chosenBy?.rawValue),
                .optionalReal(encounter.chosenAt?.timeIntervalSince1970),
            ]
        ) { _ in }
    }

    /// The senses met in one lookup, in the order they were recorded.
    ///
    /// **No surface calls it; it is how `record(_:for:)` is read back** — and, more than that, it is
    /// the only way to see that `delete(lookup:)` takes a lookup's encounters with it. That cascade
    /// is a product promise the drawer's delete rests on, and `ON DELETE CASCADE` firing is not
    /// observable from anything else this type offers.
    public func encounters(ofLookup lookupID: Int) throws -> [SenseEncounter] {
        var found: [SenseEncounter] = []
        try run(
            """
            SELECT dictionary_id, dictionary_name, dictionary_version, entry_id, sense_key,
                   sense_key_kind, sense_block, sense_ordinal, entry_sense_count, sense_hash,
                   gloss, chosen_by, chosen_at
            FROM sense_encounters WHERE lookup_id = ? ORDER BY id
            """,
            bind: [.integer(lookupID)]
        ) { row in
            let identifier = try row.text(0)
            let name = try row.text(1)
            let path: SensePath? = sqlite3_column_type(row.statement, 6) == SQLITE_NULL
                ? nil : SensePath(block: row.integer(6), ordinal: row.integer(7))
            found.append(SenseEncounter(
                dictionary: DictionaryIdentity(
                    name: name,
                    // A key of "name:…" is the marker for a dictionary that had no identifier.
                    identifier: identifier.hasPrefix("name:") ? nil : identifier,
                    version: row.optionalText(2)),
                entryID: try row.text(3), senseKey: row.optionalText(4),
                senseKeyKind: try row.senseKeyKind(5), sensePath: path,
                entrySenseCount: row.integer(8), senseHash: row.optionalText(9),
                gloss: row.optionalText(10), chosenBy: try row.senseChoice(11),
                chosenAt: sqlite3_column_type(row.statement, 12) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: row.real(12))))
        }
        return found
    }

    /// What the reader has met of this lemma before `before`: how many times, and the study items
    /// they landed on.
    ///
    /// **Encounters, not meanings.** The panel's memory strip shows that the reader has been here
    /// and when, and never the gloss they were given last time: an earlier encounter says *you
    /// should know this*, while an earlier gloss answers the question and destroys the retrieval
    /// (`feature-ledger-ux.md` C2). Nothing in this type carries a definition.
    public func priorEncounters(of lemma: String, before: Date, language: String? = nil) throws -> PriorEncounters {
        // Both reads in one transaction. Apart, a write landing between them returns occasions from
        // one snapshot and met senses from another — a strip that says "3rd lookup" beside a sense
        // it claims is new.
        try execute("BEGIN")
        var committed = false
        defer { if !committed { try? execute("ROLLBACK") } }

        var occasions: [PriorEncounter] = []
        try run(
            """
            -- `source_precision` is deliberately not read: `ReadingPlace.precision` derives it
            -- from the fields it describes, and a stored copy that could drift from them is the
            -- cached second truth this project's rules ban. The column stays, for old rows.
            SELECT looked_up_at, source_name, source_app, source_title
            FROM lookups WHERE lemma = ?1 AND looked_up_at < ?2 AND (?3 IS NULL OR language = ?3)
            ORDER BY looked_up_at DESC
            """,
            bind: [.text(Lemmatizer.canonical(lemma)), .real(before.timeIntervalSince1970),
                   .optionalText(language)]
        ) { row in
            occasions.append(PriorEncounter(
                at: Date(timeIntervalSince1970: row.real(0)),
                where: row.optionalText(1) ?? row.optionalText(2),
                title: row.optionalText(3)))
        }
        var met: Set<StudyItem> = []
        try run(
            """
            SELECT s.dictionary_id, s.entry_id, s.sense_key, s.sense_key_kind
            FROM sense_encounters s JOIN lookups l ON s.lookup_id = l.id
            WHERE l.lemma = ?1 AND l.looked_up_at < ?2 AND (?3 IS NULL OR l.language = ?3)
            """,
            bind: [.text(Lemmatizer.canonical(lemma)), .real(before.timeIntervalSince1970),
                   .optionalText(language)]
        ) { row in
            // The four columns *are* the identity, and they are the four `record(_:for:)` writes
            // from the encounter — `dictionary_id` from `DictionaryIdentity.key`, so the read and
            // the write cannot spell a dictionary differently. Built here rather than by way of a
            // `SenseEncounter`, which would need ten more columns this query has no use for.
            met.insert(StudyItem(
                dictionary: try row.text(0), entryID: try row.text(1),
                senseKey: row.optionalText(2), senseKeyKind: try row.senseKeyKind(3)))
        }
        try execute("COMMIT")
        committed = true
        return PriorEncounters(occasions: occasions, met: met)
    }

    /// Lemmas met before, whose newest lookup landed on an entry or sense never seen before.
    ///
    /// This is the query `study-unit.md` §4 calls the point of the whole design: a common word
    /// whose rare sense the reader does not know is the highest-value study item there is, and a
    /// word-level unit cannot express it, because the word is already marked known.
    ///
    /// **Nothing calls it yet** — the study surface it was written for is not built, and
    /// `LedgerStore` does not forward it. Its tests are evidence that the SQL is right, never that
    /// the feature works, and the three comments inside it record defects found by audit rather
    /// than by a reader. It is kept because the query is the hard part and rediscovering it would
    /// cost more than carrying it.
    public func newlyMetSenses(limit: Int) throws -> [NewlyMetSense] {
        guard limit >= 0 else { throw LedgerError.negativeLimit(limit) }
        var found: [NewlyMetSense] = []
        try run(
            """
            -- Only each lemma's **newest** lookup counts. Without this, a sense first met three
            -- lookups ago kept being reported as newly met every time the lemma came up again,
            -- because some *earlier* lookup had not seen it. Found by audit.
            WITH newest AS (
                SELECT id, lemma, language, looked_up_at,
                       ROW_NUMBER() OVER (
                           PARTITION BY lemma, language ORDER BY looked_up_at DESC, id DESC) AS rank
                FROM lookups)
            -- One row per sense **identity**, newest encounter first. A lookup can hold several
            -- encounters for one sense — the selector's guess and then the reader's tap — and both
            -- would otherwise come back as two newly met senses, eating two places of the limit.
            --
            -- `SELECT DISTINCT` was tried here and was worse than the problem: it dedupes the
            -- projected row, so two encounters of one sense with different glosses still returned
            -- twice, and two genuinely different senses whose key strings match under different
            -- kinds collapsed into one — because the kind is not in the projection. Identity is
            -- four columns and the partition has to name all four.
            , met AS (
                SELECT l.lemma, s.dictionary_id, s.entry_id, s.sense_key, s.sense_key_kind,
                       s.gloss, l.looked_up_at, l.id AS lookup_id, s.id AS encounter_id,
                       ROW_NUMBER() OVER (
                           PARTITION BY s.dictionary_id, s.entry_id, s.sense_key, s.sense_key_kind
                           ORDER BY s.id DESC) AS seen
                FROM newest l JOIN sense_encounters s ON s.lookup_id = l.id
                WHERE l.rank = 1)
            SELECT m.lemma, m.dictionary_id, m.entry_id, m.sense_key, m.gloss, m.looked_up_at
            FROM met m
            JOIN newest l ON l.id = m.lookup_id
            JOIN sense_encounters s ON s.id = m.encounter_id
            WHERE m.seen = 1
              AND EXISTS (
                SELECT 1 FROM lookups p
                WHERE p.lemma = l.lemma AND p.language IS NOT DISTINCT FROM l.language
                  -- By (time, id), the order `newest` itself ranks on. Comparing the timestamp
                  -- alone leaves two lookups sharing one timestamp neither newer nor earlier than
                  -- each other, so the lemma has no earlier lookup and reports nothing newly met.
                  AND (p.looked_up_at, p.id) < (l.looked_up_at, l.id))
              AND NOT EXISTS (
                SELECT 1 FROM sense_encounters q JOIN lookups p ON q.lookup_id = p.id
                WHERE p.lemma = l.lemma AND p.language IS NOT DISTINCT FROM l.language
                  AND (p.looked_up_at, p.id) < (l.looked_up_at, l.id)
                  AND q.dictionary_id = s.dictionary_id AND q.entry_id = s.entry_id
                  AND q.sense_key IS NOT DISTINCT FROM s.sense_key
                  -- A `StudyItem` is keyed by its kind as well as its key, so two senses whose key
                  -- strings match under different kinds are two senses. Omitting this reported the
                  -- second of them as already met.
                  AND q.sense_key_kind = s.sense_key_kind)
            ORDER BY m.looked_up_at DESC, m.encounter_id DESC LIMIT ?
            """,
            bind: [.integer(limit)]
        ) { row in
            found.append(NewlyMetSense(
                lemma: try row.text(0), dictionary: try row.text(1), entryID: try row.text(2),
                senseKey: row.optionalText(3), gloss: row.optionalText(4),
                metAt: Date(timeIntervalSince1970: row.real(5))))
        }
        return found
    }

    /// Lemmas the dictionaries had, by how often they were looked up, most first; equal counts put
    /// the most recent first, and equal times the lemma in code-point order, so a list cut at
    /// `limit` is the same list every time.
    ///
    /// **Nothing calls it yet.** `feature-ledger-vocabulary-memory.md` G1 records it as the study
    /// list's query with its surface pending, which is what it still is — and `LedgerStore` does
    /// not forward it.
    public func studyList(limit: Int) throws -> [LemmaCount] {
        guard limit >= 0 else { throw LedgerError.negativeLimit(limit) }
        var list: [LemmaCount] = []
        try run(
            """
            SELECT lemma, language, COUNT(*) AS n, MAX(looked_up_at) AS last FROM lookups
            WHERE result = ? GROUP BY lemma, language
            ORDER BY n DESC, last DESC, lemma ASC, language IS NULL, language ASC LIMIT ?
            """,
            bind: [.text(LookupResult.found.rawValue), .integer(limit)]
        ) { row in
            list.append(LemmaCount(
                lemma: try row.text(0), language: row.optionalText(1), count: row.integer(2),
                lastLookedUpAt: Date(timeIntervalSince1970: row.real(3))))
        }
        return list
    }

    /// Every lookup of `lemma`, found or not, newest first.
    ///
    /// `language` nil means every language — which is what a caller asking "have I ever looked this
    /// spelling up" wants. A caller that knows the language passes it, and does not get another
    /// language's homograph.
    ///
    /// **No surface calls it; it is how `record` is read back.** `recentLookups` is what the drawer
    /// reads, and it projects a `ReadingEntry` rather than a whole `LookupRecord` — so this is the
    /// only thing that returns every column a lookup writes, and every migration test reads through
    /// it. Kept for that: a write path with no read-back is a write path nothing can check.
    public func history(of lemma: String, language: String? = nil) throws -> [LookupRecord] {
        var records: [LookupRecord] = []
        try run(
            """
            SELECT surface, lemma, context, source_app, source_url, looked_up_at,
                   result, answered_by, capture_source, capture_confidence, context_quality,
                   lemma_basis, language, context_range_location, context_range_length,
                   source_name, source_document, source_page, source_title, source_title_raw,
                   part_of_speech, sense_abstention, script
            -- Numbered, not bare: a bare `?` is parameter 1, so `?1` beside it would alias the
            -- lemma rather than the language.
            FROM lookups WHERE lemma = ?1 AND (?2 IS NULL OR language = ?2)
            ORDER BY looked_up_at DESC, id DESC
            """,
            bind: [.text(Lemmatizer.canonical(lemma)), .optionalText(language)]
        ) { row in
            let range: NSRange? = sqlite3_column_type(row.statement, 13) == SQLITE_NULL
                ? nil : NSRange(location: row.integer(13), length: row.integer(14))
            records.append(LookupRecord(
                surface: try row.text(0), lemma: try row.text(1), context: try row.text(2),
                lemmaBasis: try row.lemmaBasis(11), language: row.optionalText(12), contextRange: range,
                partOfSpeech: row.optionalText(20),
                place: ReadingPlace(
                    bundleID: row.optionalText(3), name: row.optionalText(15),
                    document: row.optionalText(16), page: row.optionalText(17),
                    title: row.optionalText(18), rawTitle: row.optionalText(19)),
                lookedUpAt: Date(timeIntervalSince1970: row.real(5)),
                result: try row.result(6), answeredBy: try row.answerSource(7), quality: try row.quality(8),
                legacySourceURL: row.optionalText(4), senseAbstention: try row.abstention(21),
                script: try row.optional(ProbeScript.self, 22, "lookups.script")))
        }
        return records
    }

    /// A JSON array of strings, for a bound `json_each` parameter. Written here rather than with
    /// `JSONEncoder` because the values are a closed enum's raw values — no escaping is reachable —
    /// and a throwing encoder inside a query builder would have to invent a failure mode.
    static func jsonArray(of values: [String]) -> String {
        "[" + values.sorted().map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    /// What the history drawer reads: lookups since `since`, newest first, at most `limit` of them.
    ///
    /// **It does join the gloss, and that changed on 2026-09-20.** This comment used to say the
    /// query had no column to supply a definition, which was the second half of C2's enforcement —
    /// and it stayed here, false, after `se.gloss` was added below. The rule is intact but it is
    /// held elsewhere now: the card carries the gloss and shows it only when the reader asks, and
    /// `HiddenGlossTests` fails if a card's height ever depends on the length of one.
    ///
    /// **The reading a card is built from, projected once.**
    ///
    /// Twenty-five columns, and two callers want them: the drawer's window of recent lookups, and the
    /// review surface asking for the one reading a study note rests on. A second copy is a second
    /// reader of one rule — the shape that let `history()` read a `part_of_speech` its own SELECT never
    /// projected and answer nil for every row while passing every test.
    static func readingProjection(withStudy: Bool) -> String {
        """
            SELECT l.id, l.surface, l.lemma, l.context, l.looked_up_at, l.result,
                   l.context_range_location, l.context_range_length,
                   l.source_app, l.source_name, l.source_document, l.source_page,
                   l.source_title, l.source_title_raw,
                   -- How good the capture was. A card cannot honour "a degraded capture never
                   -- renders as confidently as a clean one" without it, and `context` alone cannot
                   -- be read for it: the selection itself is stored there when nothing surrounded
                   -- the word, which is indistinguishable from a one-word sentence.
                   l.capture_source, l.capture_confidence, l.context_quality,
                   l.part_of_speech,
                   -- Which sense was met, and what it said. The gloss comes along because the
                   -- reader can ask for it; it is not shown unless they do, which is what keeps
                   -- C2 intact. What the card shows unasked is *which* sense, never its wording.
                   se.dictionary_name, se.sense_block, se.sense_ordinal, se.entry_sense_count,
                   se.gloss, se.chosen_by,
                   -- Why no sense was marked, where the selector declined: "the model declined"
                   -- and "no model here" are different facts, and the card can say which.
                   l.sense_abstention,
                   -- **Appended, never inserted.** Every reader of this projection is
                   -- positional, so a column added in the middle silently re-points all of
                   -- them. The tail is the only safe end.
                   l.language, l.disposition,
                   -- The note this reading is kept under and readiness's facts about it, all off
                   -- **one** association: the answer revealed beside "Confirm this meaning" must
                   -- belong to the note that confirming reaches.
                   -- And the encounter of *that note's* target, for the labels beside it: the
                   -- newest encounter above can be an auxiliary tap, and a primary note's meaning
                   -- drawn under another dictionary's name and sense is a misattribution.
                   \(withStudy ? """
                       kn.id, kn.confirmed_at, kn.target_kind, ka.is_usable, ka.text, ka.origin,
                       ks.dictionary_name, ks.sense_block, ks.sense_ordinal, ks.entry_sense_count,
                       ks.gloss, ks.chosen_by
                       """ : "NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL")
            FROM lookups l
            -- By id rather than by lookup_id, so a lookup with more than one encounter contributes
            -- one row and not several. Only the primary dictionary is recorded, so there should be
            -- at most one — "should be" is not a thing to build a join on.
            LEFT JOIN sense_encounters se ON se.id = (
                SELECT id FROM sense_encounters WHERE lookup_id = l.id ORDER BY id DESC LIMIT 1
            )
            \(withStudy ? """
                -- **The word's own note.** A phrase saved from this reading is linked to it as its cue,
                -- and is not what the reading is kept under (ADR-0049): taken as the newest link, it
                -- became what the history card revealed under the word and what the lookup card's
                -- status read — the phrase's meaning shown as the word's, and "Saved" for a word that
                -- was not. **Excluded by name**, so a kind this build cannot read still reaches the decoder
                -- below and is refused, rather than filtered out of sight here.
                LEFT JOIN study_notes kn ON kn.id = (
                    SELECT nl.note_id FROM study_note_lookups nl
                    JOIN study_notes word ON word.id = nl.note_id AND word.target_kind <> 'phrase'
                    WHERE nl.lookup_id = l.id
                    ORDER BY nl.recorded_at DESC, nl.note_id DESC LIMIT 1)
                LEFT JOIN study_answers ka ON ka.note_id = kn.id
                -- The newest encounter in this reading that is the note's own target: its
                -- dictionary and entry, and its sense key where the note is a sense — an entry
                -- rung's encounter carries none it can key. No such encounter is no label, never
                -- someone else's.
                LEFT JOIN sense_encounters ks ON ks.id = (
                    SELECT id FROM sense_encounters
                    WHERE lookup_id = l.id AND dictionary_id = kn.dictionary AND entry_id = kn.entry_id
                      AND ((kn.target_kind = 'sense' AND sense_key = kn.sense_key
                            AND sense_key_kind = kn.sense_key_kind)
                           OR (kn.target_kind = 'entry' AND (sense_key IS NULL OR sense_key_kind = 'none')))
                    ORDER BY id DESC LIMIT 1)
                """ : "")
        """
    }

    /// **Lookup integrity is a gate; study damage is a report.** A dangling reference in a lookup
    /// table means the upgrade itself is wrong, and it aborts loudly. One in a study table is optional
    /// storage already broken — a link left behind by a `study_notes` that is gone — and aborting on it
    /// took the lookup path down with it, against ADR-0034. So it is logged, and study reports itself
    /// unavailable where it is used.
    ///
    /// A table is study's when a study schema creates it, read off the schema constants, so a new
    /// study table is covered without a list to update — and a table nobody classified is checked as
    /// a lookup table, failing closed.
    private func checkForeignKeysAfterMigrating() throws {
        var lookupViolations: [String] = [], studyViolations = 0
        try run("PRAGMA foreign_key_check", bind: []) { row in
            let table = try row.text(0)
            if Self.studyTables.contains(table) { studyViolations += 1 } else { lookupViolations.append(table) }
        }
        if studyViolations > 0 {
            Self.log.error("study storage has \(studyViolations) dangling references; lookups upgraded regardless")
        }
        guard lookupViolations.isEmpty else {
            throw LedgerError.corruptRow("foreign keys in \(Set(lookupViolations).sorted().joined(separator: ", "))")
        }
    }

    /// Every table a study schema creates.
    static let studyTables: Set<String> = Set(
        [studySchema, studyAnswerSchema, studyCardSchema, studyOrganisationSchema, studyKeepingSchema]
            .flatMap { schema in
                schema.components(separatedBy: "CREATE TABLE ").dropFirst().map { rest in
                    String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                }
            })

    /// Whether this database holds a table called `name`.
    func hasTable(_ name: String) throws -> Bool {
        var found = false
        try run("SELECT EXISTS (SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
                bind: [.text(name)]) { found = $0.integer(0) == 1 }
        return found
    }

    /// Lookup remains usable when optional study storage is unavailable: the study columns read as
    /// NULL — no note — rather than the reading failing (ADR-0034).
    func availableReadingProjection() throws -> String {
        var count = 0
        try run("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('study_notes','study_note_lookups','study_answers')", bind:[]) { count = $0.integer(0) }
        return Self.readingProjection(withStudy: count == 3)
    }

    /// Misses come back too, marked. A lookup that found nothing is usually a typo or a stray
    /// selection, and telling that from a real gap is the reason the row was recorded at all.
    ///
    /// It does carry `capture_quality`, which is not a definition but a warning label: it is what
    /// lets a card tell a sentence from the word echoed back into the context column.
    /// The drawer's query.
    ///
    /// `studying` is required rather than defaulted, so every caller states which scripts the
    /// reader wants to see. A default of "everything" would be the quiet option: a surface that
    /// forgot to pass the setting would go on showing rows the reader had filtered out, and look
    /// exactly like a setting that does not work.
    public func recentLookups(
        since: Date, limit: Int, studying: Set<ProbeScript>
    ) throws -> [ReadingEntry] {
        // A limit of none asks for nothing. SQLite reads a *negative* LIMIT as no limit at all,
        // so this guard is what stops `limit: -1` returning a ledger years deep. (`LIMIT 0`
        // genuinely returns nothing; an earlier version of this comment claimed otherwise.)
        guard limit > 0 else { return [] }

        var entries: [ReadingEntry] = []
        // One tagger for the batch: building an `NLTagger` is the expensive part, and every row
        // written before schema 5 needs one.
        let tagging = Lemmatizer.Pass()
        try run(
            """
            \(try availableReadingProjection())
            WHERE l.disposition = 'kept' AND l.looked_up_at >= ?1
              -- The reader's script filter, applied by SQLite so `LIMIT` still counts rows they
              -- will actually see. `IS NULL` first and deliberately: every row written before
              -- schema 7 has no script, and unknown is drawn rather than dropped.
              AND (l.script IS NULL OR l.script IN (SELECT value FROM json_each(?3)))
            -- The row id breaks a tie, so two lookups sharing a timestamp keep their order between
            -- one reading of the drawer and the next.
            ORDER BY l.looked_up_at DESC, l.id DESC
            LIMIT ?2
            """,
            // The script set travels as a JSON array read by `json_each`, so the predicate is one
            // bound parameter however many scripts the reader studies. Interpolating an `IN` list
            // would build SQL out of values, which this file does nowhere.
            bind: [.real(since.timeIntervalSince1970), .integer(limit),
                   .text(Self.jsonArray(of: studying.map(\.rawValue)))]
        ) { entries.append(try Self.reading(from: $0, tagging: tagging)) }
        return entries
    }

    /// One `ReadingEntry` out of a row of `readingProjection`. **One builder, for the same reason as
    /// the projection**: a card built by the review surface and one built by the drawer are the same
    /// card, and two constructions of it drift a column at a time.
    static func reading(from row: Row, tagging: Lemmatizer.Pass) throws -> ReadingEntry {
        let range: NSRange? = sqlite3_column_type(row.statement, 6) == SQLITE_NULL
            ? nil : NSRange(location: row.integer(6), length: row.integer(7))
        let surface = try row.text(1)
        let context = try row.text(3)
        // Stored where schema 5 recorded it; tagged from the reader's own sentence where it did not.
        // `??` rather than a branch, because "recorded" and "derived" are the same answer to the card
        // — the difference is in how much evidence stands behind it, and that is not a difference a
        // part-of-speech label asks anyone to act on.
        let partOfSpeech = row.optionalText(17)
            ?? tagging.partOfSpeech(of: surface, in: context, at: range)
        return ReadingEntry(
            id: row.integer(0), lemma: try row.text(2), surface: surface,
            sentence: context, sentenceRange: range,
            place: ReadingPlace(
                bundleID: row.optionalText(8), name: row.optionalText(9),
                document: row.optionalText(10), page: row.optionalText(11),
                title: row.optionalText(12), rawTitle: row.optionalText(13)),
            at: Date(timeIntervalSince1970: row.real(4)),
            result: try row.result(5), quality: try row.quality(14),
            partOfSpeech: partOfSpeech, sense: try row.senseNote(18),
            senseAbstention: try row.abstention(24), language: row.optionalText(25),
            // NOT NULL with a default, so only a value this build cannot name reaches the `??`, and that
            // is refused above it rather than read as kept.
            disposition: try row.optional(LookupDisposition.self, 26, "lookups.disposition") ?? .kept,
            studyNoteID: try row.optionalUUID(27, "study_notes.id"),
            studyStatus: row.isNull(27) ? nil : StudyReadiness.of(try readinessFacts(from: row)),
            studyAnswer: row.optionalText(31), studySense: try row.senseNote(33),
            studyObstacle: row.isNull(27) ? nil : StudyReadiness.obstacle(try readinessFacts(from: row)))
    }

    /// Readiness's facts about the note a reading is kept under — **facts, not a verdict**: the rule is
    /// `StudyReadiness.of`, and a second spelling of it here disagreed with the library about every
    /// entry rung the reader had answered in their own words.
    private static func readinessFacts(from row: Row) throws -> StudyReadiness.Facts {
        let kind = try row.optional(StudyTarget.Kind.self, 29, "study_notes.target_kind")
        return StudyReadiness.Facts(
            isConfirmed: !row.isNull(28),
            hasUsableAnswer: !row.isNull(30) && row.integer(30) == 1,
            answerIsPublishers: row.optionalText(32) == StudyAnswer.Origin.dictionary.rawValue,
            isEntryRung: kind == .entry,
            // Reached through this very reading's link, so a reading evidences it by construction.
            hasReading: true,
            // A reading cannot ask a dictionary anything, so it never claims a sense moved.
            senseMoved: false,
            needsReading: kind != .custom)
    }

    /// The reading a lookup was, for a surface that knows which lookup it wants.
    /// The newest lookup's id, or 0 when there are none.
    public func newestLookupID() throws -> Int {
        var newest = 0
        try run("SELECT COALESCE(MAX(id), 0) FROM lookups", bind: []) { newest = $0.integer(0) }
        return newest
    }

    /// Removes every lookup above `baseline`, and with each the senses met in it.
    ///
    /// **For an instrument putting back what it added**, never for the reader: the baseline is an
    /// id taken before the writes, so this cannot reach a row that was already there.
    public func deleteLookups(after baseline: Int) throws {
        try run("DELETE FROM lookups WHERE id > ?", bind: [.integer(baseline)]) { _ in }
    }

    public func reading(ofLookup id: Int) throws -> ReadingEntry? {
        var found: ReadingEntry?
        let tagging = Lemmatizer.Pass()
        try run("\(try availableReadingProjection())\nWHERE l.id = ?1", bind: [.integer(id)]) { row in
            found = try Self.reading(from: row, tagging: tagging)
        }
        return found
    }

    /// Removes one lookup, and with it every sense encounter hung off it.
    ///
    /// **A real delete, not a hidden row.** The reader's reason for reaching for this is a word
    /// they did not mean to look up — a stray selection, a mistyped hotkey — and a history that
    /// only *pretends* to forget is worse than one that cannot: it keeps the noise and lies about
    /// it. The encounters go too, by `ON DELETE CASCADE` and the `foreign_keys` pragma this ledger
    /// opens with; a sense met only in a lookup that never happened was never met.
    ///
    /// Silent about an id that is not there. Two drawers open on the same ledger, or a click that
    /// arrives after a reload, must not be an error — the row is gone either way, which is what
    /// the caller asked for.
    public func delete(lookup id: Int) throws {
        try run("DELETE FROM lookups WHERE id = ?1", bind: [.integer(id)]) { _ in }
    }

    // MARK: - Schema

    /// A consistent copy of the ledger beside it, taken before a migration changes its shape.
    ///
    /// **Through SQLite's backup API, never by copying the file.** A ledger separated from its
    /// write-ahead log loses every write SQLite has not folded in — measured here as a 449 KB log against
    /// a 40 KB database — so a copy of `ledger.sqlite` alone is a copy of an older ledger. The backup API
    /// reads through the WAL and writes one consistent file, which is the whole reason to use it.
    ///
    /// **It throws when it cannot.** This is the one moment the reader's history changes shape, and a
    /// machine with no room for a copy of it is a condition they are owed before the rewrite rather than
    /// after. The alternative — migrate anyway and mention it — is the quiet default this project spends
    /// its time removing.
    ///
    /// Skipped for `:memory:`, which has nothing to lose, and for a database at version 0, which is one
    /// this process is about to create.
    private func backUpBeforeMigrating(from path: String) throws {
        guard path != ":memory:" else { return }
        var found = 0
        try run("PRAGMA user_version", bind: []) { found = $0.integer(0) }
        guard found > 0, found < Self.schemaVersion else { return }
        try backUp(to: "\(path).schema\(found).backup")
    }

    /// **Opens `path`, or throws with SQLite's reason**, closing the handle `sqlite3_open_v2` returns
    /// alongside a failure — which nothing else will close. One copy, for the writable door and the
    /// reading one, so the failed-open close stays one shape in this file (`LedgerConnectionTests`).
    private static func connection(to path: String, flags: Int32) throws -> Connection {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw LedgerError.sqlite(code: status, message: message)
        }
        return Connection(handle)
    }

    /// Writes a consistent copy of this ledger to `path`, replacing whatever was there.
    ///
    /// Public because recovery is a reader-facing operation, not only a migration's private step: the
    /// same copy is what a reader keeps before an upgrade they may want to undo.
    public func backUp(to path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard status == SQLITE_OK, let opened else {
            // The handle `sqlite3_open_v2` returns alongside a failure, which nothing else will close.
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(opened)
            throw LedgerError.sqlite(code: status, message: "backup: \(message)")
        }
        // **One owner releases it, as the source handle has**, rather than a `defer` beside the throws
        // below — the discipline ADR-0019 exists for. Two closes of one handle is a use-after-free, and
        // a second place in this file spelling its own cleanup is how the first one came about.
        let destination = Connection(opened)
        func failure() -> LedgerError {
            .sqlite(code: sqlite3_errcode(destination.handle),
                    message: "backup: \(String(cString: sqlite3_errmsg(destination.handle)))")
        }
        guard let backup = sqlite3_backup_init(destination.handle, "main", db, "main") else {
            throw failure()
        }
        // -1 copies every page in one step, so there is no partially copied state to reason about.
        let stepped = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard stepped == SQLITE_DONE, finished == SQLITE_OK else { throw failure() }
    }

    /// One transaction, taken before the version is read: two processes opening an old file at
    /// once must not both decide to migrate it.
    private func migrate() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            var found = 0
            try run("PRAGMA user_version", bind: []) { found = $0.integer(0) }
            guard found <= Self.schemaVersion else {
                throw LedgerError.newerSchema(found: found, supported: Self.schemaVersion)
            }
            guard found < Self.schemaVersion else { return try execute("COMMIT") }
            if found < 1 {
                try execute(
                    """
                    CREATE TABLE lookups (
                        id INTEGER PRIMARY KEY,
                        surface TEXT NOT NULL,
                        lemma TEXT NOT NULL,
                        context TEXT NOT NULL,
                        source_app TEXT,
                        source_url TEXT,
                        looked_up_at REAL NOT NULL
                    );
                    CREATE INDEX lookups_by_lemma ON lookups (lemma, looked_up_at);
                    """)
            }
            if found < 2 {
                // Schema 1 recorded only lookups that found something, so 'found' is a fact about
                // its rows, not a guess. How they were captured was not kept: those stay NULL.
                try execute(
                    """
                    ALTER TABLE lookups ADD COLUMN result TEXT NOT NULL DEFAULT 'found';
                    ALTER TABLE lookups ADD COLUMN capture_source TEXT;
                    ALTER TABLE lookups ADD COLUMN capture_confidence REAL;
                    ALTER TABLE lookups ADD COLUMN context_quality TEXT;
                    """)
                try canonicalizeLemmas()
            }
            if found < 3 {
                // What answered was not kept before schema 3: those rows stay NULL, unknown.
                try execute("ALTER TABLE lookups ADD COLUMN answered_by TEXT;")
            }
            if found < 4 {
                // Every one of these was computed at lookup time and thrown away here. Old rows get
                // NULL, which means unknown — never a guessed value.
                //
                // `source_url` is deliberately left alone rather than split into `source_page` and
                // `source_document`: it held whichever of the two the app happened to expose, and a
                // page URL can itself be a `file://`, so nothing can tell them apart after the
                // fact. It is kept whole and never written again.
                try execute(
                    """
                    ALTER TABLE lookups ADD COLUMN lemma_basis TEXT;
                    ALTER TABLE lookups ADD COLUMN language TEXT;
                    ALTER TABLE lookups ADD COLUMN context_range_location INTEGER;
                    ALTER TABLE lookups ADD COLUMN context_range_length INTEGER;
                    ALTER TABLE lookups ADD COLUMN source_name TEXT;
                    ALTER TABLE lookups ADD COLUMN source_document TEXT;
                    ALTER TABLE lookups ADD COLUMN source_page TEXT;
                    ALTER TABLE lookups ADD COLUMN source_title TEXT;
                    ALTER TABLE lookups ADD COLUMN source_title_raw TEXT;
                    ALTER TABLE lookups ADD COLUMN source_precision TEXT;
                    CREATE TABLE sense_encounters (
                        id INTEGER PRIMARY KEY,
                        lookup_id INTEGER NOT NULL REFERENCES lookups (id) ON DELETE CASCADE,
                        dictionary_id TEXT NOT NULL,
                        dictionary_name TEXT NOT NULL,
                        dictionary_version TEXT,
                        -- `DictionaryEntry.entryKey`, not the raw `d:entry` id: for a bundle
                        -- whose ids are regenerated on import, a marked headword. Rows written
                        -- before that distinction existed hold a converter id for those
                        -- dictionaries and will not match new ones. They are left as they are —
                        -- the headword they would need is not recorded, and inventing one would
                        -- be a guess dressed as history. Those keys were never stable anyway,
                        -- which is the defect this note is the tail of.
                        entry_id TEXT NOT NULL,
                        sense_key TEXT,
                        sense_key_kind TEXT NOT NULL,
                        sense_block INTEGER,
                        sense_ordinal INTEGER,
                        entry_sense_count INTEGER NOT NULL,
                        sense_hash TEXT,
                        gloss TEXT,
                        chosen_by TEXT,
                        chosen_at REAL
                    );
                    CREATE INDEX sense_encounters_by_lookup ON sense_encounters (lookup_id);
                    CREATE INDEX sense_encounters_by_item
                        ON sense_encounters (dictionary_id, entry_id, sense_key);
                    """)
            }
            if found < 5 {
                // Computed at every lookup since the selector existed, and thrown away here. Rows
                // written before this get NULL, and the history drawer tags them from the reader's
                // own sentence rather than showing a hole — a guess that says so, never a stored
                // value that cannot be told from a recorded one.
                try execute("ALTER TABLE lookups ADD COLUMN part_of_speech TEXT;")
            }
            if found < 6 {
                // Why the selector declined was decided at every lookup and kept nowhere, so a
                // model refusing a sentence and no model being here left the same trace: none.
                // Rows written before this get NULL — not recorded, never a guessed reason.
                try execute("ALTER TABLE lookups ADD COLUMN sense_abstention TEXT;")
            }
            if found < 7 {
                // The script the word is written in, so the drawer can be filtered to the scripts
                // the reader studies — the same setting the hover gate asks, and asked the same
                // way, because one setting answered by two different rules is a filter that reads
                // as broken. Derived at read time it could not be a SQL predicate, and a filter
                // applied after `LIMIT` hands back fewer cards than were asked for.
                //
                // NULL for every row written before this, meaning unknown. `recentLookups` draws
                // those: hiding history that cannot be classified would empty the reader's past
                // after an update, with a filter they never set to blame.
                try execute("ALTER TABLE lookups ADD COLUMN script TEXT;")
            }
            if found < 8 {
                // The study system's durable entities — WI-001. Additive: no card is backfilled, no
                // confirmation inferred, and no row of the reading history re-read or reinterpreted.
                try execute(Self.studySchema)
                // Which extractor issued the key on an encounter. NULL for every row written before
                // this, meaning **unknown** — and unknown it stays: every encounter so far came from
                // the live path, but "so far as anyone can tell" is not a measurement, and a guessed
                // provenance is worse than an absent one because it cannot be told from a recorded one.
                try execute("ALTER TABLE sense_encounters ADD COLUMN key_issuer TEXT;")
            }
            // Every step that alters a study table asks whether it is there: one whose study tables are
            // gone still upgrades for lookup, because a broken study system still looks words up
            // (ADR-0034). The steps that *create* study tables need no guard.
            // **A table whose `CREATE` changed is rebuilt from today's statement, its rows kept**
            // (audit-fix round 2). `ALTER` cannot change a `CHECK`, and `DROP COLUMN` cannot take a
            // column a `CHECK` names — so altering, as these steps once did, failed every real schema-8
            // ledger outright (`readiness` sits under one), left 8 to 11 refusing a card the reader wrote
            // (no `custom` before 12), and took a schema-9 ledger to 13 without `is_usable`, breaking
            // every answer write and every query that reads the verdict. A test winding a ledger back to
            // today's shape minus a column could not see any of it; the ones that wind back to the
            // historic statements, and real ledgers built from each version's own SQL, did.
            if (8...11).contains(found), try hasTable("study_notes") {
                // 8 stored `readiness`, which every fact it rests on changes elsewhere, so it is dropped;
                // `confirmed_at` arrived with 9, so an 8's notes are unconfirmed — unknown, never guessed.
                try rebuild("study_notes", from: Self.studyNotesSchema)
            }
            if found < 9 {
                try execute(Self.studyAnswerSchema)
            } else if found < 11, try hasTable("study_answers") {
                // 9 and 10 had SQL judge whether an answer was blank, with `trim()`, which removes
                // ordinary spaces and nothing else. Swift's judgement is stored from 11 on, and the rows
                // are re-judged by it here rather than by a SQL approximation of it.
                try rebuild("study_answers", from: Self.studyAnswerSchema, filling: ["is_usable": "1"])
                var rows: [(String, String)] = []
                try run("SELECT note_id, text FROM study_answers", bind: []) { row in
                    rows.append((try row.text(0), try row.text(1)))
                }
                for (id, text) in rows {
                    let usable = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    try run("UPDATE study_answers SET is_usable = ? WHERE note_id = ?",
                            bind: [.integer(usable ? 1 : 0), .text(id)]) { _ in }
                }
            }
            if found < 10 {
                // The scheduled card and its review history. Additive, and no card is created for a
                // note that already exists: a schedule invented for a target the reader enrolled
                // before there was one would be a first review they never sat.
                try execute(Self.studyCardSchema)
            } else if found < 12, try hasTable("review_events") {
                // 10 and 11 had no `kind`: every event they wrote was a graded one, which the column's
                // default says.
                try rebuild("review_events", from: Self.reviewEventsSchema)
            }
            if found < 12 {
                // WI-007's tags: the reader's own labels, belonging to no dictionary.
                try execute(Self.studyOrganisationSchema)
            }
            if found < 13 {
                try execute(Self.keepingSchema)
                if try hasTable("study_notes") { try execute(Self.studyKeepingSchema) }
            }
            try checkForeignKeysAfterMigrating()
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
            try execute("COMMIT")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// **One table brought to today's statement, every row kept**: copied aside, dropped, created from
    /// `schema`, and copied back by the columns the two shapes share — `filling` names a value for a
    /// column today's adds without a default. Only inside `migrate()`, whose transaction makes it all or
    /// nothing, and only with foreign keys off: dropping a parent table with them on is a `DELETE` that
    /// cascades through every child. `checkForeignKeysAfterMigrating` then proves the children still
    /// point at something.
    private func rebuild(_ table: String, from schema: String, filling: [String: String] = [:]) throws {
        try execute("""
            DROP TABLE IF EXISTS temp.migrating;
            CREATE TEMP TABLE migrating AS SELECT * FROM main.\(table);
            DROP TABLE main.\(table);
            """)
        try execute(schema)
        func columns(of name: String, in database: String) throws -> [String] {
            var names: [String] = []
            try run("SELECT name FROM pragma_table_info(?, ?)", bind: [.text(name), .text(database)]) {
                names.append(try $0.text(0))
            }
            return names
        }
        let before = try columns(of: "migrating", in: "temp")
        let after = try columns(of: table, in: "main")
        let shared = after.filter(before.contains)
        let filled = after.filter { !before.contains($0) && filling[$0] != nil }
        let into = (shared + filled).joined(separator: ", ")
        let values = (shared + filled.compactMap { filling[$0] }).joined(separator: ", ")
        try execute("""
            INSERT INTO main.\(table) (\(into)) SELECT \(values) FROM temp.migrating;
            DROP TABLE temp.migrating;
            """)
    }

    /// Schema 1 stored lemmas as given; `LookupRecord` now writes them in canonical form, and older
    /// rows are brought into line so each lemma is one study-list entry.
    private func canonicalizeLemmas() throws {
        var changed: [(id: Int, lemma: String)] = []
        try run("SELECT id, lemma FROM lookups", bind: []) { row in
            let stored = try row.text(1)
            let canonical = Lemmatizer.canonical(stored)
            if canonical != stored { changed.append((row.integer(0), canonical)) }
        }
        for row in changed {
            try run("UPDATE lookups SET lemma = ? WHERE id = ?", bind: [.text(row.lemma), .integer(row.id)]) { _ in }
        }
    }

    // MARK: - SQLite plumbing

    /// Every value a statement can bind. Exhaustive, so a new kind of value is a compile error
    /// rather than a silent NULL.
    enum SQLiteValue {
        case text(String)
        case integer(Int)
        case real(Double)
        case null

        static func optionalText(_ value: String?) -> SQLiteValue { value.map(SQLiteValue.text) ?? .null }
        static func optionalReal(_ value: Double?) -> SQLiteValue { value.map(SQLiteValue.real) ?? .null }
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard status == SQLITE_OK else {
            throw LedgerError.sqlite(code: status, message: message.map { String(cString: $0) } ?? "")
        }
    }

    func run(_ sql: String, bind values: [SQLiteValue], row: (Row) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error()
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32 =
                switch value {
                case .text(let text):
                    // By byte count, not to the first NUL: a string may contain one.
                    text.utf8CString.withUnsafeBufferPointer { buffer in
                        sqlite3_bind_text64(statement, index, buffer.baseAddress, sqlite3_uint64(buffer.count - 1),
                                            transient, UInt8(SQLITE_UTF8))
                    }
                case .integer(let number): sqlite3_bind_int64(statement, index, sqlite3_int64(number))
                case .real(let number): sqlite3_bind_double(statement, index, number)
                case .null: sqlite3_bind_null(statement, index)
                }
            guard status == SQLITE_OK else { throw error() }
        }
        // Shared by every row of this statement, so the first bad read is the one reported.
        let fault = ProjectionFault()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                do {
                    try row(Row(statement: statement, fault: fault))
                } catch {
                    // **The cause, not the symptom.** A text column read past the end is NULL, which
                    // `text(_:)` reports as a corrupt row — true of the value and useless about why.
                    if let what = fault.first { throw LedgerError.projection(what) }
                    throw error
                }
                // Per row rather than at the end, so a whole result set is not decoded from NULLs first.
                if let what = fault.first { throw LedgerError.projection(what) }
            case SQLITE_DONE: return
            default: throw error()
            }
        }
    }

    /// Where a read outside a query's projection is recorded, so `run` can refuse the query **instead of
    /// ending the process**.
    ///
    /// This was a `precondition` in `Row.inRange`, and the reasoning for being loud there was right: an
    /// out-of-range read comes back as NULL, indistinguishable from a column that is genuinely empty,
    /// which is how `history()` came to read a `part_of_speech` its `SELECT` never projected and pass
    /// every test. What was wrong was the *severity*. A mistake in one query's `SELECT` ended the app,
    /// taking the lookup path down with the study table — the one thing ADR-0034 exists to prevent.
    ///
    /// The numeric accessors cannot simply throw: `integer`, `real` and `isNull` are read as plain
    /// values at some 160 call sites, and a query's column indices are constants, not data. So the fault
    /// is carried out of the row closure and `run` turns it into a `LedgerError`.
    ///
    /// **Logged as well as thrown.** A caller writing `try?` would otherwise restore exactly the silence
    /// the precondition was added to break, and this is a mistake in the code rather than a state the
    /// reader's file can be in — so it belongs in the log whatever the caller does with the error.
    final class ProjectionFault {
        private(set) var first: String?

        func record(_ what: String) {
            guard first == nil else { return }
            first = what
            Ledger.log.fault("ledger: \(what, privacy: .public)")
        }
    }

    private func error() -> LedgerError {
        .sqlite(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }

    struct Row {
        let statement: OpaquePointer
        let fault: ProjectionFault

        /// An index past the end of the projection is a **mistake in the query, not a NULL**.
        /// SQLite answers out-of-range reads with NULL, which cannot be told from a column that is
        /// genuinely empty — that is how `history()` came to read a `part_of_speech` its SELECT
        /// never projected, return nil for every row, and pass every test.
        ///
        /// **Recorded, not trapped** — see `ProjectionFault`. Column 0 is read in its place, because
        /// SQLite documents an out-of-range index as undefined and a row that reached here has at least
        /// one column; the value is discarded, since `run` refuses the query as soon as the closure
        /// returns.
        private func inRange(_ column: Int32) -> Int32 {
            let count = sqlite3_column_count(statement)
            guard column >= 0, column < count else {
                fault.record("column \(column) is outside this query's \(count) columns")
                return 0
            }
            return column
        }

        func optionalText(_ column: Int32) -> String? {
            // **One checked column for both calls.** Reading the bytes at one index and their count at
            // another is a read past the end of the buffer; the two spellings were harmless only while
            // an out-of-range index could not come back as a different one.
            let column = inRange(column)
            guard let bytes = sqlite3_column_text(statement, column) else { return nil }
            // By the stored length, so an embedded NUL does not end the string early.
            let count = Int(sqlite3_column_bytes(statement, column))
            return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        }

        func text(_ column: Int32) throws -> String {
            guard let text = optionalText(column) else { throw LedgerError.corruptRow("NULL in text column \(column)") }
            return text
        }

        func integer(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, inRange(column))) }
        func real(_ column: Int32) -> Double { sqlite3_column_double(statement, inRange(column)) }
        /// Out-of-range here reads as SQLITE_NULL, which is how a projection short by one column
        /// turns into "this row has no capture quality" instead of into an error.
        func isNull(_ column: Int32) -> Bool {
            sqlite3_column_type(statement, inRange(column)) == SQLITE_NULL
        }

        /// A stored identifier, or nil where the column is NULL. **Text that is not one is a damaged row,
        /// never an absent one** (audit-fix round 3, #7): read as nil, a reading linked to a note whose id
        /// did not parse came back with no note and a study status beside it — a saved meaning drawn as
        /// unsaved. `name` is the table and column, which is what the refusal says.
        func optionalUUID(_ column: Int32, _ name: String) throws -> UUID? {
            guard let raw = optionalText(column) else { return nil }
            guard let id = UUID(uuidString: raw) else { throw LedgerError.corruptRow("\(name) '\(raw)'") }
            return id
        }

        /// A stored enumeration, or nil where the column is NULL — **and a value it does not name is a
        /// damaged row**, for the reason `optionalUUID` gives: a disposition read as kept, a target kind as
        /// none or a script as none is a guess about a row nobody can read, presented as its content.
        func optional<Value: RawRepresentable>(_: Value.Type, _ column: Int32, _ name: String) throws -> Value?
        where Value.RawValue == String {
            guard let raw = optionalText(column) else { return nil }
            guard let value = Value(rawValue: raw) else { throw LedgerError.corruptRow("\(name) '\(raw)'") }
            return value
        }

        func result(_ column: Int32) throws -> LookupResult {
            let raw = try text(column)
            guard let result = LookupResult(rawValue: raw) else { throw LedgerError.corruptRow("result '\(raw)'") }
            return result
        }

        func lemmaBasis(_ column: Int32) throws -> Lemma.Basis? {
            guard let raw = optionalText(column) else { return nil }
            guard let basis = Lemma.Basis(name: raw) else { throw LedgerError.corruptRow("lemma_basis '\(raw)'") }
            return basis
        }

        func senseKeyKind(_ column: Int32) throws -> SenseKeyKind {
            let raw = try text(column)
            guard let kind = SenseKeyKind(rawValue: raw) else { throw LedgerError.corruptRow("sense_key_kind '\(raw)'") }
            return kind
        }

        func senseChoice(_ column: Int32) throws -> SenseChoice? {
            guard let raw = optionalText(column) else { return nil }
            guard let choice = SenseChoice(rawValue: raw) else { throw LedgerError.corruptRow("chosen_by '\(raw)'") }
            return choice
        }

        func abstention(_ column: Int32) throws -> Abstention? {
            guard let raw = optionalText(column) else { return nil }
            guard let why = Abstention(rawValue: raw) else { throw LedgerError.corruptRow("sense_abstention '\(raw)'") }
            return why
        }

        func answerSource(_ column: Int32) throws -> AnswerSource? {
            guard let raw = optionalText(column) else { return nil }
            guard let source = AnswerSource(rawValue: raw) else { throw LedgerError.corruptRow("answered_by '\(raw)'") }
            return source
        }

        /// Six columns: dictionary, block, ordinal, count, gloss, chosen_by. A lookup with no sense
        /// encounter joins to all-NULL, which is "no sense recorded" rather than a broken row —
        /// the ordinary case for an entry-level lookup, and for every row written before schema 4.
        func senseNote(_ first: Int32) throws -> SenseNote? {
            guard let dictionary = optionalText(first) else { return nil }
            func optionalInteger(_ column: Int32) -> Int? {
                isNull(column) ? nil : integer(column)
            }
            return SenseNote(
                dictionary: dictionary,
                block: optionalInteger(first + 1),
                ordinal: optionalInteger(first + 2),
                outOf: integer(first + 3),
                gloss: optionalText(first + 4),
                chosenBy: try senseChoice(first + 5))
        }

        /// Three columns: source, confidence, context. All NULL is a schema-1 row; anything else
        /// must be a complete, valid quality.
        func quality(_ first: Int32) throws -> CaptureQuality? {
            let isNull = (first..<first + 3).map { self.isNull($0) }
            if isNull.allSatisfy({ $0 }) { return nil }
            guard !isNull.contains(true),
                  let source = CaptureQuality.Source(rawValue: try text(first)),
                  let context = CaptureQuality.Context(rawValue: try text(first + 2)),
                  let quality = CaptureQuality(source: source, confidence: real(first + 1), context: context)
            else { throw LedgerError.corruptRow("capture quality") }
            return quality
        }
    }
}

/// SQLite copies bound text before `bind` returns — Swift's temporary C string is gone after it.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
