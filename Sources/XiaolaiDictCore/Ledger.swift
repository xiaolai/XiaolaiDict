import Foundation
import SQLite3

/// Whether the dictionaries had the word. A miss is recorded too — usually a typo or a stray
/// selection, which later triage can tell from a real gap — but it does not rank in the study list.
public enum LookupResult: String, Sendable, CaseIterable {
    case found
    case notFound
}

/// What answered a lookup: the dictionary service with its rich entries, or — when it could not —
/// the public API's plain text. A degraded answer stays marked as one after it is stored.
public enum AnswerSource: String, Sendable, CaseIterable {
    case dictionaryService
    case publicFallback
}

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
    /// How the word and its context were captured. Nil only for lookups recorded before the ledger
    /// stored it (schema 1): unknown, rather than guessed.
    public let quality: CaptureQuality?
    /// The single `source_url` column of schemas 1–3, which conflated a page with a file. Kept as
    /// it was found and never written again: the migration cannot know which of the two any old row
    /// held, and guessing would be worse than leaving it whole and unclaimed.
    public let legacySourceURL: String?

    public init(
        surface: String, lemma: String, context: String, lemmaBasis: Lemma.Basis? = nil,
        language: String? = nil, contextRange: NSRange? = nil, partOfSpeech: String? = nil,
        place: ReadingPlace = ReadingPlace(),
        lookedUpAt: Date, result: LookupResult, answeredBy: AnswerSource?, quality: CaptureQuality?,
        legacySourceURL: String? = nil
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
    /// A row holds a value this schema does not allow — the file was edited or damaged.
    case corruptRow(String)
    case sqlite(code: Int32, message: String)
}

/// Every lookup, one row each. The value is the frequency per lemma — how often the reader failed
/// to know a word — which ranks a study list better than anything starred by hand.
///
/// Not thread-safe: own one from a single actor.
public final class Ledger {
    public static let schemaVersion = 5
    /// How long a write waits for another connection — a second XiaolaiDict, a database browser — to
    /// release its lock before failing. SQLite's default is not to wait at all.
    static let busyTimeoutMilliseconds: Int32 = 2_000

    private let db: OpaquePointer

