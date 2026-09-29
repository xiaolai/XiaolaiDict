import DictionaryModel
import Foundation
import Testing
@testable import XiaolaiDictCore

/// **Recovery and erasure.** WI-006, and the gate P0 closes on.
///
/// Four claims, each of which is easy to believe and hard to notice is false: a restored copy is
/// whole, a committed grade survives a restart exactly once, an erase reaches the copies this app
/// made, and a broken study system still lets the reader look a word up.
struct StudyRecoveryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() -> (String, () -> Void) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-recovery-\(UUID().uuidString).sqlite").path
        return (path, {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            let name = URL(fileURLWithPath: path).lastPathComponent
            for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            where file.hasPrefix(name) {
                try? FileManager.default.removeItem(at: directory.appending(path: file))
            }
        })
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
        let card = try #require(try ledger.card(of: note.id, at: now))
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
        try ledger.execute("DROP INDEX study_cards_question")
        try ledger.execute("""
            INSERT INTO study_cards (id, note_id, prompt, phase, paused, revision, scheduler_version,
                                     created_at)
            SELECT 'second', note_id, prompt, phase, paused, revision, scheduler_version, created_at
            FROM study_cards LIMIT 1
            """)
        let problems = try ledger.integrity()
        #expect(problems.contains { $0.hasPrefix("duplicate cards") }, "got \(problems)")
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
            let card = try #require(try ledger.card(of: note.id, at: now))
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
        #expect(Ledger.appManagedBackups(besides: path).count == 1)

        let ledger = try Ledger(path: path)
        let report = try ledger.eraseReadingData(at: path)
        #expect(report.lookupsRemoved == 1)
        #expect(report.backupsRemoved.count == 1)
        #expect(report.isComplete)
        #expect(Ledger.appManagedBackups(besides: path).isEmpty)
        #expect(try ledger.history(of: "fine").isEmpty)
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
        // And enrolling fails loudly rather than pretending it worked.
        #expect(throws: (any Error).self) {
            try ledger.enroll(.entry(dictionary: "noad", entryID: "e1"), issuer: .live,
                              language: "en", chosenBy: nil,
                              answer: StudyAnswer(origin: .reader, text: "x"), lookupID: id,
                              at: self.now)
        }
    }
}
