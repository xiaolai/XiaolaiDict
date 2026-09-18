import Foundation
import XiaolaiDictCore
import SQLite3
import Testing

/// The ledger's value is the frequency count per lemma — how often the reader failed to know a
/// word — not the word list (design note §9).
struct LedgerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        _ surface: String, lemma: String, at offset: TimeInterval = 0, context: String = "",
        app: String? = "com.apple.Safari", url: String? = nil, result: LookupResult = .found,
        answeredBy: AnswerSource? = .dictionaryService,
        quality: CaptureQuality? = CaptureQuality.accessibility(.accessibilityTextRange, context: .complete)
    ) -> LookupRecord {
        LookupRecord(
            surface: surface, lemma: lemma, context: context, sourceApp: app, sourceURL: url,
            lookedUpAt: now.addingTimeInterval(offset), result: result, answeredBy: answeredBy, quality: quality)
    }

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("xiaolaidict-ledger-\(UUID().uuidString).sqlite").path
    }

    private func removeDatabase(at path: String) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    @Test func aRecordReadsBackExactly() throws {
        let ledger = try Ledger(path: ":memory:")
        let original = record(
            "ephemeral", lemma: "ephemeral", context: "An ephemeral beauty — 转瞬即逝。",
            app: "com.apple.TextEdit", url: "file:///tmp/notes.txt",
            quality: .accessibility(.accessibilityTextMarkers, context: .mayBeCut))
        try ledger.record(original)
        #expect(try ledger.history(of: "ephemeral") == [original])
    }

    @Test func missingSourceFieldsStayMissing() throws {
        let ledger = try Ledger(path: ":memory:")
        let original = record("ephemeral", lemma: "ephemeral", app: nil, url: nil)
        try ledger.record(original)
        #expect(try ledger.history(of: "ephemeral") == [original])
    }

    /// Bound by byte count and read back by stored length: a NUL inside captured text is text,
    /// not the end of it.
    @Test func anEmbeddedNULSurvives() throws {
        let ledger = try Ledger(path: ":memory:")
        let original = record("ephemeral", lemma: "ephemeral", context: "before\u{0}after", url: "file:///a\u{0}b")
        try ledger.record(original)
        #expect(try ledger.history(of: "ephemeral") == [original])
    }

    @Test func theStudyListCountsLookupsPerLemmaMostFirst() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.record(record("running", lemma: "run", at: 1))
        try ledger.record(record("ephemeral", lemma: "ephemeral", at: 2))
        try ledger.record(record("ran", lemma: "run", at: 3))
        try ledger.record(record("runs", lemma: "run", at: 4))

        let list = try ledger.studyList(limit: 10)
        #expect(list.map(\.lemma) == ["run", "ephemeral"])
        #expect(list.map(\.count) == [3, 1])
        #expect(list[0].lastLookedUpAt == now.addingTimeInterval(4))
    }

    @Test func equalCountsRankTheMostRecentFirst() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.record(record("older", lemma: "older", at: 1))
        try ledger.record(record("newer", lemma: "newer", at: 2))
        #expect(try ledger.studyList(limit: 10).map(\.lemma) == ["newer", "older"])
    }

    /// Equal counts at the same moment are ordered by the lemma, so a list cut by its limit is the
    /// same list every time.
    @Test func fullTiesAreBrokenByTheLemma() throws {
        let ledger = try Ledger(path: ":memory:")
        for word in ["pear", "apple", "fig"] { try ledger.record(record(word, lemma: word, at: 1)) }
        #expect(try ledger.studyList(limit: 2).map(\.lemma) == ["apple", "fig"])
    }

    @Test func theStudyListHonoursItsLimit() throws {
        let ledger = try Ledger(path: ":memory:")
        for (index, word) in ["a", "b", "c"].enumerated() {
            try ledger.record(record(word, lemma: word, at: TimeInterval(index)))
        }
        #expect(try ledger.studyList(limit: 2).count == 2)
        #expect(try ledger.studyList(limit: 0).isEmpty)
    }

    /// SQLite reads a negative LIMIT as "no limit"; passed through, a bounded request would
    /// silently return the whole ledger.
    @Test func aNegativeLimitIsRefused() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.record(record("a", lemma: "a"))
        #expect(throws: LedgerError.negativeLimit(-1)) { try ledger.studyList(limit: -1) }
    }

    /// Every lookup is recorded — a miss is usually a typo or a stray selection, which later
    /// triage can tell from a real gap — but only words the dictionaries had rank for study.
    @Test func aMissIsRecordedButDoesNotRank() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.record(record("qzxqzx", lemma: "qzxqzx", result: .notFound))
        try ledger.record(record("ephemeral", lemma: "ephemeral"))
        #expect(try ledger.history(of: "qzxqzx").map(\.result) == [.notFound])
        #expect(try ledger.studyList(limit: 10).map(\.lemma) == ["ephemeral"])
    }

    @Test func historyIsNewestFirst() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.record(record("ran", lemma: "run", at: 1))
        try ledger.record(record("running", lemma: "run", at: 2))
        #expect(try ledger.history(of: "run").map(\.surface) == ["running", "ran"])
    }

    /// SQLite groups text byte by byte. Composed and decomposed "café", or "Run" and "run", would
    /// otherwise be separate study entries — splitting the one number the ledger exists for.
    @Test func differentSpellingsOfOneLemmaAreOneEntry() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.record(record("café", lemma: "caf\u{e9}", at: 1))
        try ledger.record(record("café", lemma: "cafe\u{301}", at: 2))
        try ledger.record(record("Café", lemma: "Caf\u{e9}", at: 3))
        #expect(try ledger.studyList(limit: 10).map(\.count) == [3])
        #expect(try ledger.history(of: "cafe\u{301}").count == 3)
    }

    @Test func lookupsSurviveReopeningTheFile() throws {
        let path = temporaryPath()
        defer { removeDatabase(at: path) }

        try Ledger(path: path).record(record("ephemeral", lemma: "ephemeral"))
        #expect(try Ledger(path: path).studyList(limit: 10).map(\.lemma) == ["ephemeral"])
    }

    /// Zero trust at the boundary: a blank surface or lemma is a caller bug, not a word.
    @Test(arguments: ["", "   ", "\n"])
    func aBlankSurfaceIsRefused(surface: String) throws {
        let ledger = try Ledger(path: ":memory:")
        #expect(throws: LedgerError.blankSurface) { try ledger.record(record(surface, lemma: "x")) }
    }

    @Test(arguments: ["", "   ", "\n"])
    func aBlankLemmaIsRefused(lemma: String) throws {
        let ledger = try Ledger(path: ":memory:")
        #expect(throws: LedgerError.blankLemma) { try ledger.record(record("word", lemma: lemma)) }
    }

    /// A database written by a newer XiaolaiDict must not be read — or worse, written — by an older one.
    @Test func aNewerSchemaIsRefusedRatherThanGuessed() throws {
        let path = temporaryPath()
        defer { removeDatabase(at: path) }
        _ = try Ledger(path: path)
        try SQLiteFile(path: path).execute("PRAGMA user_version = \(Ledger.schemaVersion + 1)")

        #expect(throws: LedgerError.newerSchema(found: Ledger.schemaVersion + 1, supported: Ledger.schemaVersion)) {
            try Ledger(path: path)
        }
    }

    /// A ledger written by schema 1 is carried forward, not lost: its rows were all hits (schema 1
    /// recorded nothing else), their capture quality was never kept, and their lemmas take the
    /// canonical form.
    @Test func aSchema1LedgerIsMigrated() throws {
        let path = temporaryPath()
        defer { removeDatabase(at: path) }
        let file = try SQLiteFile(path: path)
        try file.execute(
            """
            CREATE TABLE lookups (id INTEGER PRIMARY KEY, surface TEXT NOT NULL, lemma TEXT NOT NULL,
                context TEXT NOT NULL, source_app TEXT, source_url TEXT, looked_up_at REAL NOT NULL);
            CREATE INDEX lookups_by_lemma ON lookups (lemma, looked_up_at);
            INSERT INTO lookups (surface, lemma, context, source_app, source_url, looked_up_at)
                VALUES ('Café', 'Cafe\u{301}', 'At the café.', 'com.apple.Safari', NULL, 1800000000);
            PRAGMA user_version = 1;
            """)

        let ledger = try Ledger(path: path)
        let migrated = try #require(try ledger.history(of: "café").first)
        #expect(migrated.lemma == "caf\u{e9}")
        #expect(migrated.result == .found)
        #expect(migrated.answeredBy == nil)
        #expect(migrated.quality == nil)
        #expect(try ledger.studyList(limit: 10).map(\.lemma) == ["caf\u{e9}"])
    }

    /// A plain-text fallback is a hit, but a weaker one — and stays marked as one once stored.
    @Test func whatAnsweredIsKept() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.record(record("ephemeral", lemma: "ephemeral", at: 1, answeredBy: .publicFallback))
        try ledger.record(record("ephemeral", lemma: "ephemeral", at: 2, answeredBy: .dictionaryService))
        #expect(try ledger.history(of: "ephemeral").map(\.answeredBy) == [.dictionaryService, .publicFallback])
    }

    /// Schema 2 did not keep what answered; its rows read back with that unknown, and the file
    /// takes new rows that do.
    @Test func aSchema2LedgerIsMigrated() throws {
        let path = temporaryPath()
        defer { removeDatabase(at: path) }
        try SQLiteFile(path: path).execute(
            """
            CREATE TABLE lookups (id INTEGER PRIMARY KEY, surface TEXT NOT NULL, lemma TEXT NOT NULL,
                context TEXT NOT NULL, source_app TEXT, source_url TEXT, looked_up_at REAL NOT NULL,
                result TEXT NOT NULL DEFAULT 'found', capture_source TEXT, capture_confidence REAL,
                context_quality TEXT);
            INSERT INTO lookups (surface, lemma, context, looked_up_at, result, capture_source,
                capture_confidence, context_quality)
                VALUES ('saw', 'see', 'I saw it.', 1800000000, 'found', 'accessibilityTextRange', 1, 'complete');
            PRAGMA user_version = 2;
            """)
        let ledger = try Ledger(path: path)
        let migrated = try #require(try ledger.history(of: "see").first)
        #expect(migrated.answeredBy == nil)
        #expect(migrated.quality == .accessibility(.accessibilityTextRange, context: .complete))
        try ledger.record(record("saw", lemma: "see", at: 5, answeredBy: .publicFallback))
        #expect(try ledger.history(of: "see").map(\.answeredBy) == [.publicFallback, nil])
    }

    /// Another connection holding the write lock — a second XiaolaiDict, a database browser — makes a
    /// write wait for it, not fail at once and lose the lookup.
    @Test func aWriteWaitsForAnotherConnectionsLock() async throws {
        let path = temporaryPath()
        defer { removeDatabase(at: path) }
        let ledger = try Ledger(path: path)
        let other = try SQLiteFile(path: path)
        try other.execute("BEGIN IMMEDIATE")
        let release = Task.detached {
            try await Task.sleep(for: .milliseconds(300))
            try other.execute("COMMIT")
        }
        try ledger.record(record("ephemeral", lemma: "ephemeral"))
        try await release.value
        #expect(try ledger.history(of: "ephemeral").count == 1)
    }

    @Test(arguments: [-0.1, 1.1, Double.nan])
    func aConfidenceOutsideZeroToOneIsNotAQuality(confidence: Double) {
        #expect(CaptureQuality(source: .accessibilityTextRange, confidence: confidence, context: .complete) == nil)
    }
}

/// A second, raw connection: what another process would do to the same file.
private final class SQLiteFile: @unchecked Sendable {  // used from one task at a time
    private let db: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else { throw SQLiteFileError(message: "open \(path)") }
        db = handle
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteFileError(message: String(cString: sqlite3_errmsg(db)))
        }
    }
}

private struct SQLiteFileError: Error { let message: String }
