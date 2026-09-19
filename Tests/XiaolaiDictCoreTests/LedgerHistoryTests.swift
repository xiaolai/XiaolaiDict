import Foundation
import XiaolaiDictCore
import Testing

/// What the history drawer reads: recent lookups, newest first, as `ReadingEntry` values that
/// deliberately cannot carry a definition.
struct LedgerHistoryTests {
    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-history-\(UUID().uuidString).sqlite").path
    }

    private func removeDatabase(at path: String) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func record(
        _ lemma: String, at when: Date, result: LookupResult = .found,
        context: String = "A sentence.", range: NSRange? = NSRange(location: 2, length: 8),
        place: ReadingPlace = ReadingPlace(bundleID: "com.apple.TextEdit", name: "TextEdit")
    ) -> LookupRecord {
        LookupRecord(
            surface: lemma, lemma: lemma, context: context, lemmaBasis: .tagger, language: "en",
            contextRange: range, place: place, lookedUpAt: when, result: result,
            answeredBy: .dictionaryService, quality: nil)
    }

    private func withLedger(_ body: (Ledger) throws -> Void) throws {
        let path = temporaryPath()
        defer { removeDatabase(at: path) }
        try body(try Ledger(path: path))
    }

    @Test func recentLookupsComeBackNewestFirst() throws {
        try withLedger { ledger in
            _ = try ledger.record(record("older", at: noon.addingTimeInterval(-3600)))
            _ = try ledger.record(record("newer", at: noon))

            let found = try ledger.recentLookups(since: noon.addingTimeInterval(-86400), limit: 50)
            #expect(found.map(\.lemma) == ["newer", "older"])
        }
    }

    @Test func aLookupOlderThanTheCutoffIsLeftOut() throws {
        try withLedger { ledger in
            _ = try ledger.record(record("ancient", at: noon.addingTimeInterval(-86400 * 30)))
            _ = try ledger.record(record("recent", at: noon))

            let found = try ledger.recentLookups(since: noon.addingTimeInterval(-86400), limit: 50)
            #expect(found.map(\.lemma) == ["recent"])
        }
    }

    /// The drawer holds a bounded number of cards; a ledger years deep must not arrive whole.
    @Test func theLimitCapsHowManyComeBack() throws {
        try withLedger { ledger in
            for index in 0..<10 {
                _ = try ledger.record(record("w\(index)", at: noon.addingTimeInterval(Double(index))))
            }
            let found = try ledger.recentLookups(since: noon.addingTimeInterval(-86400), limit: 3)
            #expect(found.count == 3)
            // The newest three, not the first three off the disk.
            #expect(found.map(\.lemma) == ["w9", "w8", "w7"])
        }
    }

    @Test func aLimitOfNoneAsksForNothingRatherThanEverything() throws {
        try withLedger { ledger in
            _ = try ledger.record(record("fine", at: noon))
            let none = try ledger.recentLookups(since: .distantPast, limit: 0)
            let negative = try ledger.recentLookups(since: .distantPast, limit: -5)
            #expect(none.isEmpty)
            #expect(negative.isEmpty)
        }
    }

    /// The card has to be traceable to the lookup it came from, so the id is the ledger's own.
    @Test func eachEntryCarriesItsLedgerRowID() throws {
        try withLedger { ledger in
            let first = try ledger.record(record("fine", at: noon))
            let second = try ledger.record(record("hold", at: noon.addingTimeInterval(1)))

            let found = try ledger.recentLookups(since: .distantPast, limit: 50)
            #expect(found.map(\.id) == [second, first])
        }
    }

    @Test func theSentenceAndWhereItWasReadSurvive() throws {
        try withLedger { ledger in
            _ = try ledger.record(record(
                "hold", at: noon, context: "The ship's hold was full.",
                range: NSRange(location: 11, length: 4),
                place: ReadingPlace(
                    bundleID: "com.apple.Safari", name: "Safari",
                    page: "https://example.com/a", title: "A page")))

            let found = try ledger.recentLookups(since: .distantPast, limit: 50)
            let entry = try #require(found.first)
            #expect(entry.sentence == "The ship's hold was full.")
            #expect(entry.sentenceRange == NSRange(location: 11, length: 4))
            #expect(entry.place.name == "Safari")
            #expect(entry.place.precision == .page)
        }
    }

    /// A miss is recorded on purpose — usually a typo or a stray selection — so review can tell it
    /// from a real gap. It comes back marked, never silently dropped.
    @Test func aMissComesBackMarkedAsOne() throws {
        try withLedger { ledger in
            _ = try ledger.record(record("qqqq", at: noon, result: .notFound))
            let found = try ledger.recentLookups(since: .distantPast, limit: 50)
            let entry = try #require(found.first)
            #expect(entry.result == .notFound)
        }
    }

    @Test func anEmptyLedgerHasNoHistory() throws {
        try withLedger { ledger in
            let found = try ledger.recentLookups(since: .distantPast, limit: 50)
            #expect(found.isEmpty)
        }
    }

    /// Two lookups sharing a timestamp must not swap places between one reading and the next, or
    /// the drawer reorders itself under the reader for no reason.
    @Test func lookupsSharingATimestampAreOrderedByRowID() throws {
        try withLedger { ledger in
            let first = try ledger.record(record("a", at: noon))
            let second = try ledger.record(record("b", at: noon))

            let found = try ledger.recentLookups(since: .distantPast, limit: 50)
            #expect(found.map(\.id) == [second, first])
        }
    }
}
