import Foundation
import XiaolaiDictCore
import XiaolaiDictTestSupport
import Testing

/// Schema 7: the script a looked-up word is written in.
///
/// It is stored rather than derived at read time for the reason every other column here is: the
/// drawer has to *filter* on it, and a predicate SQLite cannot see has to be applied after `LIMIT`
/// — which would hand the reader fewer cards than they asked for and call it a day's history.
///
/// **The same predicate as the hover gate, deliberately.** The reader sets one thing — the scripts
/// they study — and it governs both whether a hover fires and whether the row reaches the drawer.
/// Filtering here on `language` instead would have been the near miss: it is already stored, and it
/// is `NLLanguageRecognizer`'s answer, which on a single word is a guess. Two layers answering one
/// setting with two different rules is how a filter comes to look broken.
struct LedgerSchema7Tests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// One scratch directory per test, removed by its own owner — the rule every fixture here
    /// follows, and the reason a full run leaves nothing behind.
    private func withLedger(_ body: (Ledger) throws -> Void) throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-schema7")
        try body(try Ledger(path: scratch.url.appending(path: "ledger.sqlite").path))
    }

    private func record(
        _ surface: String, script: ProbeScript?, at offset: TimeInterval = 0
    ) -> LookupRecord {
        LookupRecord(
            surface: surface, lemma: surface, context: surface, lemmaBasis: .surface,
            language: nil, contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now.addingTimeInterval(offset), result: .found,
            answeredBy: .dictionaryService,
            quality: .accessibility(.accessibilityTextMarkers, context: .complete),
            script: script)
    }

    /// The column survives the round trip. Without this the filter below would pass for the wrong
    /// reason — every row unclassified is every row visible.
    @Test func theScriptIsWrittenAndReadBack() throws {
        try withLedger { ledger in
            _ = try ledger.record(record("水", script: .han))
            let back = try #require(
                try ledger.recentLookups(since: now.addingTimeInterval(-60), limit: 5,
                                         studying: Set(ProbeScript.allCases)).first)
            #expect(back.surface == "水")

            // **Read back through the other reader too.** Checking `surface` alone is what let the
            // column go missing from `history(of:)` entirely: the write worked, the drawer worked,
            // and every record that reader returned carried `script: nil` — a value that reads
            // exactly like a row from before the schema. The assertion has to name the column.
            let recorded = try #require(try ledger.history(of: "水").first)
            #expect(recorded.script == .han, "history(of:) dropped the script it was written with")
        }
    }

    /// A reader studying Latin does not see the Chinese words they passed over.
    @Test func aRowInAScriptTheReaderDoesNotStudyIsNotDrawn() throws {
        try withLedger { ledger in
            _ = try ledger.record(record("hold", script: .latin, at: -2))
            _ = try ledger.record(record("水", script: .han, at: -1))

            let latin = try ledger.recentLookups(
                since: now.addingTimeInterval(-60), limit: 50, studying: [.latin])
            #expect(latin.map(\.surface) == ["hold"], "a han row reached a Latin-only drawer")

            let both = try ledger.recentLookups(
                since: now.addingTimeInterval(-60), limit: 50, studying: [.latin, .han])
            #expect(Set(both.map(\.surface)) == ["hold", "水"])
        }
    }

    /// **A row whose script was never recorded stays visible.** Every lookup made before this
    /// schema has NULL here, and hiding history that cannot be classified is the worse error: the
    /// reader would open the drawer after an update and find their past emptied, with the filter
    /// they never touched to blame. NULL means unknown, as it does in every other column added
    /// late — never a guessed value, and never a reason to drop a row.
    @Test func aRowWithNoRecordedScriptIsStillDrawn() throws {
        try withLedger { ledger in
            _ = try ledger.record(record("ancient", script: nil))
            let drawn = try ledger.recentLookups(
                since: now.addingTimeInterval(-60), limit: 50, studying: [.han])
            #expect(drawn.map(\.surface) == ["ancient"], "an unclassified row was hidden by the filter")
        }
    }

    /// The filter is applied by SQLite and not after the fact, so `limit` still means what it says.
    /// Applied in Swift after the query, a day holding 30 Chinese words and 5 English ones would
    /// answer a limit of 10 with 5 — the drawer silently short, and nothing to say why.
    @Test func theLimitCountsRowsTheReaderWillSee() throws {
        try withLedger { ledger in
            for index in 0..<30 { _ = try ledger.record(record("水\(index)", script: .han, at: -Double(index) - 10)) }
            for index in 0..<5 { _ = try ledger.record(record("word\(index)", script: .latin, at: -Double(index))) }

            let drawn = try ledger.recentLookups(
                since: now.addingTimeInterval(-600), limit: 10, studying: [.latin])
            #expect(drawn.count == 5, "the han rows were counted against the limit before being dropped")
        }
    }

    /// **A lookup and the sense it met are one write or neither.**
    ///
    /// They were two statements with nothing around them, so an encounter that failed left the
    /// lookup persisted while the caller was told the recording had failed — and the caller's
    /// answer to that is to drop the lookup id, which is what a reader's later tap would have been
    /// hung off. The row survives unreachable: a lookup with no sense and no way to give it one.
    ///
    /// **The rollback itself has no test, and that is a statement about the schema rather than an
    /// omission.** Every column on `sense_encounters` is `NOT NULL` over a Swift type that cannot
    /// be nil, there is no unique index, and the foreign key is satisfied by construction because
    /// the transaction supplies the id it just inserted — so no value reachable through this API
    /// makes the *second* insert fail while the first succeeds. Opening the ledger read-only fails
    /// both and proves nothing about ordering. What is asserted here is the success path: both
    /// rows land together, and the id returned is the one the sense is attached to. The savepoint
    /// is insurance against a schema that grows a constraint later, and if one is ever added, the
    /// failure it introduces is what should bring a rollback test with it.
    @Test func aLookupAndItsSenseAreWrittenTogether() throws {
        try withLedger { ledger in
            let encounter = SenseEncounter(
                dictionary: DictionaryIdentity(name: "NOAD"), entryID: "m_en_1",
                senseKey: "m_en_1.001", senseKeyKind: .publisher, sensePath: nil,
                entrySenseCount: 3, senseHash: nil, gloss: "a penalty", chosenBy: .model,
                chosenAt: now)
            let id = try ledger.record(record("fine", script: .latin), with: encounter)

            let recorded = try ledger.history(of: "fine")
            #expect(recorded.count == 1)
            let met = try ledger.encounters(ofLookup: id)
            #expect(met.map(\.senseKey) == ["m_en_1.001"],
                    "the sense was not attached to the id the lookup came back with")
        }
    }
}
