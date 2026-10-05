import DictionaryModel
import Foundation
import ReviewKit

/// Why a developer data operation did not run.
public enum DeveloperDataError: Error, Equatable {
    /// Test data is deployed into an empty ledger only, so it can never be mixed with a reader's own.
    case ledgerNotEmpty
}

/// What a deploy put in the ledger, counted from what was written and not from what was intended.
public struct TestDataReport: Equatable, Sendable {
    public let lookups: Int
    public let notes: Int
    public let reviewed: Int
}

/// **The developer pane's data operations.** Core and unconditional so they can be tested; reached only
/// from the pane, which a release does not contain.
extension Ledger {
    /// Tables that hold the schema's own state and not anything a reader made. **Clearing one would change
    /// how the ledger migrates, not what it contains.** `keep_backfill` is the cursor of the keep backfill.
    static let bookkeepingTables: Set<String> = ["keep_backfill"]

    /// Every table the schema holds, bookkeeping included. `DeveloperDataTests` pins this list against a
    /// literal, so a table added later fails there until it is classified as one or the other.
    func allTables() throws -> [String] {
        var names: [String] = []
        try run("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
                bind: []) { names.append(try $0.text(0)) }
        return names
    }

    /// The tables a reader's data lives in: all of them but the bookkeeping.
    func userTables() throws -> [String] {
        try allTables().filter { !Self.bookkeepingTables.contains($0) }
    }

    /// Readings and study notes, for the developer pane.
    public func developerCounts() throws -> (lookups: Int, notes: Int) {
        var lookups = 0, notes = 0
        try run("SELECT COUNT(*) FROM lookups", bind: []) { lookups = $0.integer(0) }
        try run("SELECT COUNT(*) FROM study_notes", bind: []) { notes = $0.integer(0) }
        return (lookups, notes)
    }

    /// Whether the ledger holds nothing a reader made.
    public func holdsNoUserData() throws -> Bool {
        try userTables().allSatisfy { table in
            var count = 0
            try? run("SELECT COUNT(*) FROM \(table)", bind: []) { count = $0.integer(0) }
            return count == 0
        }
    }

    /// Deletes every row of every table and nothing else: the schema, its version and the pragmas stay,
    /// so the ledger opens and writes exactly as before. Returns how many rows went.
    ///
    /// **Foreign keys are off for the deletion and read back on afterwards**, because the order tables
    /// reference one another in is the schema's business and not this function's; `foreign_key_check` must
    /// then be empty or the pragma is left off and this throws. The pages are scrubbed (`secure_delete`,
    /// `VACUUM`) like every other erase here.
    @discardableResult
    public func clearEveryRow() throws -> Int {
        let tables = try userTables()
        var removed = 0
        for table in tables {
            try run("SELECT COUNT(*) FROM \(table)", bind: []) { removed += $0.integer(0) }
        }
        guard removed > 0 else { return 0 }
        try execute("PRAGMA secure_delete = ON")
        try execute("PRAGMA foreign_keys = OFF")
        do {
            try inOneTransaction("clearEveryRow") {
                // **Twice**: deleting a note fires a trigger that records a tombstone in `removed_keep_targets`,
                // which may already have been emptied; the second pass removes what the first one made.
                for _ in 0..<2 {
                    for table in tables { try run("DELETE FROM \(table)", bind: []) { _ in } }
                }
            }
        } catch {
            try? execute("PRAGMA foreign_keys = ON")
            throw error
        }
        var violations = 0
        try run("PRAGMA foreign_key_check", bind: []) { _ in violations += 1 }
        try execute("PRAGMA foreign_keys = ON")
        var on = 0
        try run("PRAGMA foreign_keys", bind: []) { on = $0.integer(0) }
        guard violations == 0, on == 1 else { throw LedgerError.corruptRow("clearEveryRow left the ledger inconsistent") }
        try run("PRAGMA wal_checkpoint(TRUNCATE)", bind: []) { _ in }
        try execute("VACUUM")
        return removed
    }

