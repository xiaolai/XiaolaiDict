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
        place: ReadingPlace = ReadingPlace(bundleID: "com.apple.TextEdit", name: "TextEdit"),
        quality: CaptureQuality? = nil, partOfSpeech: String? = nil
    ) -> LookupRecord {
        LookupRecord(
            surface: lemma, lemma: lemma, context: context, lemmaBasis: .tagger, language: "en",
            contextRange: range, partOfSpeech: partOfSpeech, place: place, lookedUpAt: when,
            result: result, answeredBy: .dictionaryService, quality: quality)
    }

    private func encounter(
        gloss: String?, ordinal: Int?, outOf: Int, chosenBy: SenseChoice?
    ) -> SenseEncounter {
        SenseEncounter(
            dictionary: DictionaryIdentity(name: "NOAD"), entryID: "headword:temper",
            senseKey: "m_en_us1294316.004", senseKeyKind: .publisher,
            sensePath: ordinal.map { SensePath(block: 1, ordinal: $0) }, entrySenseCount: outOf,
            senseHash: nil, gloss: gloss, chosenBy: chosenBy, chosenAt: nil)
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

    // MARK: - How good the capture was

    /// The drawer cannot honour "a degraded capture never renders as confidently as a clean one"
    /// unless the query hands it the quality. It was selecting every other column and not this one,
    /// so a card had no way to tell a sentence from the selection echoed back into the column.
    @Test func howGoodTheCaptureWasReachesTheDrawer() throws {
        try withLedger { ledger in
            _ = try ledger.record(record(
                "qqqq", at: noon, context: "qqqq", range: nil,
                quality: .accessibility(.accessibilityTextRange, context: .missing)))

            let found = try ledger.recentLookups(since: .distantPast, limit: 50)
            let entry = try #require(found.first)
            #expect(entry.quality?.context == .missing)
            // And the card built from it says nothing rather than printing the word twice.
            #expect(entry.cue == .none)
        }
    }

    @Test func aCutSentenceComesBackKnownToBeCut() throws {
        try withLedger { ledger in
            _ = try ledger.record(record(
                "hold", at: noon, context: "The ship's hold was",
                quality: .accessibility(.accessibilityTextMarkers, context: .mayBeCut)))

            let entry = try #require(try ledger.recentLookups(since: .distantPast, limit: 50).first)
            #expect(entry.quality?.context == .mayBeCut)
            #expect(entry.cue == .truncatedSentence)
        }
    }

    /// Recognised text is the one source that can be *wrong* rather than absent, so its confidence
    /// has to survive the trip as well as its context.
    @Test func theRecognisersOwnConfidenceSurvives() throws {
        try withLedger { ledger in
            let read = try #require(CaptureQuality(
                source: .opticalRecognition, confidence: 0.62, context: .complete))
            _ = try ledger.record(record("hold", at: noon, quality: read))

            let entry = try #require(try ledger.recentLookups(since: .distantPast, limit: 50).first)
            #expect(entry.quality?.source == .opticalRecognition)
            #expect(entry.quality?.confidence == 0.62)
        }
    }

    /// Rows written before schema 4 have no quality at all. They must come back without one rather
    /// than with a made-up one — an invented `.complete` would be the drawer claiming a context
    /// nothing ever captured.
    @Test func aRowWrittenBeforeTheQualityColumnComesBackWithoutOne() throws {
        try withLedger { ledger in
            _ = try ledger.record(record("hold", at: noon, quality: nil))
            let entry = try #require(try ledger.recentLookups(since: .distantPast, limit: 50).first)
            #expect(entry.quality == nil)
        }
    }

    // MARK: - How the word was being used

    /// Recorded from schema 5 on, because the selector already knew it. Every card before that had
    /// to guess from the sentence.
    @Test func aRecordedPartOfSpeechComesBackAsRecorded() throws {
        try withLedger { ledger in
            _ = try ledger.record(record(
                "hold", at: noon, context: "Hold the line.", partOfSpeech: "verb"))
            let entry = try #require(try ledger.recentLookups(since: .distantPast, limit: 50).first)
            #expect(entry.partOfSpeech == "verb")
        }
    }

    /// The rows written before schema 5 — most of them, for a long time. A hole on the card would
    /// be a worse answer than one read off the reader's own sentence.
    @Test func aRowWithoutOneIsTaggedFromTheSentence() throws {
        try withLedger { ledger in
            // A range that actually covers the word: the capture's own answer to where it is, and
            // what the tagger is handed. The default fixture range points elsewhere in the
            // sentence, which is a fine way to test that the range is honoured and a poor way to
            // test the tagging.
            _ = try ledger.record(record(
                "hold", at: noon, context: "The ship's hold was full.",
                range: ("The ship's hold was full." as NSString).range(of: "hold"),
                partOfSpeech: nil))
            let entry = try #require(try ledger.recentLookups(since: .distantPast, limit: 50).first)
            #expect(entry.partOfSpeech == "noun")
        }
    }

    /// What was stored wins over what could be guessed: the selector saw the entry, the tagger
    /// only sees the grammar.
    @Test func whatWasStoredIsNotOverriddenByTheGuess() throws {
        try withLedger { ledger in
            _ = try ledger.record(record(
                "hold", at: noon, context: "The ship's hold was full.",
                range: ("The ship's hold was full." as NSString).range(of: "hold"),
                partOfSpeech: "verb"))
            let entry = try #require(try ledger.recentLookups(since: .distantPast, limit: 50).first)
            #expect(entry.partOfSpeech == "verb", "the stored answer was thrown away for a guess")
        }
    }

    // MARK: - Which sense was met

    @Test func theSenseTheReaderMetReachesTheCard() throws {
        try withLedger { ledger in
            let id = try ledger.record(record("temper", at: noon))
            try ledger.record(
                encounter(gloss: "a neutralizing force", ordinal: 4, outOf: 12, chosenBy: .reader),
                for: id)

            let entry = try #require(try ledger.recentLookups(since: .distantPast, limit: 50).first)
            let sense = try #require(entry.sense)
            #expect(sense.dictionary == "NOAD")
            #expect(sense.ordinal == 4)
            #expect(sense.outOf == 12)
            #expect(sense.gloss == "a neutralizing force")
            #expect(sense.isConfirmed)
        }
    }

    /// The gloss travels with the card so the reader can ask for it. It is the *view* that keeps it
    /// hidden until they do — carrying it is not showing it.
    @Test func aModelsGuessArrivesMarkedAsAGuess() throws {
        try withLedger { ledger in
            let id = try ledger.record(record("temper", at: noon))
            try ledger.record(
                encounter(gloss: "a guess", ordinal: 2, outOf: 12, chosenBy: .model), for: id)

            let sense = try #require(
                try ledger.recentLookups(since: .distantPast, limit: 50).first?.sense)
            #expect(sense.isConfirmed == false)
            #expect(sense.canReveal)
        }
    }

    /// A lookup that never resolved a sense — the ordinary case for an entry-level encounter, and
    /// for every row written before schema 4.
    @Test func aLookupWithNoSenseHasNoSenseNote() throws {
        try withLedger { ledger in
            _ = try ledger.record(record("temper", at: noon))
            let entry = try #require(try ledger.recentLookups(since: .distantPast, limit: 50).first)
            #expect(entry.sense == nil)
        }
    }

    /// Only the primary dictionary is recorded, so there should be at most one encounter per
    /// lookup. "Should be" is not a thing to build a join on: two must still yield one card.
    @Test func aLookupWithTwoEncountersIsStillOneCard() throws {
        try withLedger { ledger in
            let id = try ledger.record(record("temper", at: noon))
            try ledger.record(encounter(gloss: "first", ordinal: 1, outOf: 12, chosenBy: .model), for: id)
            try ledger.record(encounter(gloss: "second", ordinal: 2, outOf: 12, chosenBy: .reader), for: id)

            let found = try ledger.recentLookups(since: .distantPast, limit: 50)
            #expect(found.count == 1, "the join multiplied the card")
            // The later one: a reader's tap arrives after the model's guess and replaces it.
            #expect(found.first?.sense?.gloss == "second")
        }
    }
}
