import DictionaryModel
import Foundation
import XiaolaiDictCore
import SQLite3
import Testing

/// Schema 4: the fields `study-unit.md` §5.1 and `where-a-word-was-read.md` §3 say are captured
/// today and thrown away at the ledger boundary, plus the sense-encounter table of §5.2.
///
/// The rule the whole migration rests on: **a column added later is NULL for old rows, meaning
/// unknown, never guessed.** Every day of lookups recorded without these is a day that cannot be
/// reconstructed, which is why they land in one migration rather than several.
struct LedgerSchema4Tests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("xiaolaidict-schema4-\(UUID().uuidString).sqlite").path
    }

    private func removeDatabase(at path: String) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func record(
        surface: String = "fine", lemma: String = "fine", context: String = "He paid the fine.",
        lemmaBasis: Lemma.Basis? = .tagger, language: String? = "en",
        contextRange: NSRange? = NSRange(location: 12, length: 4),
        place: ReadingPlace = ReadingPlace(
            bundleID: "com.apple.Safari", name: "Safari", document: nil,
            page: "https://example.com/a", title: "A page", rawTitle: "A page - Safari")
    ) -> LookupRecord {
        LookupRecord(
            surface: surface, lemma: lemma, context: context, lemmaBasis: lemmaBasis, language: language,
            contextRange: contextRange, place: place, lookedUpAt: now, result: .found,
            answeredBy: .dictionaryService,
            quality: .accessibility(.accessibilityTextMarkers, context: .complete))
    }

    /// The part of speech has to survive `history()`, not only `recentLookups()`.
    ///
    /// It did not: the read was added and the column was never put in the projection, so
    /// `row.optionalText(20)` indexed past the end of the row. SQLite answers an out-of-range read
    /// with NULL, which cannot be told from a column that is genuinely empty — so every record
    /// came back with a nil part of speech and every test still passed. `Row.inRange` now traps on
    /// the index; this is what would have caught the projection.
    @Test func aRecordedPartOfSpeechSurvivesHistoryToo() throws {
        let ledger = try Ledger(path: ":memory:")
        _ = try ledger.record(LookupRecord(
            surface: "hold", lemma: "hold", context: "Hold the line.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, partOfSpeech: "verb", place: ReadingPlace(),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))

        let record = try #require(try ledger.history(of: "hold").first)
        #expect(record.partOfSpeech == "verb")
    }

    /// Two senses whose key strings match under **different kinds** are two senses.
    ///
    /// `StudyItem` is keyed by kind as well as key, and `newlyMetSenses` has to agree. A first fix
    /// here used `SELECT DISTINCT`, which dedupes the projected row rather than the identity — and
    /// since the kind is not projected, it silently collapsed exactly this pair into one.
    @Test func twoSensesSharingAKeyUnderDifferentKindsAreBothNew() throws {
        let ledger = try Ledger(path: ":memory:")
        _ = try ledger.record(record(lemma: "hold", context: "An earlier lookup."))
        let latest = try ledger.record(record(lemma: "hold", context: "The newest lookup."))
        for kind in [SenseKeyKind.publisher, .position] {
            try ledger.record(SenseEncounter(
                dictionary: noad, entryID: "e", senseKey: "shared", senseKeyKind: kind,
                sensePath: nil, entrySenseCount: 2, senseHash: nil, gloss: "g",
                chosenBy: .reader, chosenAt: now), for: latest)
        }
        #expect(try ledger.newlyMetSenses(limit: 10).count == 2)
    }

    /// One sense met twice in one lookup — the selector's guess, then the reader's tap, which the
    /// ledger keeps apart on purpose — is still one newly met sense. Different glosses and a nil
    /// gloss must not make it two, which is what deduping the row rather than the identity did.
    @Test func oneSenseMetTwiceInALookupIsStillOneNewSense() throws {
        let ledger = try Ledger(path: ":memory:")
        _ = try ledger.record(record(lemma: "hold", context: "An earlier lookup."))
        let latest = try ledger.record(record(lemma: "hold", context: "The newest lookup."))
        for (gloss, by) in [(nil, SenseChoice.model), ("the reader's own", .reader)] {
            try ledger.record(SenseEncounter(
                dictionary: noad, entryID: "e", senseKey: "k", senseKeyKind: .publisher,
                sensePath: nil, entrySenseCount: 2, senseHash: nil, gloss: gloss,
                chosenBy: by, chosenAt: now), for: latest)
        }
        let met = try ledger.newlyMetSenses(limit: 10)
        #expect(met.count == 1)
        // The newest encounter wins, so the reader's tap is what the strip reports.
        #expect(met.first?.gloss == "the reader's own")
    }

    /// **The pin, which is the point of it.** Bumping `schemaVersion` without writing a migration
    /// leaves `PRAGMA user_version` claiming a shape the database does not have, and every later
    /// read is a column that is not there. This fails on the bump and is meant to: the number moves
    /// only in the same change as the `ALTER TABLE` that earns it.
    @Test func theSchemaIsSeven() {
        #expect(Ledger.schemaVersion == 7)
    }

    /// Schema 6: why the selector declined is kept, and "the model declined this sentence" reads
    /// back as a different fact from "no model here" — in the lookup's history and in the drawer.
    @Test(arguments: [Abstention.refused, .unavailable, .tooClose])
    func whyNoSenseWasMarkedIsKept(why: Abstention) throws {
        let ledger = try Ledger(path: ":memory:")
        let id = try ledger.record(LookupRecord(
            surface: "charge", lemma: "charge", context: "The police will charge him with fraud.",
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil,
            senseAbstention: why))
        #expect(try ledger.history(of: "charge").first?.senseAbstention == why)
        let drawn = try #require(try ledger.recentLookups(
            since: now.addingTimeInterval(-60), limit: 5, studying: Set(ProbeScript.allCases)).first)
        #expect(drawn.id == id)
        #expect(drawn.senseAbstention == why)
    }

    /// A lookup that marked a sense records no reason, and an old row reads back as unrecorded.
    @Test func aMarkedLookupRecordsNoReason() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.record(LookupRecord(
            surface: "hold", lemma: "hold", context: "Hold the line.", lookedUpAt: now, result: .found,
            answeredBy: .dictionaryService, quality: nil))
        #expect(try ledger.history(of: "hold").first?.senseAbstention == nil)
    }

    /// Everything captured now survives the boundary, and reads back as it went in.
    @Test func everyNewFieldRoundTrips() throws {
        let ledger = try Ledger(path: ":memory:")
        let original = record()
        try ledger.record(original)
        #expect(try ledger.history(of: "fine") == [original])
    }

    /// `lemma_basis` is the point of I2: the study list groups by a key that is sometimes a guess,
    /// and nothing recorded which.
    @Test(arguments: [Lemma.Basis.tagger, .inferred, .ambiguous, .surface])
    func everyLemmaBasisSurvives(basis: Lemma.Basis) throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.record(record(lemmaBasis: basis))
        #expect(try ledger.history(of: "fine").first?.lemmaBasis == basis)
    }

    /// A lemma alone collides across languages: *die*, *chat*, *pain*, *gift*.
    @Test func theLanguageIsKept() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.record(record(lemma: "chat", language: "fr"))
        #expect(try ledger.history(of: "chat").first?.language == "fr")
    }

    /// Unrecoverable later: "The surprise was no surprise" has two, and a card cannot mark the word
    /// in its sentence without knowing which.
    @Test func theWordsPlaceInItsSentenceIsKept() throws {
        let ledger = try Ledger(path: ":memory:")
        try ledger.record(record(
            surface: "surprise", lemma: "surprise", context: "The surprise was no surprise.",
            contextRange: NSRange(location: 21, length: 8)))
        #expect(try ledger.history(of: "surprise").first?.contextRange == NSRange(location: 21, length: 8))
    }

    // MARK: - Where it was read

    /// A page and a file are never the same column. Today's single `source_url` stored a local HTML
    /// page in Safari and a file open in an editor identically (`where-a-word-was-read.md` §2).
    @Test func aPageAndADocumentAreSeparate() throws {
        let ledger = try Ledger(path: ":memory:")
        let page = ReadingPlace(
            bundleID: "com.apple.Safari", name: "Safari", document: nil,
            page: "file:///tmp/page.html", title: "Page", rawTitle: "Page")
        let file = ReadingPlace(
            bundleID: "com.apple.Preview", name: "Preview", document: "file:///tmp/paper.pdf",
            page: nil, title: "paper", rawTitle: "paper.pdf")
        try ledger.record(record(surface: "one", lemma: "one", place: page))
        try ledger.record(record(surface: "two", lemma: "two", place: file))
        #expect(try ledger.history(of: "one").first?.place == page)
        #expect(try ledger.history(of: "two").first?.place == file)
        #expect(page.precision == .page)
        #expect(file.precision == .document)
    }

    /// Twelve of seventeen apps measured could say nothing beyond their own name, so that is the
    /// ordinary case — and review must say "in Safari" rather than imply a place it does not have.
    @Test func anAppThatCanSayNothingIsRecordedAsSayingNothing() throws {
        let ledger = try Ledger(path: ":memory:")
        let bare = ReadingPlace(
            bundleID: "com.tencent.xinWeChat", name: "WeChat", document: nil, page: nil,
            title: nil, rawTitle: "WeChat")
        try ledger.record(record(place: bare))
        let read = try #require(try ledger.history(of: "fine").first)
        #expect(read.place == bare)
        #expect(read.place.precision == .appOnly)
    }

    /// Stripping the app-name suffix is a heuristic — Chrome appends " - Google Chrome" — so the
    /// raw title is kept beside the stripped one rather than replaced by it.
    @Test func theRawTitleIsKeptBesideTheStrippedOne() throws {
        let ledger = try Ledger(path: ":memory:")
        let place = ReadingPlace(
            bundleID: "com.google.Chrome", name: "Google Chrome", document: nil,
            page: "https://example.com/", title: "Example", rawTitle: "Example - Google Chrome")
        try ledger.record(record(place: place))
        let read = try #require(try ledger.history(of: "fine").first?.place)
        #expect(read.title == "Example")
        #expect(read.rawTitle == "Example - Google Chrome")
    }

    // MARK: - Sense encounters

    private let noad = DictionaryIdentity(
        name: "New Oxford American Dictionary", identifier: "com.apple.dictionary.NOAD", version: "2.6")

    @Test func aSenseEncounterRoundTrips() throws {
        let ledger = try Ledger(path: ":memory:")
        let lookup = try ledger.record(record())
        let encounter = SenseEncounter(
            dictionary: noad, entryID: "m_en_gbus0362760", senseKey: "m_en_gbus0362760.005",
            senseKeyKind: .publisher, sensePath: SensePath(block: 1, ordinal: 1), entrySenseCount: 2,
            senseHash: "a1b2c3d4e5f60718", gloss: "罚款", chosenBy: .onlySense, chosenAt: now)
        try ledger.record(encounter, for: lookup)
        #expect(try ledger.encounters(ofLookup: lookup) == [encounter])
    }

    /// The gap `dictionary-markup.md` §7 named and the code did not close: a sideloaded
    /// conversion's entry ids are generated by whatever tool built the bundle and change on the
    /// next import, so a ledger keyed to them loses the reader's study list the moment they
    /// re-import the dictionary. Three of the seven dictionaries enabled on this Mac are
    /// sideloaded.
    ///
    /// This asserts the key, not the fix: rekeying by anything the bundle regenerates fails here.
    @Test func aStudyItemSurvivesReimportingASideloadedDictionary() throws {
        let ledger = try Ledger(path: ":memory:")
        // No bundle identifier — measured empty for every sideloaded conversion enabled here.
        let longman = DictionaryIdentity(name: "Longman Dictionary of Contemporary English")
        func entry(id: String) -> DictionaryEntry {
            DictionaryEntry(
                dictionary: longman, headword: "hold", lookedUp: "hold", html: "<p/>",
                document: EntryDocument(isStyled: true, entryID: id, homograph: nil))
        }

        let lookup = try ledger.record(record(surface: "hold", lemma: "hold", context: "Take hold."))
        // An entry-level encounter, which is all a dictionary whose sense boundary is a colour
        // change can honestly record.
        try ledger.record(SenseEncounter(
            dictionary: longman, entryID: try #require(entry(id: "_myk").entryKey),
            senseKey: nil, senseKeyKind: SenseKeyKind.none, sensePath: nil, entrySenseCount: 0,
            senseHash: nil, gloss: nil, chosenBy: nil, chosenAt: nil), for: lookup)

        // The reader imports Longman again. Every entry id in the bundle is different.
        let reimported = try #require(entry(id: "_2878").entryKey)
        let met = try ledger.priorEncounters(of: "hold", before: now.addingTimeInterval(10)).met
        #expect(met.contains(StudyItem(
            dictionary: longman.key, entryID: reimported,
            senseKey: nil, senseKeyKind: SenseKeyKind.none)))
    }

    /// A sense the model picked is a hypothesis; one the reader tapped is a fact. They must never
    /// merge (`study-unit.md` §5.2).
    @Test(arguments: [SenseChoice.reader, .model, .onlySense])
    func howASenseWasChosenIsKept(choice: SenseChoice) throws {
        let ledger = try Ledger(path: ":memory:")
        let lookup = try ledger.record(record())
        try ledger.record(SenseEncounter(
            dictionary: noad, entryID: "e", senseKey: "e.1", senseKeyKind: .publisher,
            sensePath: SensePath(block: 1, ordinal: 1), entrySenseCount: 1, senseHash: "h",
            gloss: nil, chosenBy: choice, chosenAt: now), for: lookup)
        #expect(try ledger.encounters(ofLookup: lookup).first?.chosenBy == choice)
    }

    /// An entry whose sense is not resolved is still an encounter: null means "this entry, sense
    /// unresolved", and the kind says why.
    @Test func anEntryLevelEncounterHasNoSenseKey() throws {
        let ledger = try Ledger(path: ":memory:")
        let lookup = try ledger.record(record())
        let collins = DictionaryIdentity(name: "Collins COBUILD")
        let encounter = SenseEncounter(
            dictionary: collins, entryID: "_8pm", senseKey: nil, senseKeyKind: SenseKeyKind.none,
            sensePath: nil, entrySenseCount: 0, senseHash: nil, gloss: nil, chosenBy: nil, chosenAt: nil)
        try ledger.record(encounter, for: lookup)
        let read = try #require(try ledger.encounters(ofLookup: lookup).first)
        #expect(read == encounter)
        #expect(read.senseKey == nil)
        #expect(read.dictionary.key == "name:Collins COBUILD", "a dictionary with no identifier keyed by one")
    }

    /// The query §4 job 2 exists for: a lemma met before, whose newest lookup landed on an entry or
    /// sense never seen before. It is the highest-value study item there is, and a word-level unit
    /// cannot express it because the word is already marked known.
    @Test func aKnownWordWithAnUnknownSenseIsFound() throws {
        let ledger = try Ledger(path: ":memory:")
        func met(_ senseKey: String, at offset: TimeInterval) throws {
            let lookup = try ledger.record(LookupRecord(
                surface: "fine", lemma: "fine", context: "c", lemmaBasis: .tagger, language: "en",
                contextRange: nil, place: ReadingPlace(bundleID: "a", name: "A"),
                lookedUpAt: now.addingTimeInterval(offset), result: .found,
                answeredBy: .dictionaryService, quality: nil))
            try ledger.record(SenseEncounter(
                dictionary: noad, entryID: "m_en_gbus0362750", senseKey: senseKey, senseKeyKind: .publisher,
                sensePath: SensePath(block: 1, ordinal: 1), entrySenseCount: 4, senseHash: "h\(senseKey)",
                gloss: nil, chosenBy: .reader, chosenAt: now), for: lookup)
        }
        try met("m_en_gbus0362750.005", at: 0)
        try met("m_en_gbus0362750.005", at: 100)  // the same sense again: nothing new
        #expect(try ledger.newlyMetSenses(limit: 10).isEmpty)

        try met("m_en_gbus0362750.020", at: 200)  // a sense of a word already known
        let fresh = try ledger.newlyMetSenses(limit: 10)
        #expect(fresh.map(\.senseKey) == ["m_en_gbus0362750.020"])
        #expect(fresh.map(\.lemma) == ["fine"])
    }

    // MARK: - Migration

    /// A schema-3 ledger is carried forward. Its rows kept none of the new fields, so they stay
    /// NULL — unknown, never guessed. In particular `source_url` conflated a page with a file, and
    /// the migration does not pretend to know which one any old row held.
    @Test func aSchema3LedgerMigratesForward() throws {
        let path = temporaryPath()
        defer { removeDatabase(at: path) }
        try SQLiteFile(path: path).execute("""
            CREATE TABLE lookups (
                id INTEGER PRIMARY KEY, surface TEXT NOT NULL, lemma TEXT NOT NULL, context TEXT NOT NULL,
                source_app TEXT, source_url TEXT, looked_up_at REAL NOT NULL,
                result TEXT NOT NULL DEFAULT 'found', capture_source TEXT, capture_confidence REAL,
                context_quality TEXT, answered_by TEXT);
            CREATE INDEX lookups_by_lemma ON lookups (lemma, looked_up_at);
            INSERT INTO lookups (surface, lemma, context, source_app, source_url, looked_up_at,
                                 result, answered_by, capture_source, capture_confidence, context_quality)
            VALUES ('fine', 'fine', 'He paid the fine.', 'com.apple.Safari', 'https://example.com/a',
                    1800000000.0, 'found', 'dictionaryService', 'accessibilityTextRange', 1.0, 'complete');
            PRAGMA user_version = 3;
            """)

        let ledger = try Ledger(path: path)
        let migrated = try #require(try ledger.history(of: "fine").first)
        #expect(migrated.lemmaBasis == nil, "a lemma basis was guessed for a row that had none")
        #expect(migrated.language == nil)
        #expect(migrated.contextRange == nil)
        #expect(migrated.place.bundleID == "com.apple.Safari", "the one source field that existed was lost")
        #expect(migrated.place.name == nil)
        #expect(migrated.place.page == nil, "an old source_url was guessed to be a page")
        #expect(migrated.place.document == nil, "an old source_url was guessed to be a document")
        #expect(migrated.legacySourceURL == "https://example.com/a", "the old value was dropped rather than kept as it was")
        // What it did keep, it kept.
        #expect(migrated.answeredBy == .dictionaryService)
        #expect(migrated.quality == .accessibility(.accessibilityTextRange, context: .complete))
    }

    /// The sense table arrives with the migration, and is usable at once.
    @Test func aMigratedLedgerCanRecordSenses() throws {
        let path = temporaryPath()
        defer { removeDatabase(at: path) }
        try SQLiteFile(path: path).execute("""
            CREATE TABLE lookups (
                id INTEGER PRIMARY KEY, surface TEXT NOT NULL, lemma TEXT NOT NULL, context TEXT NOT NULL,
                source_app TEXT, source_url TEXT, looked_up_at REAL NOT NULL,
                result TEXT NOT NULL DEFAULT 'found', capture_source TEXT, capture_confidence REAL,
                context_quality TEXT, answered_by TEXT);
            PRAGMA user_version = 3;
            """)
        let ledger = try Ledger(path: path)
        let lookup = try ledger.record(record())
        try ledger.record(SenseEncounter(
            dictionary: noad, entryID: "e", senseKey: "e.1", senseKeyKind: .publisher,
            sensePath: SensePath(block: 1, ordinal: 1), entrySenseCount: 1, senseHash: "h",
            gloss: nil, chosenBy: .onlySense, chosenAt: now), for: lookup)
        #expect(try ledger.encounters(ofLookup: lookup).count == 1)
    }

    /// A file written by a newer XiaolaiDict is refused, not half-read. Pinned one past the current
    /// schema rather than to a literal, so this keeps testing the refusal and not the number.
    @Test func aLedgerFromALaterXiaolaiDictIsRefused() throws {
        let path = temporaryPath()
        defer { removeDatabase(at: path) }
        let later = Ledger.schemaVersion + 1
        try SQLiteFile(path: path).execute("PRAGMA user_version = \(later)")
        #expect(throws: LedgerError.newerSchema(found: later, supported: Ledger.schemaVersion)) {
            _ = try Ledger(path: path)
        }
    }

    /// A sense encounter must point at a lookup that exists, or the ledger would hold senses
    /// belonging to nothing.
    @Test func anEncounterForNoSuchLookupIsRefused() throws {
        let ledger = try Ledger(path: ":memory:")
        #expect(throws: (any Error).self) {
            try ledger.record(SenseEncounter(
                dictionary: self.noad, entryID: "e", senseKey: nil, senseKeyKind: SenseKeyKind.none,
                sensePath: nil, entrySenseCount: 0, senseHash: nil, gloss: nil, chosenBy: nil,
                chosenAt: nil), for: 9_999)
        }
    }
}

