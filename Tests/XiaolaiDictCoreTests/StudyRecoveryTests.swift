import DictionaryModel
import Foundation
import ReviewKit
import SQLite3
import Testing
import XiaolaiDictTestSupport
@testable import XiaolaiDictCore

/// **Recovery and erasure.** WI-006, and the gate P0 closes on.
///
/// Four claims, each of which is easy to believe and hard to notice is false: a restored copy is
/// whole, a committed grade survives a restart exactly once, an erase reaches the copies this app
/// made, and a broken study system still lets the reader look a word up.
struct StudyRecoveryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() -> (String, () -> Void) {
        let path = ScratchFile.path("recovery")
        return (path, { ScratchFile.remove(path) })
    }

    @discardableResult
    private func save(_ ledger: Ledger, _ word: String) throws -> StudyNote {
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence with \(word).", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        return try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-\(word)", senseKey: "e-\(word).1",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "what \(word) means"),
            lookupID: lookup, at: now)
    }

    // MARK: - The copy is whole

    /// **A backup taken with writes still in the log holds them.** This is the reason the backup API
    /// exists rather than a file copy: a ledger separated from its write-ahead log loses every write
    /// SQLite has not folded in, measured here once as a 449 KB log against a 40 KB database.
    @Test func abackupTakenWithUnflushedWritesHoldsThem() throws {
        let (path, clean) = scratch()
        defer { clean() }
        let copy = path + ".copy"
        do {
            let ledger = try Ledger(path: path)
            for word in ["fine", "hold", "bank"] { try save(ledger, word) }
            // No checkpoint: the rows are in the log, which is exactly the state a file copy loses.
            try ledger.backUp(to: copy)
        }
        let restored = try Ledger(path: copy)
        #expect(try restored.notes().count == 3)
        #expect(try restored.history(of: "fine").count == 1)
        let problems = try restored.integrity()
        #expect(problems.isEmpty, "the copy is not whole: \(problems)")
    }

    /// And the restored copy passes every invariant, not only SQLite's own.
    @Test func arestoredLedgerPassesTheStudyInvariantsToo() throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let note = try save(ledger, "fine")
        let card = try ledger.card(of: note.id, at: now)
        _ = try ledger.grade(cardID: card.id, .good, eventID: UUID(), expectedRevision: 0, at: now,
                             using: try MemoryScheduler())
        let copy = path + ".copy"
        try ledger.backUp(to: copy)

        let restored = try Ledger(path: copy)
        #expect(try restored.integrity().isEmpty)
        #expect(try restored.reviews(ofCard: card.id).count == 1)
    }

    /// The checks can fail. Asserted by breaking one of the things they look for — an invariant
    /// suite that only ever passes is a suite nobody has seen work.
    @Test func theintegrityChecksCanFail() throws {
        let ledger = try Ledger(path: ":memory:")
        let note = try save(ledger, "fine")
        try ledger.card(of: note.id, at: now)
        // A second card for the same question, inserted behind the unique index by dropping it.
        // **Its id is a UUID**: integrity reads every card through the card decoder since the replay
        // joined it (WI-9b), and an id that is not one is a different defect — asserted below.
        let second = UUID().uuidString
        try ledger.execute("DROP INDEX study_cards_question")
        try ledger.execute("""
            INSERT INTO study_cards (id, note_id, prompt, phase, paused, revision, scheduler_version,
                                     created_at)
            SELECT '\(second)', note_id, prompt, phase, paused, revision, scheduler_version, created_at
            FROM study_cards LIMIT 1
            """)
        let problems = try ledger.integrity()
        #expect(problems.contains { $0.hasPrefix("duplicate cards") }, "got \(problems)")
        // **A card row nothing can read is loud**, not a card the check quietly passed over.
        try ledger.execute("UPDATE study_cards SET id = 'second' WHERE id = '\(second)'")
        #expect(throws: LedgerError.corruptRow("study_cards second")) { try ledger.integrity() }
    }

    // MARK: - A grade survives exactly once

    /// **Exactly once**: not lost, and not applied twice by a replay on reopen.
    @Test func acommittedGradeSurvivesArestartExactlyOnce() throws {
        let (path, clean) = scratch()
        defer { clean() }
        let eventID = UUID()
        var expected: ScheduledCard?
        var cardID: UUID?
        do {
            let ledger = try Ledger(path: path)
            let note = try save(ledger, "fine")
            let card = try ledger.card(of: note.id, at: now)
            cardID = card.id
            let event = try ledger.grade(cardID: card.id, .good, eventID: eventID,
                                         expectedRevision: 0, at: now, using: try MemoryScheduler())
            expected = event.after
        }
        let reopened = try Ledger(path: path)
        let id = try #require(cardID)
        #expect(try reopened.reviews(ofCard: id).count == 1)
        #expect(try #require(try reopened.card(id: id)).scheduled == expected)
        // And the same event id, replayed after the restart, is still the same one review.
        _ = try reopened.grade(cardID: id, .again, eventID: eventID, expectedRevision: 0, at: now,
                               using: try MemoryScheduler())
        #expect(try reopened.reviews(ofCard: id).count == 1, "a replayed event graded twice")
        #expect(try #require(try reopened.card(id: id)).scheduled == expected)
    }

    // MARK: - Erasure reaches the copies

    /// **A migration's copy is the app's, and a permanent erase must take it.** A reader told their
    /// reading is gone, while a copy of it sits beside the ledger, has been told something false.
    @Test func erasingReadingTakesTheCopiesThisAppMade() throws {
        let (path, clean) = scratch()
        defer { clean() }
        do {
            let ledger = try Ledger(path: path)
            try save(ledger, "fine")
            // The shape a migration leaves behind.
            try ledger.backUp(to: path + ".schema7.backup")
        }
        #expect(try Ledger.appManagedBackups(besides: path).count == 1)

        let ledger = try Ledger(path: path)
        let report = try ledger.eraseReadingData(at: path)
        #expect(report.lookupsRemoved == 1)
        #expect(report.backupsRemoved.count == 1)
        #expect(report.isComplete)
        #expect(try Ledger.appManagedBackups(besides: path).isEmpty)
        #expect(try ledger.history(of: "fine").isEmpty)
    }

    /// **A folder that cannot be listed is not a folder with no copies in it** (audit-fix round 1).
    /// The listing's error became an empty list, so the impact counted no copies and a permanent
    /// erase reported itself complete while the migration's copy — the reader's whole history —
    /// sat beside the ledger. Search permission without read permission is that shape exactly: every
    /// file opens by name, and the directory cannot be listed.
    @Test func afolderThatCannotBeListedIsNeverAnEraseWithNothingLeft() throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine")
        let copy = path + ".schema7.backup"
        try ledger.backUp(to: copy)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? Int)
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: directory)
        defer { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory) }
        try #require((try? FileManager.default.contentsOfDirectory(atPath: directory)) == nil,
                     "the folder can still be listed, so this cannot show anything")

        #expect(throws: (any Error).self, "the impact counted copies in a folder it could not list") {
            try ledger.readingErasureImpact(at: path)
        }
        let report = try ledger.eraseReadingData(at: path)
        #expect(report.lookupsRemoved == 1)
        #expect(!report.isComplete, "the erase said it was complete over a folder it could not list")
        #expect(report.backupsLeft.isEmpty)
        if case .backupsNotListed(let reason) = report.unreached.first, report.unreached.count == 1 {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("the erase did not say which thing it could not reach: \(report.unreached)")
        }
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory)
        #expect(FileManager.default.fileExists(atPath: copy), "a control: the copy is still there")
    }

    /// **A busy checkpoint is said by kind, not in a sentence** (audit-fix round 1): the target holds
    /// no display text, so the erase names what it could not reach and the surface says it. Another
    /// connection holding a read snapshot is what keeps the log from being truncated.
    @Test func aBusyWriteAheadLogIsAnIncompleteEraseByName() throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine")
        var reader: OpaquePointer?
        try #require(sqlite3_open_v2(path, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close_v2(reader) }
        try #require(sqlite3_exec(reader, "BEGIN; SELECT COUNT(*) FROM lookups;", nil, nil, nil) == SQLITE_OK)
        let report = try ledger.eraseReadingData(at: path)
        #expect(report.unreached == [.writeAheadLogBusy])
        #expect(!report.isComplete)
        // **The control**: with the reader gone, the same erase reaches everything.
        try #require(sqlite3_exec(reader, "COMMIT;", nil, nil, nil) == SQLITE_OK)
        let again = try ledger.eraseReadingData(at: path)
        #expect(again.unreached.isEmpty && again.isComplete)
    }

    /// **What fails after the rows are gone is part of the report, not a throw** (audit-fix round 2).
    /// The delete commits before the copies, the log and the rewrite are reached; `VACUUM` throwing then
    /// discarded the report and presented an erase that had happened as one that had not. A statement of
    /// this connection's own still stepping is what makes `VACUUM` refuse: "SQL statements in progress".
    @Test func whatFailsAfterTheDeleteIsReportedNotThrown() throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine")
        var report: Ledger.ErasureReport?
        try ledger.run("SELECT 1 UNION ALL SELECT 2", bind: []) { _ in
            guard report == nil else { return }
            report = try ledger.eraseReadingData(at: path)
        }
        let made = try #require(report)
        #expect(made.lookupsRemoved == 1)
        #expect(!made.isComplete, "an erase whose rewrite failed called itself complete")
        #expect(made.unreached.contains { if case .notRewritten = $0 { true } else { false } },
                "the failed rewrite is not named: \(made.unreached)")
        #expect(try ledger.history(of: "fine").isEmpty, "the delete did not commit")
        // **The control**: nothing stepping, the same erase rewrites the file.
        let again = try ledger.eraseReadingData(at: path)
        #expect(!again.unreached.contains { if case .notRewritten = $0 { true } else { false } })
    }

    /// **The note stays, and says it needs repair.** This is *delete my reading*, not *delete my
    /// cards*, and conflating them is how a reader loses months of study to a menu item about history.
    @Test func erasingReadingKeepsTheCardsAndMarksThemForRepair() throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let note = try save(ledger, "fine")
        _ = try ledger.eraseReadingData(at: path)
        #expect(try ledger.notes().count == 1)
        #expect(try ledger.readiness(of: note.id) == .needsRepair)
        #expect(try ledger.answer(of: note.id) != nil)
    }

    /// **Only this app's own copies.** A file the reader put beside the ledger is theirs, and is
    /// never a candidate for deletion by us.
    @Test func afileTheReaderPutThereIsNotOursToDelete() throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine")
        let theirs = path + ".my-own-copy"
        try ledger.backUp(to: theirs)
        defer { try? FileManager.default.removeItem(atPath: theirs) }

        let report = try ledger.eraseReadingData(at: path)
        #expect(report.backupsRemoved.isEmpty)
        #expect(FileManager.default.fileExists(atPath: theirs), "we deleted a file that was not ours")
    }

    /// **A reader's file that merely *looks* like ours is not ours.** The matcher accepted anything
    /// between `.schema` and `.backup`, so `ledger.sqlite.schema7.my-own.backup` — a copy a reader
    /// might plausibly name — was a candidate for deletion, while the comment claimed an exact match.
    @Test func afileThatOnlyResemblesOursIsNotDeleted() throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine")
        let ours = path + ".schema7.backup"
        let theirs = path + ".schema7.my-own.backup"
        try ledger.backUp(to: ours)
        try ledger.backUp(to: theirs)

        #expect(try Ledger.appManagedBackups(besides: path) == [ours])
        let report = try ledger.eraseReadingData(at: path)
        #expect(report.backupsRemoved == [ours])
        #expect(FileManager.default.fileExists(atPath: theirs), "we deleted a file that was not ours")
    }

    /// **An erase that says it is complete must not leave the text in the file.** `DELETE` frees the
    /// pages and leaves their bytes; this Mac's SQLite runs `secure_delete` in FAST mode, which only
    /// scrubs pages it is already rewriting. Measured before the fix as thousands of the deleted
    /// sentences' bytes still present.
    @Test func erasedSentencesAreNotStillInTheFile() throws {
        let (path, clean) = scratch()
        defer { clean() }
        let marker = "MARKERPHRASEUNLIKELYTOAPPEARBYCHANCE"
        do {
            let ledger = try Ledger(path: path)
            for index in 0..<40 {
                _ = try ledger.record(LookupRecord(
                    surface: "fine", lemma: "fine",
                    context: String(repeating: "\(marker) ", count: 40) + "\(index)",
                    lemmaBasis: .tagger, language: "en", contextRange: nil,
                    place: ReadingPlace(bundleID: nil, name: nil), lookedUpAt: now, result: .found,
                    answeredBy: .dictionaryService, quality: nil))
            }
            _ = try ledger.eraseReadingData(at: path)
        }
        // Read the closed file's bytes. Nothing subtle: if the reader's sentences are in there, they
        // are in there, and they were told they were gone.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let needle = Data(marker.utf8)
        #expect(bytes.range(of: needle) == nil, "the erased sentences are still in the database file")
        for suffix in ["-wal", "-shm"] {
            if let sidecar = try? Data(contentsOf: URL(fileURLWithPath: path + suffix)) {
                #expect(sidecar.range(of: needle) == nil, "still in \(suffix)")
            }
        }
    }

    // MARK: - Lookup outlives study

    /// **The dictionary is the product; study is built on it.** A study write that fails must not
    /// take the lookup path with it, or a broken card system becomes a broken dictionary.
    @Test func alookupStillWorksWhenTheStudySystemCannotBeWritten() throws {
        let ledger = try Ledger(path: ":memory:")
        // The study tables, gone — the worst version of "study is unavailable".
        try ledger.execute("""
            DROP TABLE review_events;
            DROP TABLE study_cards;
            DROP TABLE study_answers;
            DROP TABLE study_note_lookups;
            DROP TABLE study_locators;
            DROP TABLE study_notes;
            """)
        let id = try ledger.record(LookupRecord(
            surface: "fine", lemma: "fine", context: "He paid the fine.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        #expect(id > 0, "a lookup could not be recorded with the study system gone")
        #expect(try ledger.history(of: "fine").count == 1)
        #expect(try ledger.recentLookups(since: now.addingTimeInterval(-60), limit: 10,
                                         studying: [.latin]).count == 1)
        #expect(try ledger.readingArchive(ReadingArchiveQuery()).count == 1)
        // And enrolling fails loudly rather than pretending it worked.
        #expect(throws: (any Error).self) {
            try ledger.enroll(.entry(dictionary: "noad", entryID: "e1"), issuer: .live,
                              language: "en", chosenBy: nil,
                              answer: StudyAnswer(origin: .reader, text: "x"), lookupID: id,
                              at: self.now)
        }
    }

    /// **A note row this build cannot read is corruption, refused loudly, as a card row is** (audit-fix
    /// round 1, ADR-0047 "Revisiting"). The decoder skipped it — "only a newer build" could write one —
    /// but `target_kind`, `issuer` and `enrollment` are CHECK-constrained and a newer schema is refused
    /// at open, the id is a UUID every writer formats, and `card(from:)` already throws for the same
    /// shape. Skipped, the meaning vanished from the Library and its readiness read `needsRepair`.
    /// **And the dictionary still answers**: no lookup path decodes a note it did not ask for — the
    /// reading, its history and keeping another word go on as before.
    @Test(arguments: [
        ("not-a-uuid", "sense", "active", "publisher"),
        ("5D4B3E1C-0000-4000-8000-00000000000A", "sense", "dormant", "publisher"),
        ("5D4B3E1C-0000-4000-8000-00000000000B", "sense", "active", "futureKind"),
        ("5D4B3E1C-0000-4000-8000-00000000000C", "chapter", "active", "publisher"),
    ])
    func aNoteRowThisBuildCannotReadIsRefusedAndLookupsGoOn(
        _ damaged: (id: String, kind: String, enrollment: String, senseKeyKind: String)
    ) throws {
        let ledger = try Ledger(path: ":memory:")
        try save(ledger, "fine")
        #expect(try ledger.notes().count == 1, "a control: the ledger reads before the damage")
        // Damage, as a raw editor or a bad sector leaves it — past the CHECKs, which a writer cannot be.
        try ledger.execute("PRAGMA ignore_check_constraints = ON")
        try ledger.run("""
            INSERT INTO study_notes (id, target_kind, issuer, language, dictionary, entry_id, sense_key,
                                     sense_key_kind, phrase_text, enrollment, confirmed_at, created_at)
            VALUES (?, ?, 'live', 'en', 'noad', 'e-damaged', 'e-damaged.1', ?, '', ?, NULL, 0)
            """, bind: [.text(damaged.id), .text(damaged.kind), .text(damaged.senseKeyKind),
                        .text(damaged.enrollment)]) { _ in }
        try ledger.execute("PRAGMA ignore_check_constraints = OFF")

        #expect(throws: LedgerError.self, "notes() passed over \(damaged)") { try ledger.notes() }
        #expect(throws: LedgerError.self, "the library passed over \(damaged)") {
            try ledger.library(LibraryQuery(now: self.now))
        }
        // The lookup path, beside it.
        let id = try ledger.record(LookupRecord(
            surface: "brook", lemma: "brook", context: "A brook ran past.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        #expect(try ledger.reading(ofLookup: id)?.lemma == "brook")
        #expect(try ledger.recentLookups(since: now.addingTimeInterval(-60), limit: 10, studying: [.latin]).count == 2)
        #expect(try ledger.keep(.sense(dictionary: "noad", entryID: "e-brook", senseKey: "e-brook.1",
                                       senseKeyKind: .publisher),
                                issuer: .live, language: "en", chosenBy: .reader,
                                answer: StudyAnswer(origin: .reader, text: "a small stream"), lookupID: id,
                                at: now, source: .manual) != nil,
                "keeping another word went through a note it never asked for")
    }

    /// The schema-13 tables gone, so the ledger opens at `version` and upgrades.
    private static let unwindThirteen = """
        DROP TRIGGER remember_removed_target; DROP TRIGGER study_keep_new_note;
        DROP TABLE removed_keep_targets; DROP TABLE lookup_disposition_receipts;
        DROP TABLE lookup_disposition_operations; DROP TABLE study_keep_metadata; DROP TABLE keep_backfill;
        DROP INDEX lookups_archive; ALTER TABLE lookups DROP COLUMN disposition;
        ALTER TABLE lookups DROP COLUMN disposition_revision; ALTER TABLE lookups DROP COLUMN primary_dictionary;
        ALTER TABLE lookups DROP COLUMN keep_policy;
        """

    /// **An upgrade is not a study write the lookup path may depend on.** A ledger whose study tables are
    /// gone must still open, record and show history; only study is unavailable. 12 reaches schema 13's
    /// study half, 11 the `review_events` column added at 12. `survivingLinks` drops `study_notes` alone,
    /// with foreign keys off, so its links, answer, card and tag are left pointing at nothing — the
    /// damage the upgrade's foreign-key check must report rather than abort on.
    @Test(arguments: [12, 11], [false, true])
    func aledgerWithoutStudyTablesStillUpgradesForLookup(from version: Int, survivingLinks: Bool) throws {
        let directory = TemporaryDirectory()
        let path = directory.appending("ledger.sqlite").path
        do {
            let ledger = try Ledger(path: path)
            let first = try ledger.record(LookupRecord(
                surface: "fine", lemma: "fine", context: "He paid the fine.", lemmaBasis: .tagger,
                language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
                lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
            let note = try ledger.enroll(.entry(dictionary: "noad", entryID: "e1"), issuer: .live,
                                         language: "en", chosenBy: nil,
                                         answer: StudyAnswer(origin: .reader, text: "x"), lookupID: first, at: now)
            try ledger.tag(noteID: note.id, "kept")
            let organisation = version < 12
                ? StudyMigrationTests.tablesCreated(by: Ledger.studyOrganisationSchema).map { "DROP TABLE \($0);" }
                : []
            // Below 12, `review_events` goes too: its `kind` column came with 12, and an 11 whose
            // events are gone is the guarded step's case.
            let study = survivingLinks
                ? ["PRAGMA foreign_keys = OFF;", "DROP TABLE study_notes;"]
                    + (version < 12 ? ["DROP TABLE review_events;"] : [])
                : ["DROP TABLE review_events; DROP TABLE study_cards; DROP TABLE study_answers;",
                   "DROP TABLE study_note_lookups; DROP TABLE study_locators; DROP TABLE study_notes;"]
            try ledger.execute(([Self.unwindThirteen] + organisation + study
                                + ["PRAGMA user_version = \(version);"]).joined(separator: "\n"))
            if survivingLinks {
                var orphans = 0
                try ledger.run("SELECT COUNT(*) FROM study_note_lookups", bind: []) { orphans = $0.integer(0) }
                #expect(orphans == 1, "positive control: a link survives its note")
            }
        }
        let migrated = try Ledger(path: path)
        let id = try migrated.recordForLearning(LookupRecord(
            surface: "hold", lemma: "hold", context: "Hold on.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil),
            with: nil, policy: .automatic, primary: "noad")
        #expect(id > 0)
        #expect(try migrated.recentLookups(since: now.addingTimeInterval(-60), limit: 10,
                                           studying: [.latin]).count == 2)
        #expect(try migrated.readingArchive(ReadingArchiveQuery()).count == 2)
        _ = try migrated.changeDisposition(.discarded, lookups: [id], operation: UUID())
        #expect(try migrated.readingArchive(ReadingArchiveQuery()).count == 1)
    }

    /// **The other half of the scope: lookup damage still stops the upgrade.** An encounter whose
    /// lookup is gone is the lookup path's own integrity, and passing it would be the quiet default.
    @Test func adanglingLookupReferenceStillAbortsTheUpgrade() throws {
        let directory = TemporaryDirectory()
        let path = directory.appending("ledger.sqlite").path
        do {
            let ledger = try Ledger(path: path)
            try ledger.execute(Self.unwindThirteen + """
                PRAGMA foreign_keys = OFF;
                INSERT INTO sense_encounters (lookup_id, dictionary_id, dictionary_name, entry_id,
                    sense_key_kind, entry_sense_count) VALUES (999, 'noad', 'NOAD', 'e', 'none', 1);
                PRAGMA user_version = 12;
                """)
        }
        #expect(throws: LedgerError.self) { _ = try Ledger(path: path) }
        #expect(Ledger.studyTables.isSuperset(of: ["study_notes", "study_note_lookups", "review_events",
                                                   "study_tags", "study_keep_metadata"]))
        #expect(Ledger.studyTables.isDisjoint(with: ["lookups", "sense_encounters",
                                                     "lookup_disposition_receipts", "keep_backfill"]))
    }
}
