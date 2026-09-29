import Foundation
import Testing
import XiaolaiDictTestSupport
@testable import AppleDictionaryFormat
@testable import DictionaryIndex

/// **The four scripts that failed against the first schema draft, each of which must now pass.**
///
/// Every fixture is invented. An entry cut from a shipped dictionary would put licensed text in the
/// repository and would test that dictionary's content rather than the schema's constraints.
@Suite struct IndexStoreTests {
    static func store() throws -> IndexStore { try IndexStore(path: ":memory:") }

    static func entry(id: String = "give", headword: String = "give",
                      senses: [(key: String, definition: String, subEntry: String?)]) -> IndexedEntry {
        IndexedEntry(
            entryID: id, headword: headword, homograph: nil,
            senses: senses.map { s in
                let key = SenseKey(dictionary: "d", entry: id, value: s.key, origin: .content)
                return IndexedSense(key: key, contentKey: key,
                                    position: SensePosition(subEntry: s.subEntry),
                                    definition: s.definition)
            })
    }

    static func register(_ store: IndexStore, _ identifier: String = "d",
                        version: String = "1.0", confidence: String = "verified") throws {
        try store.beginRebuild(identifier: identifier, displayName: identifier,
                               contentVersion: version, keyConfidence: confidence)
    }

    /// **The pragma under everything else.** `PRAGMA foreign_keys` is off by default and per connection, and
    /// SQLite does not complain when it is never set — so every constraint below would be decoration and
    /// every test here would pass while enforcing nothing.
    @Test func foreignKeysAreActuallyEnforced() throws {
        let store = try Self.store()
        try Self.register(store)
        // An entry for a dictionary that exists is fine.
        try store.insert(Self.entry(senses: [("k1", "to hand over", nil)]), dictionary: "d")
        // One for a dictionary that does not is rejected, which is the pragma working.
        #expect(throws: IndexStore.Failure.self) {
            try store.insert(Self.entry(senses: [("k1", "x", nil)]), dictionary: "absent")
        }
    }

    /// **Script 1: an orphan alias must be rejected.**
    ///
    /// `search_key` had no foreign key. Deleting a dictionary left its aliases behind, and recreating the
    /// entry made those aliases resolve to an unrelated word.
    @Test func anAliasForAnEntryThatDoesNotExistIsRejected() throws {
        let store = try Self.store()
        try Self.register(store)
        // `insert(_:dictionary:aliases:)` writes the entry row first, so the orphan has to be reached
        // through the primitive: an alias against an entry id nothing ever created.
        try store.insert(Self.entry(senses: [("k1", "to hand over", nil)]), dictionary: "d")
        #expect(throws: IndexStore.Failure.self) {
            try store.insertAlias(dictionary: "d", entryID: "never-written",
                                  alias: SearchAlias(search: "ghost", display: "ghost"))
        }
    }

    /// The other half of the same defect: deleting a dictionary must take its aliases with it, so a
    /// recreated entry cannot inherit them.
    @Test func deletingADictionaryTakesItsAliasesAndSenses() throws {
        let store = try Self.store()
        try Self.register(store)
        try store.insert(Self.entry(senses: [("k1", "to hand over", nil)]), dictionary: "d",
                         aliases: [SearchAlias(search: "give", display: "give")])
        #expect(try store.candidates(for: "give").count == 1)
        #expect(try store.aliasCount(in: "d") == 1)

        try store.forget("d")
        #expect(try store.aliasCount(in: "d") == 0, "the alias outlived its dictionary")
        #expect(try store.senseCount(in: "d") == 0)
        #expect(try store.candidates(for: "give").isEmpty)

        // Recreating the entry must not resurrect the old alias — the wrong-word failure.
        try Self.register(store)
        try store.insert(Self.entry(id: "give", headword: "gyve",
                                    senses: [("k9", "a shackle", nil)]), dictionary: "d")
        #expect(try store.candidates(for: "give").isEmpty,
                "a stale alias resolved to an unrelated word")
    }

    /// **Script 2: a dangling `parent_key` must be rejected**, and a NULL one must still pass.
    @Test func aParentKeyPointingAtNothingIsRejected() throws {
        let store = try Self.store()
        try Self.register(store)
        try store.insert(Self.entry(senses: [("k1", "to hand over", nil)]), dictionary: "d")
        #expect(throws: IndexStore.Failure.self) {
            try store.insertSense(dictionary: "d", entryID: "give", key: "k2",
                                  definition: "a subsense", parentKey: "no-such-sense",
                                  parentOrigin: "content")
        }
        // A real parent is accepted.
        try store.insertSense(dictionary: "d", entryID: "give", key: "k3",
                              definition: "a subsense", parentKey: "k1", parentOrigin: "content")
        // And a sense that is nobody's child still passes: a composite reference with a NULL column is
        // satisfied, which is exactly the rule wanted here.
        try store.insertSense(dictionary: "d", entryID: "give", key: "k4",
                              definition: "a main sense", parentKey: nil)
        #expect(try store.senseCount(in: "d") == 3)

        // **A parent named without its origin is refused too.** A composite foreign key is satisfied when
        // any column is NULL, so this pairing would otherwise bypass the reference completely.
        #expect(throws: IndexStore.Failure.self) {
            try store.insertSense(dictionary: "d", entryID: "give", key: "k5",
                                  definition: "half a parent", parentKey: "k1", parentOrigin: nil)
        }
    }

    /// **A publisher id that reads like a content digest is a different sense.**
    ///
    /// `origin` was not part of the sense key, so the two were one row and `INSERT OR REPLACE` kept whichever
    /// arrived second — losing a sense that `SenseKey` itself distinguishes.
    @Test func aPublisherKeyAndAContentKeyWithTheSameValueAreTwoSenses() throws {
        let store = try Self.store()
        try Self.register(store)
        let digest = SenseKey.digest(of: "to hand over")
        let content = SenseKey(dictionary: "d", entry: "give", value: digest, origin: .content)
        let publisher = SenseKey.publisher(dictionary: "d", entry: "give", id: digest)
        let entry = IndexedEntry(
            entryID: "give", headword: "give", homograph: nil,
            senses: [IndexedSense(key: content, contentKey: content, position: .unplaced,
                                  definition: "to hand over"),
                     IndexedSense(key: publisher, contentKey: content, position: .unplaced,
                                  definition: "to provide")])
        try store.insert(entry, dictionary: "d", aliases: [SearchAlias(search: "give", display: "give")])
        #expect(try store.senseCount(in: "d") == 2, "one sense replaced the other")
        let found = try store.candidates(for: "give").map(\.definition).sorted()
        #expect(found == ["to hand over", "to provide"])
    }

    /// A parent in a different entry is meaningless, and the composite reference is what refuses it.
    @Test func aParentKeyInAnotherEntryIsRejected() throws {
        let store = try Self.store()
        try Self.register(store)
        try store.insert(Self.entry(id: "give", senses: [("k1", "to hand over", nil)]), dictionary: "d")
        try store.insert(Self.entry(id: "take", headword: "take",
                                    senses: [("k2", "to receive", nil)]), dictionary: "d")
        #expect(throws: IndexStore.Failure.self) {
            try store.insertSense(dictionary: "d", entryID: "take", key: "k3",
                                  definition: "borrowed parent", parentKey: "k1",
                                  parentOrigin: "content")
        }
    }

    /// **Script 3: `give up` and `give in` must return different candidate sets.**
    ///
    /// Without an alias → sub-entry association both returned `give`'s entire 76-definition set, so
    /// recovering a phrasal verb's senses would not have made them reachable — which defeats the point of
    /// recovering them.
    @Test func twoPhrasalVerbsOfOneEntryReturnDifferentCandidates() throws {
        let store = try Self.store()
        try Self.register(store)
        let give = Self.entry(senses: [
            ("k1", "to hand over", nil),
            ("k2", "to provide", nil),
            ("k3", "to stop trying", "give up"),
            ("k4", "to yield to pressure", "give in"),
        ])
        try store.insert(give, dictionary: "d", aliases: [
            SearchAlias(search: "give", display: "give"),
            SearchAlias(search: "give up", display: "give up",
                        subEntry: IndexStore.scope(alias: "give up", within: give)),
            SearchAlias(search: "give in", display: "give in",
                        subEntry: IndexStore.scope(alias: "give in", within: give)),
        ])

        let up = try store.candidates(for: "give up")
        let into = try store.candidates(for: "give in")
        #expect(up.map(\.definition) == ["to stop trying"])
        #expect(into.map(\.definition) == ["to yield to pressure"])
        #expect(up != into, "both phrasal verbs returned the same candidate set")
        // The entry's own form still reaches everything, which is correct: the alias names the entry.
        #expect(try store.candidates(for: "give").count == 4)
    }

    /// The scoping join is a pure function and is tested as one: the alias's display form is matched against
    /// the entry's own sub-entry labels under the normalisation a content key uses.
    @Test func anAliasIsScopedToTheSubEntryItNames() throws {
        let give = Self.entry(senses: [
            ("k1", "to hand over", nil),
            ("k3", "to stop trying", "give up"),
        ])
        #expect(IndexStore.scope(alias: "give up", within: give) == "give up")
        #expect(IndexStore.scope(alias: "Give Up ", within: give) == "give up", "case and spacing differ")
        #expect(IndexStore.scope(alias: "give", within: give) == nil, "the entry's own form scopes nothing")
        #expect(IndexStore.scope(alias: "give away", within: give) == nil, "an unlisted phrase scopes nothing")
        #expect(IndexStore.scope(alias: "", within: give) == nil)
    }

    /// **A group's sub-entry is found from any of its forms, not just the last.**
    ///
    /// Installed NOAD carries `["give or take", "give or take —", "give"]`, so `keys.last` is the base word,
    /// and a `give me` group ends in an `xpointer(...)` fragment. Scoping on that one form matched the wrong
    /// phrase or nothing at all.
    @Test func scopingTriesEveryFormTheGroupCarries() throws {
        let give = Self.entry(senses: [
            ("k1", "to hand over", nil),
            ("k2", "roughly", "give or take"),
        ])
        // The phrase is in the middle; the last form is the base word and the first is the folded key.
        #expect(IndexStore.scope(aliasForms: ["give or take", "give or take —", "give"], within: give)
                == "give or take")
        // An xpointer fragment names no sub-entry and must not stop the search.
        #expect(IndexStore.scope(aliasForms: ["give me", "xpointer(//*[@id='x'])", "give or take"],
                                 within: give) == "give or take")
        // And a group naming nothing still scopes nothing.
        #expect(IndexStore.scope(aliasForms: ["give", "gave"], within: give) == nil)
    }

    /// **Script 4: a bumped extractor generation forces a rebuild; an unchanged one does not.**
    ///
    /// `content_ver` alone cannot express this, so improving the reader would leave every dictionary holding
    /// rows produced by code that no longer exists.
    @Test func aBumpedExtractorGenerationForcesARebuild() throws {
        let store = try Self.store()
        #expect(try store.needsRebuild("d", contentVersion: "2.6") == true, "never built")

        try store.beginRebuild(identifier: "d", displayName: "d", contentVersion: "2.6",
                               keyConfidence: "verified", extractorGeneration: 4)
        #expect(try store.needsRebuild("d", contentVersion: "2.6", extractorGeneration: 4) == false,
                "nothing changed, so nothing should be rebuilt")
        #expect(try store.needsRebuild("d", contentVersion: "2.6", extractorGeneration: 5) == true,
                "a bumped extractor generation must force a rebuild")
        #expect(try store.needsRebuild("d", contentVersion: "2.7", extractorGeneration: 4) == true,
                "new content must force a rebuild")
    }

    /// A rebuild replaces rather than accumulates: the second build of a dictionary must not leave the
    /// first one's senses behind.
    @Test func rebuildingReplacesRatherThanAccumulates() throws {
        let store = try Self.store()
        try Self.register(store)
        try store.insert(Self.entry(senses: [("k1", "to hand over", nil), ("k2", "to provide", nil)]),
                         dictionary: "d", aliases: [SearchAlias(search: "give", display: "give")])
        #expect(try store.senseCount(in: "d") == 2)

        try Self.register(store, version: "2.0")
        try store.insert(Self.entry(senses: [("k1", "to hand over", nil)]),
                         dictionary: "d", aliases: [SearchAlias(search: "give", display: "give")])
        #expect(try store.senseCount(in: "d") == 1, "the previous build's senses survived the rebuild")
        #expect(try store.dictionaries().map(\.contentVersion) == ["2.0"])
    }

    /// A rebuild that fails half-way must leave the previous index in place, not a partial one.
    @Test func aFailedRebuildRollsBack() throws {
        let store = try Self.store()
        try Self.register(store)
        try store.insert(Self.entry(senses: [("k1", "to hand over", nil)]), dictionary: "d")

        struct Stop: Error {}
        #expect(throws: Stop.self) {
            try store.inTransaction {
                try store.insert(Self.entry(id: "take", headword: "take",
                                            senses: [("k2", "to receive", nil)]), dictionary: "d")
                throw Stop()
            }
        }
        #expect(try store.senseCount(in: "d") == 1, "the half-finished rebuild was kept")
    }

    /// Subsenses are written under their parent, and the parent is written first because the constraint
    /// requires it — which is the constraint working rather than something to route around.
    @Test func subsensesAreStoredUnderTheirParent() throws {
        let store = try Self.store()
        try Self.register(store)
        let parentKey = SenseKey(dictionary: "d", entry: "at", value: "p", origin: .content)
        let entry = IndexedEntry(
            entryID: "at", headword: "@", homograph: nil,
            senses: [IndexedSense(
                key: parentKey, contentKey: parentKey,
                position: SensePosition(senseNumber: "1"),
                definition: "used in internet addresses; used preceding a name",
                subsenses: [
                    IndexedSubsense(key: SenseKey(dictionary: "d", entry: "at", value: "s1",
                                                  origin: .content),
                                    label: nil, definition: "used in internet addresses"),
                    IndexedSubsense(key: SenseKey(dictionary: "d", entry: "at", value: "s2",
                                                  origin: .content),
                                    label: "•", definition: "used preceding a name"),
                ])])
        try store.insert(entry, dictionary: "d",
                         aliases: [SearchAlias(search: "@", display: "@")])
        let found = try store.candidates(for: "@")
        #expect(found.count == 3, "the sense and both subsenses")
        #expect(found.filter { $0.parentKey == "p" }.map(\.senseKey).sorted() == ["s1", "s2"])
        #expect(found.first { $0.senseKey == "p" }?.parentKey == nil)
        #expect(found.first { $0.senseKey == "s2" }?.senseNumber == "•")
    }

    /// **A bound call carrying two statements is refused, not half-run.**
    ///
    /// `sqlite3_prepare_v2` compiles the first statement of its input and ignores the rest silently, so such
    /// a call would execute a prefix of what it was given and report success — a defect generator of exactly
    /// the shape this schema's other constraints exist to remove.
    @Test func aPreparedCallCarryingTwoStatementsIsRefused() throws {
        let store = try Self.store()
        #expect(throws: IndexStore.Failure.self) {
            try store.prepareTwoForTesting()
        }
        // **And a semicolon inside a comment is not a second statement.** A first version of this check
        // scanned the string for `;` and rejected four of the store's own queries, one of which has a
        // semicolon in a SQL comment — so the check now asks SQLite what it left unconsumed.
        try Self.register(store)
        try store.insert(Self.entry(senses: [("k1", "to hand over", nil)]), dictionary: "d",
                         aliases: [SearchAlias(search: "give", display: "give")])
        #expect(try store.candidates(for: "give").count == 1,
                "the candidates query has a semicolon in a comment and must still run")
    }

    /// The store survives being reopened: the schema applies with `IF NOT EXISTS`, so opening an existing
    /// index is the same code path as creating one.
    @Test func anExistingIndexReopensWithoutLoss() throws {
        // `TemporaryDirectory`, not `NSTemporaryDirectory()` — nothing owned the 16,363
        // UUID-named directories that idiom left behind, which is why the helper exists.
        let scratch = TemporaryDirectory(named: "adf-index")
        let path = scratch.appending("index.sqlite").path

        do {
            let store = try IndexStore(path: path)
            try Self.register(store)
            try store.insert(Self.entry(senses: [("k1", "to hand over", nil)]), dictionary: "d",
                             aliases: [SearchAlias(search: "give", display: "give")])
        }
        let reopened = try IndexStore(path: path)
        #expect(try reopened.candidates(for: "give").map(\.definition) == ["to hand over"])
        #expect(try reopened.needsRebuild("d", contentVersion: "1.0") == false)
    }

    /// **A sense is returned once, however many aliases reach it.**
    ///
    /// The join form returned it once per matching alias, and one entry can carry several aliases with the
    /// same folded `search` and different display forms — `give` and `Give`.
    @Test func aSenseIsNotReturnedTwiceForTwoAliases() throws {
        let store = try Self.store()
        try Self.register(store)
        try store.insert(Self.entry(senses: [("k1", "to hand over", nil)]), dictionary: "d", aliases: [
            SearchAlias(search: "give", display: "give"),
            SearchAlias(search: "give", display: "Give"),
        ])
        #expect(try store.aliasCount(in: "d") == 2, "both display forms are stored")
        #expect(try store.candidates(for: "give").count == 1, "the sense came back once per alias")
    }

    /// **Two sub-entry labels that differ only in spelling are one group.**
    ///
    /// `scope` normalised the alias before comparing, but the query then compared raw spellings — so an entry
    /// carrying both `give up` and `Give Up` had one group unreachable, and which one depended on sense order.
    @Test func subEntryScopingIsNotDefeatedBySpelling() throws {
        let store = try Self.store()
        try Self.register(store)
        let give = Self.entry(senses: [
            ("k1", "to hand over", nil),
            ("k2", "to stop trying", "give up"),
            ("k3", "to abandon", "Give Up"),
        ])
        try store.insert(give, dictionary: "d", aliases: [
            SearchAlias(search: "give up", display: "give up",
                        subEntry: IndexStore.scope(alias: "give up", within: give)),
        ])
        let found = try store.candidates(for: "give up").map(\.definition).sorted()
        #expect(found == ["to abandon", "to stop trying"],
                "one spelling of the label was unreachable: \(found)")
    }

    /// **A scope whose label is not already canonical must still match.**
    ///
    /// The earlier version of the test above used `give up` as the label — already canonical — so it passed
    /// while `insertAlias` stored the scope unnormalised and the query compared it against a normalised
    /// column. A label the publisher spells `Give Up` matched nothing at all. The fix had in fact been
    /// written once and then refactored out from under itself, which is exactly what an uncanonical fixture
    /// would have caught.
    @Test func aScopeWhoseLabelIsNotCanonicalStillMatches() throws {
        let store = try Self.store()
        try Self.register(store)
        let give = Self.entry(senses: [
            ("k1", "to hand over", nil),
            ("k2", "to stop trying", "Give Up"),
        ])
        let scope = IndexStore.scope(alias: "give up", within: give)
        #expect(scope == "Give Up", "scope returns the publisher's own spelling, for display")
        try store.insert(give, dictionary: "d", aliases: [
            SearchAlias(search: "give up", display: "give up", subEntry: scope),
        ])
        #expect(try store.candidates(for: "give up").map(\.definition) == ["to stop trying"],
                "an uncanonical label made the scoped alias reach nothing")
        // And the label a reader sees is still the publisher's.
        #expect(try store.candidates(for: "give up").first?.subEntry == "Give Up")
    }

    /// An embedded NUL must round-trip rather than truncate the value silently — `-1` as a bind length means
    /// "to the first NUL", so two distinct identifiers could collapse into one row.
    @Test func anEmbeddedNULRoundTrips() throws {
        let store = try Self.store()
        try Self.register(store)
        let odd = "abc\u{0000}def"
        try store.insert(Self.entry(senses: [("k1", odd, nil)]), dictionary: "d",
                         aliases: [SearchAlias(search: "x", display: "x")])
        #expect(try store.candidates(for: "x").first?.definition == odd)
    }

    /// **An index written under an older schema is discarded, not migrated.**
    ///
    /// `CREATE TABLE IF NOT EXISTS` leaves an existing table exactly as it was, so a file missing a column
    /// added later keeps the old shape and every insert against it fails. The index is derived from the
    /// dictionaries on this Mac and can always be rebuilt, so throwing it away is both safe and the only
    /// option that cannot half-work.
    @Test func anIndexFromAnOlderSchemaIsDiscarded() throws {
        // `TemporaryDirectory`, not `NSTemporaryDirectory()` — nothing owned the 16,363
        // UUID-named directories that idiom left behind, which is why the helper exists.
        let scratch = TemporaryDirectory(named: "adf-schema")
        let path = scratch.appending("index.sqlite").path

        do {
            let store = try IndexStore(path: path)
            try Self.register(store)
            try store.insert(Self.entry(senses: [("k1", "to hand over", nil)]), dictionary: "d",
                             aliases: [SearchAlias(search: "give", display: "give")])
            #expect(try store.candidates(for: "give").count == 1)
            // Pretend it was written by an earlier schema.
            try store.setSchemaVersionForTesting(IndexStore.schemaVersion - 1)
        }
        let reopened = try IndexStore(path: path)
        #expect(try reopened.dictionaries().isEmpty, "the stale index survived a schema change")
        // And it is usable again immediately.
        try Self.register(reopened)
        try reopened.insert(Self.entry(senses: [("k1", "to hand over", nil)]), dictionary: "d",
                            aliases: [SearchAlias(search: "give", display: "give")])
        #expect(try reopened.candidates(for: "give").count == 1)
    }

    /// **The lookup enters through the alias index, asserted from SQLite's own plan.**
    ///
    /// An `EXISTS` predicate de-duplicates correctly but starts from `sense`, so it cannot use
    /// `search_key_by_search`: measured at 45.75 ms for a missing word over 200,000 senses. Entering through
    /// the alias and collapsing duplicates with `GROUP BY` keeps both properties — and a plan check is the
    /// only way to know which of the two the query is actually getting.
    @Test func theLookupUsesTheAliasIndexRatherThanScanningEverySense() throws {
        let store = try Self.store()
        let plan = try store.candidateQueryPlan()
        #expect(!plan.isEmpty)
        let joined = plan.joined(separator: " | ")
        #expect(!joined.contains("SCAN sense"), "the lookup scans every sense: \(joined)")
        #expect(joined.contains("search_key_by_search"),
                "the lookup does not use the alias index: \(joined)")
    }

    // MARK: - Anchors and alignment

    static func anchored(_ id: String, _ headword: String, _ anchors: [String],
                         _ senses: [(key: String, pos: String?, definition: String,
                                     examples: [String])]) -> IndexedEntry {
        IndexedEntry(
            entryID: id, headword: headword, homograph: nil,
            senses: senses.map { sense in
                let key = SenseKey(dictionary: "d", entry: id, value: sense.key, origin: .content)
                return IndexedSense(key: key, contentKey: key,
                                    position: SensePosition(partOfSpeech: sense.pos),
                                    definition: sense.definition, examples: sense.examples)
            },
            anchors: anchors)
    }

    /// **The join the alignment rests on: entries, not anchors.** One entry commonly carries several — a
    /// `prlexid` per pronunciation, British and American — and iterating anchors assessed its senses once per
    /// pronunciation, inflating every count and leaving `INSERT OR REPLACE` to collapse the duplicates
    /// afterwards.
    @Test func entriesAreJoinedOnceHoweverManyAnchorsTheyShare() throws {
        let store = try Self.store()
        try store.beginRebuild(identifier: "hub", displayName: "hub", contentVersion: "1",
                               keyConfidence: "verified")
        try store.beginRebuild(identifier: "spoke", displayName: "spoke", contentVersion: "1",
                               keyConfidence: "verified")
        // Both entries carry the same two anchors — one word, two pronunciations.
        try store.insert(Self.anchored("h1", "fine", ["optra1.001", "optra1.005"],
                                       [("k1", "noun", "a penalty", [])]), dictionary: "hub")
        try store.insert(Self.anchored("s1", "fine", ["optra1.001", "optra1.005"],
                                       [("k2", "noun", "罚款", [])]), dictionary: "spoke")
        #expect(try store.anchorCount(in: "hub") == 2)
        let pairs = try store.entryPairs(hub: "hub", spoke: "spoke")
        #expect(pairs.count == 1, "one entry pair, not one per anchor: \(pairs)")
        #expect(pairs.first?.hub == "h1")
        #expect(pairs.first?.spoke == "s1")
    }

    /// An aligned pair is stored with both sides' identity, and read back.
    @Test func anAlignedPairRoundTrips() throws {
        let store = try Self.store()
        try store.beginRebuild(identifier: "hub", displayName: "hub", contentVersion: "1",
                               keyConfidence: "verified")
        try store.beginRebuild(identifier: "spoke", displayName: "spoke", contentVersion: "1",
                               keyConfidence: "verified")
        try store.insert(Self.anchored("h1", "fine", ["optra1.001"],
                                       [("k1", "noun", "a penalty", ["a heavy fine"])]),
                         dictionary: "hub")
        try store.insert(Self.anchored("s1", "fine", ["optra1.001"],
                                       [("k2", "noun", "罚款", ["a heavy fine"])]),
                         dictionary: "spoke")
        let hubSense = try #require(try store.sensesByEntry(in: "hub")["h1"]?.first)
        let spokeSense = try #require(try store.sensesByEntry(in: "spoke")["s1"]?.first)
        #expect(hubSense.examples == ["a heavy fine"], "examples did not round-trip")

        try store.insertAlignment(hub: ("hub", hubSense), spoke: ("spoke", spokeSense),
                                  confidence: 0.82, method: SenseAligner.method)
        #expect(try store.alignmentCount(hub: "hub", spoke: "spoke") == 1)

        // **A pair dies with either sense.** The first schema draft let an alias outlive its entry and then
        // resolve to an unrelated word; a stored alignment pointing at a sense that has been rebuilt away is
        // that defect with two dictionaries in it.
        try store.forget("spoke")
        #expect(try store.alignmentCount(hub: "hub", spoke: "spoke") == 0,
                "the pair outlived the sense it pointed at")
    }

    /// A pair whose sense does not exist is refused outright.
    @Test func anAlignmentToANonexistentSenseIsRejected() throws {
        let store = try Self.store()
        try store.beginRebuild(identifier: "hub", displayName: "hub", contentVersion: "1",
                               keyConfidence: "verified")
        try store.insert(Self.anchored("h1", "fine", ["optra1.001"],
                                       [("k1", "noun", "a penalty", [])]), dictionary: "hub")
        let real = try #require(try store.sensesByEntry(in: "hub")["h1"]?.first)
        let ghost = IndexStore.AlignableSense(
            entryID: "nowhere", senseKey: "k9", origin: "content", headword: "fine",
            partOfSpeech: "noun", definition: "invented", examples: [], subEntry: nil,
            hasSubsenses: false)
        #expect(throws: IndexStore.Failure.self) {
            try store.insertAlignment(hub: ("hub", real), spoke: ("hub", ghost),
                                      confidence: 0.9, method: "test")
        }
    }

    /// **The inflection list is the publisher's, and phrases are not inflections.** `held` must be excluded
    /// from matchable text along with `hold`; `hold water` is a sub-entry's name and must not be.
    @Test func inflectionsAreSingleWordSearchFormsOnly() throws {
        let store = try Self.store()
        try Self.register(store)
        try store.insert(Self.entry(id: "hold", headword: "hold",
                                    senses: [("k1", "to grasp", nil)]), dictionary: "d",
                         aliases: [SearchAlias(search: "hold", display: "hold"),
                                   SearchAlias(search: "held", display: "held"),
                                   SearchAlias(search: "holding", display: "holding"),
                                   SearchAlias(search: "hold water", display: "hold water")])
        let forms = try store.inflectionsByEntry(in: "d")["hold"] ?? []
        #expect(forms == ["hold", "held", "holding"], "got \(forms.sorted())")
    }

    /// A parent is reported as one, so a matcher can prefer the leaf that names a single meaning.
    @Test func aSenseWithChildrenReportsThat() throws {
        let store = try Self.store()
        try Self.register(store)
        let parent = SenseKey(dictionary: "d", entry: "at", value: "p", origin: .content)
        try store.insert(IndexedEntry(
            entryID: "at", headword: "@", homograph: nil,
            senses: [IndexedSense(
                key: parent, contentKey: parent, position: SensePosition(senseNumber: "1"),
                definition: "a; b", examples: [],
                subsenses: [
                    IndexedSubsense(key: SenseKey(dictionary: "d", entry: "at", value: "s1",
                                                  origin: .content), label: nil, definition: "a"),
                    IndexedSubsense(key: SenseKey(dictionary: "d", entry: "at", value: "s2",
                                                  origin: .content), label: "•", definition: "b"),
                ])]), dictionary: "d")
        let senses = try store.sensesByEntry(in: "d")["at"] ?? []
        #expect(senses.count == 3)
        #expect(senses.filter(\.hasSubsenses).map(\.senseKey) == ["p"])
        #expect(senses.filter { !$0.hasSubsenses }.map(\.senseKey).sorted() == ["s1", "s2"])
    }
}

