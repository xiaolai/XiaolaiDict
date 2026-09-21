import Foundation
import XiaolaiDictCore
import Testing

/// Moving the reader's state from the paths the app used under its legacy name.
///
/// The failure this guards is the quiet one: a migration that reports success over an empty
/// destination looks exactly like a migration that worked, and the reader's history is simply
/// gone. So every case here asserts what *arrived*, never that a call returned.
struct StateMigrationTests {
    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    /// A directory nothing else is using, removed when the test ends.
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-migration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    private func record(_ lemma: String) -> LookupRecord {
        LookupRecord(
            surface: lemma, lemma: lemma, context: "A sentence with \(lemma) in it.",
            lemmaBasis: .tagger, language: "en", lookedUpAt: noon, result: .found,
            answeredBy: .dictionaryService, quality: nil)
    }

    /// A legacy directory holding a ledger of `lemmas`, plus the two sidecar files SQLite leaves
    /// beside it. They are written by hand rather than by SQLite so the test does not depend on
    /// when a checkpoint happens to run.
    private func seedLegacy(at directory: URL, lemmas: [String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("ledger.sqlite").path
        let ledger = try Ledger(path: path)
        for lemma in lemmas { _ = try ledger.record(record(lemma)) }
    }

    // MARK: - The ledger directory

    @Test func nothingToMoveWhenTheLegacyDirectoryWasNeverThere() throws {
        let root = temporaryDirectory()
        defer { remove(root) }

        let result = try StateMigration.migrateLedgerDirectory(
            from: root.appendingPathComponent("Legacy", isDirectory: true),
            to: root.appendingPathComponent("XiaolaiDict", isDirectory: true))

        #expect(result == .nothingToMove)
    }

    @Test func theLedgerMovesAndEveryRowArrives() throws {
        let root = temporaryDirectory()
        defer { remove(root) }
        let legacy = root.appendingPathComponent("Legacy", isDirectory: true)
        let current = root.appendingPathComponent("XiaolaiDict", isDirectory: true)
        try seedLegacy(at: legacy, lemmas: ["hold", "fine", "sanction"])

        let result = try StateMigration.migrateLedgerDirectory(from: legacy, to: current)

        #expect(result == .moved(lookups: 3))
        // The rows are readable at the new path — which is the claim, not that a call returned.
        let moved = try Ledger(path: current.appendingPathComponent("ledger.sqlite").path)
        #expect(try moved.lookupCount() == 3)
        #expect(FileManager.default.fileExists(atPath: legacy.path) == false)
    }

    /// The whole directory travels, not the database file alone. A ledger moved without its
    /// write-ahead log loses every write SQLite had not yet folded into the main file — on this
    /// developer's Mac that log was 449 KB against a 40 KB database.
    @Test func theSidecarFilesTravelWithTheDatabase() throws {
        let root = temporaryDirectory()
        defer { remove(root) }
        let legacy = root.appendingPathComponent("Legacy", isDirectory: true)
        let current = root.appendingPathComponent("XiaolaiDict", isDirectory: true)
        try seedLegacy(at: legacy, lemmas: ["hold"])
        for suffix in ["-wal", "-shm"] {
            try Data("sentinel".utf8)
                .write(to: legacy.appendingPathComponent("ledger.sqlite\(suffix)"))
        }

        _ = try StateMigration.migrateLedgerDirectory(from: legacy, to: current)

        for suffix in ["-wal", "-shm"] {
            let arrived = current.appendingPathComponent("ledger.sqlite\(suffix)")
            #expect(FileManager.default.fileExists(atPath: arrived.path), "ledger.sqlite\(suffix) was left behind")
        }
    }

    /// Anything else the directory holds goes too — the rule is "move the directory", so a file
    /// added later needs no change here.
    @Test func anUnrelatedFileInTheDirectoryTravelsToo() throws {
        let root = temporaryDirectory()
        defer { remove(root) }
        let legacy = root.appendingPathComponent("Legacy", isDirectory: true)
        let current = root.appendingPathComponent("XiaolaiDict", isDirectory: true)
        try seedLegacy(at: legacy, lemmas: ["hold"])
        try Data("notes".utf8).write(to: legacy.appendingPathComponent("something-later.json"))

        _ = try StateMigration.migrateLedgerDirectory(from: legacy, to: current)

        #expect(FileManager.default.fileExists(
            atPath: current.appendingPathComponent("something-later.json").path))
    }

    @Test func runningItTwiceIsSafeAndTheSecondRunMovesNothing() throws {
        let root = temporaryDirectory()
        defer { remove(root) }
        let legacy = root.appendingPathComponent("Legacy", isDirectory: true)
        let current = root.appendingPathComponent("XiaolaiDict", isDirectory: true)
        try seedLegacy(at: legacy, lemmas: ["hold", "fine"])

        #expect(try StateMigration.migrateLedgerDirectory(from: legacy, to: current) == .moved(lookups: 2))
        #expect(try StateMigration.migrateLedgerDirectory(from: legacy, to: current) == .nothingToMove)

        let moved = try Ledger(path: current.appendingPathComponent("ledger.sqlite").path)
        #expect(try moved.lookupCount() == 2)
    }

    /// Two ledgers are never merged. A reader who has already used the new app has state at the
    /// new path; overwriting or merging it would lose whichever side lost, silently.
    @Test func refusesToTouchEitherSideWhenBothDirectoriesExist() throws {
        let root = temporaryDirectory()
        defer { remove(root) }
        let legacy = root.appendingPathComponent("Legacy", isDirectory: true)
        let current = root.appendingPathComponent("XiaolaiDict", isDirectory: true)
        try seedLegacy(at: legacy, lemmas: ["hold", "fine", "sanction"])
        try seedLegacy(at: current, lemmas: ["temper"])

        let result = try StateMigration.migrateLedgerDirectory(from: legacy, to: current)

        #expect(result == .bothExist)
        #expect(try Ledger(path: legacy.appendingPathComponent("ledger.sqlite").path).lookupCount() == 3)
        #expect(try Ledger(path: current.appendingPathComponent("ledger.sqlite").path).lookupCount() == 1)
    }

    /// A legacy directory with no database in it is still moved — it may hold something else —
    /// and reports no lookups rather than failing.
    @Test func aLegacyDirectoryWithNoLedgerMovesAndReportsNoLookups() throws {
        let root = temporaryDirectory()
        defer { remove(root) }
        let legacy = root.appendingPathComponent("Legacy", isDirectory: true)
        let current = root.appendingPathComponent("XiaolaiDict", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: legacy.appendingPathComponent("notes.txt"))

        #expect(try StateMigration.migrateLedgerDirectory(from: legacy, to: current) == .moved(lookups: 0))
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("notes.txt").path))
    }

    // MARK: - The defaults domain

    private func domain() -> String { "xiaolaidict.migration.test.\(UUID().uuidString)" }

    private func forget(_ names: String...) {
        for name in names { UserDefaults.standard.removePersistentDomain(forName: name) }
    }

    @Test func everyKeyTheOldDomainHeldArrivesInTheNewOne() throws {
        let (old, new) = (domain(), domain())
        defer { forget(old, new) }
        let source = try #require(UserDefaults(suiteName: old))
        source.set("⌃⌥D", forKey: "LookupShortcut")
        source.set("frosted", forKey: "DrawerGlass")
        source.set(false, forKey: "HoverEnabled")

        let moved = StateMigration.migrateDefaults(from: old, to: new)

        #expect(moved == 3)
        let destination = try #require(UserDefaults(suiteName: new))
        #expect(destination.string(forKey: "LookupShortcut") == "⌃⌥D")
        #expect(destination.string(forKey: "DrawerGlass") == "frosted")
        #expect(destination.bool(forKey: "HoverEnabled") == false)
    }

    /// Only keys the old domain itself holds. `dictionaryRepresentation()` returns the *merged*
    /// view — the global domain included — so copying that would pour system-wide preferences
    /// into the app's own domain.
    @Test func systemWidePreferencesAreNotCopiedIn() throws {
        let (old, new) = (domain(), domain())
        defer { forget(old, new) }
        let source = try #require(UserDefaults(suiteName: old))
        source.set("frosted", forKey: "DrawerGlass")

        _ = StateMigration.migrateDefaults(from: old, to: new)

        let destination = try #require(UserDefaults(suiteName: new))
        // A key every process sees through the global domain, which this app never set.
        #expect(destination.persistentDomain(forName: new)?["AppleLanguages"] == nil)
        #expect(destination.persistentDomain(forName: new)?.count == 1)
    }

    /// A value the reader has already set under the new name wins. They have used the new app;
    /// the old domain is the stale one.
    @Test func aValueAlreadySetUnderTheNewNameIsNotOverwritten() throws {
        let (old, new) = (domain(), domain())
        defer { forget(old, new) }
        let source = try #require(UserDefaults(suiteName: old))
        source.set("frosted", forKey: "DrawerGlass")
        source.set("⌃⌥D", forKey: "LookupShortcut")
        let destination = try #require(UserDefaults(suiteName: new))
        destination.set("clear", forKey: "DrawerGlass")

        let moved = StateMigration.migrateDefaults(from: old, to: new)

        #expect(moved == 1)
        #expect(destination.string(forKey: "DrawerGlass") == "clear")
        #expect(destination.string(forKey: "LookupShortcut") == "⌃⌥D")
    }

    @Test func migratingDefaultsTwiceMovesNothingTheSecondTime() throws {
        let (old, new) = (domain(), domain())
        defer { forget(old, new) }
        let source = try #require(UserDefaults(suiteName: old))
        source.set("frosted", forKey: "DrawerGlass")

        #expect(StateMigration.migrateDefaults(from: old, to: new) == 1)
        #expect(StateMigration.migrateDefaults(from: old, to: new) == 0)
    }

    @Test func anOldDomainThatHoldsNothingMovesNothing() {
        let (old, new) = (domain(), domain())
        defer { forget(old, new) }
        #expect(StateMigration.migrateDefaults(from: old, to: new) == 0)
    }
}