    /// `path` is a file, created if absent, or ":memory:" for a ledger that lives only as long as
    /// this object.
    public init(path: String) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw LedgerError.sqlite(code: status, message: message)
        }
        db = handle
        do {
            guard sqlite3_busy_timeout(db, Self.busyTimeoutMilliseconds) == SQLITE_OK else { throw error() }
            // Off by default in SQLite, which would make `sense_encounters`' reference to `lookups`
            // decorative: a sense could be hung off a lookup that does not exist and nothing would
            // say so. Fail loudly instead.
            try run("PRAGMA foreign_keys = ON", bind: []) { _ in }
            // Readers no longer block the writer, nor it them. A no-op for ":memory:".
            try run("PRAGMA journal_mode = WAL", bind: []) { _ in }
            try migrate()
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit {
        sqlite3_close(db)
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
                                 source_precision, part_of_speech)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                .optionalText(record.partOfSpeech),
            ]
        ) { _ in }
        return Int(sqlite3_last_insert_rowid(db))
    }

    /// One meeting with one sense, hung off the lookup that produced it.
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
    public func history(of lemma: String, language: String? = nil) throws -> [LookupRecord] {
        var records: [LookupRecord] = []
        try run(
            """
            SELECT surface, lemma, context, source_app, source_url, looked_up_at,
                   result, answered_by, capture_source, capture_confidence, context_quality,
                   lemma_basis, language, context_range_location, context_range_length,
                   source_name, source_document, source_page, source_title, source_title_raw,
                   part_of_speech
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
                legacySourceURL: row.optionalText(4)))
        }
        return records
    }

    /// What the history drawer reads: lookups since `since`, newest first, at most `limit` of them.
    ///
    /// **It does join the gloss, and that changed on 2026-09-20.** This comment used to say the
    /// query had no column to supply a definition, which was the second half of C2's enforcement —
    /// and it stayed here, false, after `se.gloss` was added below. The rule is intact but it is
    /// held elsewhere now: the card carries the gloss and shows it only when the reader asks, and
    /// `HiddenGlossTests` fails if a card's height ever depends on the length of one.
    ///
    /// Misses come back too, marked. A lookup that found nothing is usually a typo or a stray
    /// selection, and telling that from a real gap is the reason the row was recorded at all.
    ///
    /// It does carry `capture_quality`, which is not a definition but a warning label: it is what
    /// lets a card tell a sentence from the word echoed back into the context column.
    public func recentLookups(since: Date, limit: Int) throws -> [ReadingEntry] {
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
                   se.gloss, se.chosen_by
            FROM lookups l
            -- By id rather than by lookup_id, so a lookup with more than one encounter contributes
            -- one row and not several. Only the primary dictionary is recorded, so there should be
            -- at most one — "should be" is not a thing to build a join on.
            LEFT JOIN sense_encounters se ON se.id = (
                SELECT id FROM sense_encounters WHERE lookup_id = l.id ORDER BY id DESC LIMIT 1
            )
            WHERE l.looked_up_at >= ?1
            -- The row id breaks a tie, so two lookups sharing a timestamp keep their order between
            -- one reading of the drawer and the next.
            ORDER BY l.looked_up_at DESC, l.id DESC
            LIMIT ?2
            """,
            bind: [.real(since.timeIntervalSince1970), .integer(limit)]
        ) { row in
            let range: NSRange? = sqlite3_column_type(row.statement, 6) == SQLITE_NULL
                ? nil : NSRange(location: row.integer(6), length: row.integer(7))
            let surface = try row.text(1)
            let context = try row.text(3)
            // Stored where schema 5 recorded it; tagged from the reader's own sentence where it
            // did not. `??` rather than a branch, because "recorded" and "derived" are the same
            // answer to the card — the difference is in how much evidence stands behind it, and
            // that is not a difference a part-of-speech label asks anyone to act on.
            let partOfSpeech = row.optionalText(17)
                ?? tagging.partOfSpeech(of: surface, in: context, at: range)
            entries.append(ReadingEntry(
                id: row.integer(0), lemma: try row.text(2), surface: surface,
                sentence: context, sentenceRange: range,
                place: ReadingPlace(
                    bundleID: row.optionalText(8), name: row.optionalText(9),
                    document: row.optionalText(10), page: row.optionalText(11),
                    title: row.optionalText(12), rawTitle: row.optionalText(13)),
                at: Date(timeIntervalSince1970: row.real(4)),
                result: try row.result(5), quality: try row.quality(14),
                partOfSpeech: partOfSpeech, sense: try row.senseNote(18)))
        }
        return entries
    }

    // MARK: - Schema

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
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
            try execute("COMMIT")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
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

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard status == SQLITE_OK else {
            throw LedgerError.sqlite(code: status, message: message.map { String(cString: $0) } ?? "")
        }
    }

    private func run(_ sql: String, bind values: [SQLiteValue], row: (Row) throws -> Void) throws {
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
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw error()
            }
        }
    }

    private func error() -> LedgerError {
        .sqlite(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }

    struct Row {
        let statement: OpaquePointer

        /// An index past the end of the projection is a **mistake in the query, not a NULL**.
        /// SQLite answers out-of-range reads with NULL, which cannot be told from a column that is
        /// genuinely empty — that is how `history()` came to read a `part_of_speech` its SELECT
        /// never projected, return nil for every row, and pass every test. Loud here, once, rather
        /// than a wrong answer everywhere.
        private func inRange(_ column: Int32) -> Int32 {
            let count = sqlite3_column_count(statement)
            precondition(
                column >= 0 && column < count,
                "column \(column) is outside this query's \(count) columns")
            return column
        }

        func optionalText(_ column: Int32) -> String? {
            guard let bytes = sqlite3_column_text(statement, inRange(column)) else { return nil }
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