/// **Opening an index to read it must never be able to destroy it.**
///
/// `IndexStore(path:)` opens `READWRITE | CREATE` and drops every table when `user_version` differs. That
/// is right for a rebuild, which owns the file and can always build it again from the reader's own
/// dictionaries. It is catastrophic for anything that only wants to *read*: the phrase detector opens the
/// index to fetch sub-entry labels, and under the read-write initialiser a reader whose index was written
/// by a different build would have 319 MB of derived data silently dropped by a lookup — and a reader with
/// no index at all would get an empty one created, which later reads as "nothing is indexed".
///
/// So the read-only door refuses both, loudly, and these are the two refusals.
@Suite struct IndexStoreReadOnlyTests {
    /// The load-bearing one, **asserted on the bytes**.
    ///
    /// Reading the rows back is not available here: the only door that can reset `user_version` is the
    /// read-write one, and opening it is itself what drops the tables — so a test that reopened to look
    /// would destroy the evidence it came for. The file being byte-identical is the stronger claim anyway,
    /// and it says the refusal happened *before* anything was written.
    ///
    /// **It carries its own positive control.** The same read-write open on the same file at the end both
    /// proves the hazard is real and proves this check could have failed.
    @Test func anIndexFromAnotherSchemaIsRefusedWithoutBeingTouched() throws {
        let scratch = TemporaryDirectory(named: "adf-readonly")
        let url = scratch.appending("index.sqlite")
        do {
            let store = try IndexStore(path: url.path)
            try IndexStoreTests.register(store)
            try store.insert(IndexStoreTests.entry(senses: [("k1", "to hand over", nil)]),
                             dictionary: "d", aliases: [SearchAlias(search: "give", display: "give")])
            #expect(try store.candidates(for: "give").count == 1)
            try store.setSchemaVersionForTesting(IndexStore.schemaVersion - 1)
        }
        let before = try Data(contentsOf: url)
        #expect(throws: IndexStore.Failure.self) { try IndexStore(readingAt: url.path) }
        #expect(try Data(contentsOf: url) == before,
                "the refused open left the reader's index byte-identical")

