import Foundation
@testable import XiaolaiDict
import XiaolaiDictCore
import Testing

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
}
