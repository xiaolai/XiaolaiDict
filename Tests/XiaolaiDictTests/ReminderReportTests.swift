import Foundation
import ReviewKit
import SQLite3
import StudyKit
@testable import StudyModels
import Testing
import XiaolaiDictUI
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **`--reminder-report`: the grant, what is pending and when it fires, what the reader's settings
/// plan, and the log — never what a banner says.**
///
/// The `reminder` end-to-end stage reads this from inside the bundle, where the real notification
/// center answers. Here the same function is run over the fake center.
@MainActor
struct ReminderReportTests {
    private static let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private let now = Date(timeIntervalSince1970: 1_791_165_600)  // 2026-10-05 10:00 in Shanghai

    private func report(_ path: String, _ center: FakeReminderCenter,
                        _ defaults: UserDefaults) async throws -> (CommandStatus, String, [String: Any]) {
        var lines: [String] = []
        let status = await ReminderReport.run(
            scheduling: center, store: Wiring.store(path), primary: { PrimaryDictionary(chosen: "noad") },
            defaults: defaults, clock: { self.now }, zone: { Self.shanghai },
            write: { lines.append($0); return true })
        let line = try #require(lines.last, "the instrument wrote nothing")
        #expect(lines.count == 1, "one report, one line: \(lines)")
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return (status, line, decoded)
    }

