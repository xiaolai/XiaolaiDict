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
    /// Bundle identifier of the app it was read in.
    public let sourceApp: String?
    /// The page or file, when the app can say.
    public let sourceURL: String?
    /// When the lookup was asked for — not when its answer arrived.
    public let lookedUpAt: Date
    public let result: LookupResult
    /// What answered. Nil only for lookups recorded before the ledger stored it (schemas 1 and 2).
    public let answeredBy: AnswerSource?
    /// How the word and its context were captured. Nil only for lookups recorded before the ledger
    /// stored it (schema 1): unknown, rather than guessed.
    public let quality: CaptureQuality?

    public init(
        surface: String, lemma: String, context: String, sourceApp: String?, sourceURL: String?,
        lookedUpAt: Date, result: LookupResult, answeredBy: AnswerSource?, quality: CaptureQuality?
    ) {
        self.surface = surface
        self.lemma = Lemmatizer.canonical(lemma)
        self.context = context
        self.sourceApp = sourceApp
        self.sourceURL = sourceURL
        self.lookedUpAt = lookedUpAt
        self.result = result
        self.answeredBy = answeredBy
        self.quality = quality
    }
}

/// How often a lemma has been looked up: the study list's unit.
public struct LemmaCount: Equatable, Sendable {
    public let lemma: String
    public let count: Int
    public let lastLookedUpAt: Date
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
    public static let schemaVersion = 3
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

    public func record(_ record: LookupRecord) throws {
        guard !record.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LedgerError.blankSurface
        }
        guard !record.lemma.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LedgerError.blankLemma
        }
        try run(
            """
            INSERT INTO lookups (surface, lemma, context, source_app, source_url, looked_up_at,
                                 result, answered_by, capture_source, capture_confidence, context_quality)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: [
                .text(record.surface), .text(record.lemma), .text(record.context),
                .optionalText(record.sourceApp), .optionalText(record.sourceURL),
                .real(record.lookedUpAt.timeIntervalSince1970), .text(record.result.rawValue),
                .optionalText(record.answeredBy?.rawValue),
                .optionalText(record.quality?.source.rawValue), .optionalReal(record.quality?.confidence),
                .optionalText(record.quality?.context.rawValue),
            ]
        ) { _ in }
    }

    /// Lemmas the dictionaries had, by how often they were looked up, most first; equal counts put
    /// the most recent first, and equal times the lemma in code-point order, so a list cut at
    /// `limit` is the same list every time.
    public func studyList(limit: Int) throws -> [LemmaCount] {
        guard limit >= 0 else { throw LedgerError.negativeLimit(limit) }
        var list: [LemmaCount] = []
        try run(
            """
            SELECT lemma, COUNT(*) AS n, MAX(looked_up_at) AS last FROM lookups
            WHERE result = ? GROUP BY lemma ORDER BY n DESC, last DESC, lemma ASC LIMIT ?
            """,
            bind: [.text(LookupResult.found.rawValue), .integer(limit)]
        ) { row in
            list.append(LemmaCount(
                lemma: try row.text(0), count: row.integer(1),
                lastLookedUpAt: Date(timeIntervalSince1970: row.real(2))))
        }
        return list
    }

    /// Every lookup of `lemma`, found or not, newest first.
    public func history(of lemma: String) throws -> [LookupRecord] {
        var records: [LookupRecord] = []
        try run(
            """
            SELECT surface, lemma, context, source_app, source_url, looked_up_at,
                   result, answered_by, capture_source, capture_confidence, context_quality
            FROM lookups WHERE lemma = ? ORDER BY looked_up_at DESC, id DESC
            """,
            bind: [.text(Lemmatizer.canonical(lemma))]
        ) { row in
            records.append(LookupRecord(
                surface: try row.text(0), lemma: try row.text(1), context: try row.text(2),
                sourceApp: row.optionalText(3), sourceURL: row.optionalText(4),
                lookedUpAt: Date(timeIntervalSince1970: row.real(5)),
                result: try row.result(6), answeredBy: try row.answerSource(7), quality: try row.quality(8)))
        }
        return records
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
    private enum SQLiteValue {
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

    private struct Row {
        let statement: OpaquePointer

        func optionalText(_ column: Int32) -> String? {
            guard let bytes = sqlite3_column_text(statement, column) else { return nil }
            // By the stored length, so an embedded NUL does not end the string early.
            let count = Int(sqlite3_column_bytes(statement, column))
            return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        }

        func text(_ column: Int32) throws -> String {
            guard let text = optionalText(column) else { throw LedgerError.corruptRow("NULL in text column \(column)") }
            return text
        }

        func integer(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }

        func result(_ column: Int32) throws -> LookupResult {
            let raw = try text(column)
            guard let result = LookupResult(rawValue: raw) else { throw LedgerError.corruptRow("result '\(raw)'") }
            return result
        }

        func answerSource(_ column: Int32) throws -> AnswerSource? {
            guard let raw = optionalText(column) else { return nil }
            guard let source = AnswerSource(rawValue: raw) else { throw LedgerError.corruptRow("answered_by '\(raw)'") }
            return source
        }

        /// Three columns: source, confidence, context. All NULL is a schema-1 row; anything else
        /// must be a complete, valid quality.
        func quality(_ first: Int32) throws -> CaptureQuality? {
            let isNull = (first..<first + 3).map { sqlite3_column_type(statement, $0) == SQLITE_NULL }
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
