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
            surface: "saw", lemma: "see", context: "I saw it.", sourceApp: "com.apple.TextEdit", sourceURL: nil,
            lookedUpAt: Date(timeIntervalSince1970: 1_800_000_000), result: .notFound, answeredBy: .dictionaryService,
            quality: .accessibility(.accessibilityTextRange, context: .complete))
        try await store.record(record)
        // Read back through a second connection, as the study list will.
        #expect(try Ledger(path: path).history(of: "see") == [record])
    }

    @Test func anUnopenableLedgerIsAnError() {
        #expect(throws: LedgerError.self) { try LedgerStore(path: "/nonexistent-directory/ledger.sqlite") }
    }
}