/// Found by audit. Both are query defects: the data was right and the question was wrong, which is
/// the kind of bug that never crashes and quietly ranks the wrong word first.
struct LedgerQueryAuditTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let noad = DictionaryIdentity(
        name: "New Oxford American Dictionary", identifier: "com.apple.dictionary.NOAD", version: "2.6")

    private func record(
        _ ledger: Ledger, _ lemma: String, language: String?, at offset: TimeInterval
    ) throws -> Int {
        try ledger.record(LookupRecord(
            surface: lemma, lemma: lemma, context: "c", lemmaBasis: .tagger, language: language,
            contextRange: nil, place: ReadingPlace(bundleID: "a", name: "A"),
            lookedUpAt: now.addingTimeInterval(offset), result: .found,
            answeredBy: .dictionaryService, quality: nil))
    }

    private func met(_ ledger: Ledger, _ lookup: Int, sense: String) throws {
        try ledger.record(SenseEncounter(
            dictionary: noad, entryID: "m1", senseKey: sense, senseKeyKind: .publisher,
            sensePath: SensePath(block: 1, ordinal: 1), entrySenseCount: 4, senseHash: "h\(sense)",
            gloss: nil, chosenBy: .reader, chosenAt: now), for: lookup)
    }

    /// English *gift* and German *Gift* are different words that happen to be spelled alike — the
    /// exact collision `language` was added to prevent. Grouping by lemma alone made them one row
    /// of count 2, and put a word the reader knows at the top of the study list.
    @Test func thestudyListDoesNotMergeLanguages() throws {
        let ledger = try Ledger(path: ":memory:")
        _ = try record(ledger, "gift", language: "en", at: 0)
        _ = try record(ledger, "gift", language: "de", at: 1)
        let list = try ledger.studyList(limit: 10)
        #expect(list.count == 2, "two languages merged into one study item: \(list)")
        #expect(Set(list.map(\.language)) == ["en", "de"])
        #expect(list.allSatisfy { $0.count == 1 })
    }

    /// Rows written before schema 4 have no language. Unknown is its own group, never folded into
    /// a known one.
    @Test func anUnknownLanguageIsItsOwnGroup() throws {
        let ledger = try Ledger(path: ":memory:")
        _ = try record(ledger, "gift", language: "en", at: 0)
        _ = try record(ledger, "gift", language: nil, at: 1)
        #expect(try ledger.studyList(limit: 10).count == 2)
    }

    /// History and prior encounters take the same filter, so a memory strip cannot count another
    /// language's homograph as an earlier meeting with this word.
    @Test func historyAndPriorEncountersCanBeFilteredByLanguage() throws {
        let ledger = try Ledger(path: ":memory:")
        _ = try record(ledger, "gift", language: "en", at: 0)
        _ = try record(ledger, "gift", language: "de", at: 1)
        #expect(try ledger.history(of: "gift").count == 2, "unfiltered history should still see both")
        #expect(try ledger.history(of: "gift", language: "en").count == 1)
        let prior = try ledger.priorEncounters(
            of: "gift", before: now.addingTimeInterval(10), language: "de")
        #expect(prior.occasions.count == 1)
        #expect(prior.occasion == 2)
    }

    /// A sense met three lookups ago is not newly met now. Only the lemma's **newest** lookup
    /// counts; before the fix, an older encounter kept resurfacing because some earlier lookup had
    /// not seen it.
    @Test func aSenseMetEarlierIsNotReportedAsNew() throws {
        let ledger = try Ledger(path: ":memory:")
        try met(ledger, try record(ledger, "fine", language: "en", at: 0), sense: "m1.A")
        try met(ledger, try record(ledger, "fine", language: "en", at: 100), sense: "m1.B")
        // The newest lookup lands on B again — nothing new was met.
        try met(ledger, try record(ledger, "fine", language: "en", at: 200), sense: "m1.B")
        #expect(try ledger.newlyMetSenses(limit: 10).isEmpty, "an older encounter resurfaced as new")
    }

    /// And it still finds the real thing: the newest lookup landing on a sense never seen before.
    @Test func aGenuinelyNewSenseIsStillFound() throws {
        let ledger = try Ledger(path: ":memory:")
        try met(ledger, try record(ledger, "fine", language: "en", at: 0), sense: "m1.A")
        try met(ledger, try record(ledger, "fine", language: "en", at: 100), sense: "m1.B")
        let fresh = try ledger.newlyMetSenses(limit: 10)
        #expect(fresh.map(\.senseKey) == ["m1.B"])
    }
}