        let writable = try IndexStore(path: url.path)
        #expect(try Data(contentsOf: url) != before,
                "and the read-write door does change it — which is the hazard, and this test's control")
        #expect(try writable.candidates(for: "give").isEmpty,
                "it dropped the reader's rows, which is why reading must not come through it")
    }

    /// **No index is not an empty index.** Creating one here would answer every later question with
    /// "nothing is indexed" for a reader who simply has not built one yet.
    @Test func amissingIndexIsRefusedRatherThanCreated() throws {
        let scratch = TemporaryDirectory(named: "adf-readonly-missing")
        let path = scratch.appending("index.sqlite").path
        #expect(throws: IndexStore.Failure.self) { try IndexStore(readingAt: path) }
        #expect(FileManager.default.fileExists(atPath: path) == false,
                "the refused open must not have left a file behind")
    }

    /// A current index opens and reads, which is the whole point of the door.
    @Test func acurrentIndexOpensForReading() throws {
        let scratch = TemporaryDirectory(named: "adf-readonly-ok")
        let path = scratch.appending("index.sqlite").path
        do {
            let store = try IndexStore(path: path)
            try IndexStoreTests.register(store)
            try store.insert(
                IndexStoreTests.entry(senses: [("k1", "to reckon with", "take something into account")]),
                dictionary: "d", aliases: [SearchAlias(search: "take", display: "take")])
        }
        let reading = try IndexStore(readingAt: path)
        #expect(try reading.subEntryLabels(in: "d") == ["take something into account"])
    }

    /// And a read-only connection cannot write, however it is asked — the property the refusals above are
    /// protecting, asserted rather than assumed from the open flags.
    @Test func areadOnlyConnectionRefusesToWrite() throws {
        let scratch = TemporaryDirectory(named: "adf-readonly-write")
        let path = scratch.appending("index.sqlite").path
        do { _ = try IndexStore(path: path) }
        let reading = try IndexStore(readingAt: path)
        #expect(throws: IndexStore.Failure.self) { try IndexStoreTests.register(reading) }
    }
}
