import Foundation
@testable import XiaolaiDict
import XiaolaiDictCore
import Testing
import XiaolaiDictTestSupport

/// The store is opened at a path of the test's choosing, so nothing here touches the reader's own
/// ledger in Application Support.
struct LedgerStoreTests {
    @Test func aLookupIsRecordedThroughTheStore() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("xiaolaidict-store-\(UUID().uuidString).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try LedgerStore(path: path)
        let record = LookupRecord(
            surface: "saw", lemma: "see", context: "I saw it.", lemmaBasis: .inferred, language: "en",
            contextRange: NSRange(location: 2, length: 3),
            place: ReadingPlace(bundleID: "com.apple.TextEdit", name: "TextEdit"),
            lookedUpAt: Date(timeIntervalSince1970: 1_800_000_000), result: .notFound, answeredBy: .dictionaryService,
            quality: .accessibility(.accessibilityTextRange, context: .complete))
        let noad = DictionaryIdentity(
            name: "New Oxford American Dictionary", identifier: "com.apple.dictionary.NOAD", version: "2.6")
        let encounter = SenseEncounter(
            dictionary: noad, entryID: "m_en_gbus1017290", senseKey: "m_en_gbus1017290.005",
            senseKeyKind: .publisher, sensePath: SensePath(block: 1, ordinal: 1), entrySenseCount: 1,
            senseHash: "0123456789abcdef", gloss: "perceive with the eyes", chosenBy: .onlySense,
            chosenAt: Date(timeIntervalSince1970: 1_800_000_001))
        try await store.record(LookupRecording(record: record, encounter: encounter))
        // Read back through a second connection, as the study list will.
        let reopened = try Ledger(path: path)
        #expect(try reopened.history(of: "see") == [record])
        // The sense went in with the lookup it belongs to, in the same call.
        #expect(try reopened.encounters(ofLookup: 1) == [encounter])
    }

    @Test func anUnopenableLedgerIsAnError() {
        #expect(throws: LedgerError.self) { try LedgerStore(path: "/nonexistent-directory/ledger.sqlite") }
    }

    /// A first-ever launch gets a working ledger, **at the path every earlier launch used**.
    /// Literals, not `LedgerStore.directoryName`: the point is that the location cannot change
    /// without this failing, because a moved ledger is one the reader's history is not in.
    @Test func openDefaultCreatesTheLedgerWhereTheReadersHistoryLives() async throws {
        // `TemporaryDirectory`, which owns the removal. What stood here spelled the same thing in
        // a way the scan that enforces this rule cannot see: the token was split across two lines
        // and the directory was made by `appendingPathComponent(_:isDirectory:)`, so neither the
        // "temporarydirectory" line nor the "createDirectory" line carried both halves the scan
        // looks for. It leaked under a rule written to stop exactly this.
        let scratch = TemporaryDirectory(named: "xiaolaidict-open")

        let store = try await LedgerStore.openDefault(applicationSupport: scratch.url)

        #expect(try await store.recentLookups(since: Date(timeIntervalSince1970: 1_800_000_000), limit: 10).isEmpty)
        // Built from `scratch` rather than from a copy of its URL, so the directory is still alive
        // at the assertion: nothing else here holds it, and its removal is its deinit.
        let ledger = scratch.appending("XiaolaiDict/ledger.sqlite").path
        #expect(FileManager.default.fileExists(atPath: ledger), "the ledger is not where the reader's history is")
    }
}