    /// A small, deterministic ledger to develop against: lookups over thirty days, notes of each kind a
    /// surface differs on (a sense with the reader's own answer, one with the dictionary's, a model's
    /// unconfirmed proposal, a phrase, a paused note), and cards graded so that some are due, some not and
    /// some new. **Written through the same calls the app makes**, so `integrity()` holds.
    @discardableResult
    public func deployTestData(now: Date) throws -> TestDataReport {
        guard try holdsNoUserData() else { throw DeveloperDataError.ledgerNotEmpty }
        let dictionary = DictionaryIdentity.noad
        let day: TimeInterval = 86_400
        let places = [("com.apple.Safari", "Safari"), ("com.apple.iBooksX", "Books"), ("com.apple.Preview", "Preview")]
        let words: [(String, String)] = [
            ("laconic", "Her laconic reply ended the argument."),
            ("ephemeral", "Fame is ephemeral."),
            ("ubiquitous", "Phones are ubiquitous now."),
            ("candid", "He gave a candid answer."),
            ("fine", "She paid the fine on Friday."),
            ("hold", "The cargo sat in the hold."),
            ("rein", "He kept a tight rein on spending."),
            ("temper", "Heat tempers the steel."),
            ("sanction", "Sanctions were lifted in May."),
            ("table", "They will table the motion."),
            ("verbose", "A verbose report nobody read."),
            ("terse", "His terse note said little."),
        ]
        var lookupIDs: [String: Int] = [:]
        var lookups = 0
        for (index, entry) in words.enumerated() {
            // One to three readings each, on different days, so counts and "seen before" have something to say.
            for visit in 0..<(1 + index % 3) {
                let place = places[(index + visit) % places.count]
                let when = now.addingTimeInterval(-Double(1 + index * 2 + visit * 9) * day)
                let id = try record(LookupRecord(
                    surface: entry.0, lemma: entry.0, context: entry.1, lemmaBasis: .tagger, language: "en",
                    contextRange: nil, place: ReadingPlace(bundleID: place.0, name: place.1), lookedUpAt: when,
                    result: .found, answeredBy: .dictionaryService, quality: nil, script: .latin))
                lookupIDs[entry.0] = id
                lookups += 1
            }
        }
        func seeded(_ word: String) throws -> Int {
            guard let id = lookupIDs[word] else { throw DeveloperDataError.ledgerNotEmpty }
            return id
        }
        func enroll(_ word: String, _ chosenBy: SenseChoice, _ answer: StudyAnswer?, daysAgo: Double) throws -> StudyNote {
            try self.enroll(
                .sense(dictionary: dictionary, entryID: "t-\(word)", senseKey: "t-\(word).1", senseKeyKind: .publisher),
                issuer: .live, language: "en", chosenBy: chosenBy, answer: answer,
                lookupID: try seeded(word), at: now.addingTimeInterval(-daysAgo * day))
        }
        let mine = StudyAnswer(origin: .reader, text: "my own words for it")
        func given(_ word: String) -> StudyAnswer { StudyAnswer(origin: .dictionary, text: "what \(word) means") }
        let laconic = try enroll("laconic", .reader, mine, daysAgo: 28)
        let ephemeral = try enroll("ephemeral", .reader, given("ephemeral"), daysAgo: 24)
        let ubiquitous = try enroll("ubiquitous", .reader, given("ubiquitous"), daysAgo: 20)
        _ = try enroll("candid", .reader, mine, daysAgo: 12)
        _ = try enroll("fine", .onlySense, given("fine"), daysAgo: 9)
        let paused = try enroll("hold", .reader, given("hold"), daysAgo: 8)
        _ = try enroll("rein", .model, given("rein"), daysAgo: 6)   // an unconfirmed proposal
        _ = try enroll("verbose", .reader, nil, daysAgo: 3)         // no answer yet: needs one before review
        let phrase = try self.enroll(
            .phrase(dictionary: dictionary, text: "take something into account"),
            issuer: .inventory, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "consider something along with other factors"),
            lookupID: try seeded("table"), at: now.addingTimeInterval(-5 * day))
        try setPaused(true, ofNotes: [paused.id])

        // Graded through the scheduler, so due dates and memory state are the real ones: one due now, one not
        // due for a while, one lapsed.
        let scheduler = try MemoryScheduler()
        var reviewed = 0
        for (note, verdict, daysAgo) in [(laconic, Grade.good, 20.0), (ephemeral, .good, 2.0), (ubiquitous, .again, 3.0)] {
            let card = try existingCard(of: note.id).unwrap()
            try gradeSeeded(card: card, verdict, daysAgo: daysAgo, scheduler: scheduler, now: now, day: day)
            reviewed += 1
        }
        _ = phrase
        var notes = 0
        try run("SELECT COUNT(*) FROM study_notes", bind: []) { notes = $0.integer(0) }
        return TestDataReport(lookups: lookups, notes: notes, reviewed: reviewed)
    }

    private func gradeSeeded(card: StudyCard, _ verdict: Grade, daysAgo: Double, scheduler: MemoryScheduler,
                       now: Date, day: TimeInterval) throws {
        try self.grade(cardID: card.id, verdict, eventID: UUID(), expectedRevision: card.revision,
                       at: now.addingTimeInterval(-daysAgo * day), using: scheduler)
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw DeveloperDataError.ledgerNotEmpty }
        return self
    }
}