    /// **The instrument changes no ledger** (audit-fix round 1). It began opening the reader's ledger
    /// through the app's own door before it read a setting — which creates one where there is none
    /// and migrates an older one, with reminders off and nothing to plan. It opens on demand, only a
    /// ledger that exists, and only at this build's schema.
    @Test func theInstrumentNeverCreatesOrUpgradesALedger() async throws {
        let support = ScratchFile.unmade("reminder-report-support", file: "support")
        defer { ScratchFile.remove(support.path) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let ledgerPath = support.appending(path: LedgerStore.directoryName).appending(path: LedgerStore.fileName).path

        // Asked for nothing, it opens nothing.
        var opens = 0
        let store = ReminderReport.ledgerOnDemand { opens += 1; return try await LedgerStore.openForReading(applicationSupport: support) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(opens == 0, "the ledger was opened before anything asked for it")

        // None there: refused, and none made.
        await #expect(throws: (any Error).self) { try await store()?.value }
        #expect(opens == 1)
        #expect(!FileManager.default.fileExists(atPath: ledgerPath), "a reader that changes nothing made a ledger")

        // An older schema: refused, and not upgraded — no copy written, the version as it was.
        try FileManager.default.createDirectory(atPath: (ledgerPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        _ = try Ledger(path: ledgerPath)
        try Self.setUserVersion(Ledger.schemaVersion - 1, at: ledgerPath)
        await #expect(throws: (any Error).self) {
            try await LedgerStore.openForReading(applicationSupport: support)
        }
        #expect(try Self.userVersion(at: ledgerPath) == Ledger.schemaVersion - 1, "it was migrated")
        #expect(!FileManager.default.fileExists(atPath: ledgerPath + ".schema\(Ledger.schemaVersion - 1).backup"))

        // **The control**: at this build's schema it opens, once, however often it is asked for.
        try Self.setUserVersion(Ledger.schemaVersion, at: ledgerPath)
        opens = 0
        let current = ReminderReport.ledgerOnDemand { opens += 1; return try await LedgerStore.openForReading(applicationSupport: support) }
        _ = try await current()?.value
        _ = try await current()?.value
        #expect(opens == 1)
    }

    /// **Opened for reading is opened read-only, and the file is byte for byte what it was** (audit-fix
    /// round 2). Round 1 checked the version first and then opened through the writable door, which
    /// switched the journal to WAL — a change to the file's header — took `BEGIN IMMEDIATE`, and would
    /// have created or migrated whatever was at the path by the time of the second open. One read-only
    /// connection, the version read on it, is the whole door now; SQLite refuses a write through it.
    @Test func theReadingDoorWritesNothingAndCannot() async throws {
        let support = ScratchFile.unmade("reminder-report-readonly", file: "support")
        defer { ScratchFile.remove(support.path) }
        let directory = support.appending(path: LedgerStore.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledgerPath = directory.appending(path: LedgerStore.fileName).path
        try Wiring.save(try Ledger(path: ledgerPath), "quixotic", at: now)
        // The rollback journal, so a switch to WAL is a change to the bytes of the file itself.
        try Self.exec("PRAGMA journal_mode = DELETE", at: ledgerPath)
        let before = try Data(contentsOf: URL(fileURLWithPath: ledgerPath))

        do {
            let store = try await LedgerStore.openForReading(applicationSupport: support)
            _ = try await store.sittingCandidates(dictionary: nil, introducedSince: now)
            #expect(try await store.libraryCount(LibraryQuery()) == 1, "the read-only door read nothing")
            await #expect(throws: (any Error).self, "a write went through the read-only door") {
                try await store.ignoreSuggestion(lemma: "quixotic", language: "en", at: self.now)
            }
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: ledgerPath)) == before,
                "opening for reading changed the file")
        #expect(try Self.journalMode(at: ledgerPath) == "delete", "opening for reading switched the journal")

        // **And the shape the E2E stages leave**: a write-ahead-log ledger with neither its log nor its
        // index beside it, which the reminder stage reads right after a restore. Opened read-only all
        // the same — SQLite makes the two sidecars in the writable folder — and the file is untouched.
        let walSupport = ScratchFile.unmade("reminder-report-wal", file: "support")
        defer { ScratchFile.remove(walSupport.path) }
        let walDirectory = walSupport.appending(path: LedgerStore.directoryName)
        try FileManager.default.createDirectory(at: walDirectory, withIntermediateDirectories: true)
        let walPath = walDirectory.appending(path: LedgerStore.fileName).path
        do {
            let writer = try Ledger(path: walPath)
            try Wiring.save(writer, "quixotic", at: now)
        }
        // macOS's SQLite keeps the sidecars past the last close, the log emptied by its checkpoint; the
        // stages remove them, as a restore does, and so does this.
        let log = try FileManager.default.attributesOfItem(atPath: walPath + "-wal")[.size] as? Int
        try #require(log == 0, "the log still holds writes, so removing it would lose them")
        try FileManager.default.removeItem(atPath: walPath + "-wal")
        try FileManager.default.removeItem(atPath: walPath + "-shm")
        let walBefore = try Data(contentsOf: URL(fileURLWithPath: walPath))
        do {
            let store = try await LedgerStore.openForReading(applicationSupport: walSupport)
            #expect(try await store.libraryCount(LibraryQuery()) == 1, "a sidecar-less WAL ledger did not read")
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: walPath)) == walBefore,
                "opening a WAL ledger for reading changed the file")
        // The control, from the header itself: bytes 18 and 19 are 2 in a write-ahead-log database. A
        // read-only connection is no witness here — it cannot open this shape, which is the point.
        #expect(walBefore.count > 19 && walBefore[18] == 2 && walBefore[19] == 2, "the control: this ledger was a WAL one")
    }

    private static func exec(_ sql: String, at path: String) throws {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        try #require(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        try #require(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }

    private static func userVersion(at path: String) throws -> Int {
        var handle: OpaquePointer?, statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(handle) }
        try #require(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        try #require(sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK)
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func journalMode(at path: String) throws -> String {
        var handle: OpaquePointer?, statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(handle) }
        try #require(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        try #require(sqlite3_prepare_v2(handle, "PRAGMA journal_mode", -1, &statement, nil) == SQLITE_OK)
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        return String(cString: sqlite3_column_text(statement, 0))
    }

    /// Writes `PRAGMA user_version` through a connection of its own: opening a `Ledger` would migrate.
    private static func setUserVersion(_ version: Int, at path: String) throws {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        try #require(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        try #require(sqlite3_exec(handle, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK)
    }

    /// **Grant, pending, fire dates, plan and log — and no word of a banner.** Run after the app's own
    /// coordinator added a week of requests from a ledger holding *quixotic*.
    @Test func theInstrumentPrintsWhatIsPendingAndNoContent() async throws {
        let (path, clean) = Wiring.scratch("reminder-report")
        defer { clean() }
        try Wiring.save(try Ledger(path: path), "quixotic", at: now.addingTimeInterval(-10 * 86_400))
        let defaults = TemporaryDefaults.suite()
        let center = FakeReminderCenter()
        let reminders = ReminderCoordinator(
            scheduling: center, defaults: defaults, store: Wiring.store(path),
            primary: { PrimaryDictionary(chosen: "noad") }, clock: { self.now }, zone: { Self.shanghai },
            triggers: ReminderTriggers(system: NotificationCenter(), workspace: NotificationCenter(),
                                       ledger: LedgerChanges(), studyDictionary: { "noad" }))
        // Turned on the reader's way: the switch writes a log first, then plans.
        await reminders.setEnabled(true)

        let (status, line, report) = try await report(path, center, defaults)
        #expect(status == .success)
        #expect(report["logRead"] as? String == "log")
        #expect(report["grant"] as? String == "granted")
        #expect(report["enabled"] as? Bool == true)
        #expect(report["zone"] as? String == "Asia/Shanghai")
        #expect(report["horizon"] as? Int == ReminderRecommendation.horizon)
        let pending = try #require(report["pending"] as? [[String: Any]])
        #expect(pending.count == ReminderRecommendation.horizon)
        let first = try #require(pending.first)
        #expect(first["id"] as? String == "review.2026-10-05")
        #expect(first["fireAt"] as? Double == 1_791_198_000)  // 19:00 in Shanghai
        let planned = try #require(report["planned"] as? [[String: Any]])
        #expect(planned.map { $0["id"] as? String } == pending.map { $0["id"] as? String })
        let log = try #require(report["log"] as? [[String: Any]])
        #expect(log.first?["id"] as? String == "review.2026-10-05")
        #expect(log.first?["state"] as? String == "added")
        #expect(log.first?["fireAt"] as? Double == 1_791_198_000)

        for said in ["quixotic", "means", "A sitting", "is ready", "Skip Today", "Later"] {
            #expect(!line.contains(said), "the instrument printed what a banner or a card says: \(said)")
        }
    }

    /// **On, and no log: the report plans what the coordinator would** — a lost log, today spent — and
    /// says the key held nothing, rather than printing a stand-in as if it had been kept (WI-8).
    @Test func aLostLogIsPlannedAsTheCoordinatorPlansIt() async throws {
        let (path, clean) = Wiring.scratch("reminder-report-lost")
        defer { clean() }
        try Wiring.save(try Ledger(path: path), "quixotic", at: now.addingTimeInterval(-10 * 86_400))
        let defaults = TemporaryDefaults.suite()
        ReminderSettingsStore(defaults: defaults).save(ReminderSettings(isEnabled: true))
        let (status, _, report) = try await report(path, FakeReminderCenter(), defaults)
        #expect(status == .success)
        #expect(report["logRead"] as? String == "absent")
        #expect((report["log"] as? [Any])?.isEmpty == true, "a stand-in was printed as the kept log")
        let planned = try #require(report["planned"] as? [[String: Any]])
        #expect(planned.first?["id"] as? String == "review.2026-10-06", "today was planned over a lost log")
        #expect(planned.count == ReminderRecommendation.horizon - 1)
    }

    /// Off: nothing planned, and the report says so rather than reading as a broken plan.
    @Test func offPlansNothing() async throws {
        let (path, clean) = Wiring.scratch("reminder-report-off")
        defer { clean() }
        try Wiring.save(try Ledger(path: path), "quixotic", at: now.addingTimeInterval(-10 * 86_400))
        let (status, _, report) = try await report(path, FakeReminderCenter(grant: .notAsked),
                                                   TemporaryDefaults.suite())
        #expect(status == .success)
        #expect(report["enabled"] as? Bool == false)
        #expect(report["grant"] as? String == "notAsked")
        #expect((report["planned"] as? [Any])?.isEmpty == true)
        #expect((report["pending"] as? [Any])?.isEmpty == true)
    }

    /// **Compiled out of a release**, as `--read-point` and `--read-selection` are: a bare `swift test`
    /// is built without the development flag, so here it must refuse.
    @Test func theInstrumentIsNotBuiltIntoARelease() async {
#if XIAOLAIDICT_CAPTURE_INSTRUMENTS
        #expect(Bool(true))
#else
        #expect(await ReminderReport.run() == .usage, "a release must refuse --reminder-report")
#endif
    }
}
