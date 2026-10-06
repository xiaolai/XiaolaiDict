import AppleDictionaryFormat
import DictionaryModel
import Foundation
import Synchronization
import Testing
import XiaolaiDictTestSupport

@testable import PhraseLookup

/// **The build the service runs**, with the dictionaries named and their inventories supplied, so what is
/// asserted is the merge, the currency check and the failure policy — not a licensed dictionary on disk.
struct FormTableReaderTests {
    typealias Reading = InflectionInventory.Reading

    static func bundle(_ identifier: String, english: Bool = true) -> DictionaryBundle {
        DictionaryBundle(
            url: URL(fileURLWithPath: "/nonexistent/\(identifier).dictionary"), identifier: identifier,
            displayName: identifier,
            languages: [DeclaredLanguage(index: english ? "en_US" : "de", explains: english ? "en_US" : "de")])
    }

    static func inventory(_ forms: [String: Set<Reading>], own: Set<String> = [],
                          headwords: Set<String> = []) -> InflectionInventory {
        InflectionInventory(contentVersion: "v", forms: forms, ownHeadwords: own, headwords: headwords)
    }

    struct Boom: Error {}

    @Test func theTableIsTheUnionOfTheEnglishDictionariesAndNothingElse() throws {
        let scratch = TemporaryDirectory()
        let asked = Mutex<[String]>([])
        let reading = FormTableReader.table(
            for: [Self.bundle("a"), Self.bundle("b"), Self.bundle("de", english: false)],
            store: FormTableStore(directory: scratch.url)) { bundle, _ in
            asked.withLock { $0.append(bundle.identifier) }
            return bundle.identifier == "a"
                ? Self.inventory(["swore": [Reading(lemma: "swear", partOfSpeech: "verb")]], own: ["found"],
                                 headwords: ["walk"])
                : Self.inventory(["swore": [Reading(lemma: "swear", partOfSpeech: "verb")],
                                  "found": [Reading(lemma: "find", partOfSpeech: "verb")]], own: ["found"],
                                 headwords: ["abuela"])
        }
        let table = try #require(reading.table)
        #expect(asked.withLock { $0.sorted() } == ["a", "b"], "a bilingual's key groups are another language's")
        #expect(table.count == 2)
        #expect(table.judge("abuelas", tagged: nil, partOfSpeech: nil) == .lemma("abuela"), "the word lists are unioned")
        #expect(table.judge("walked", tagged: nil, partOfSpeech: nil) == .lemma("walk"))
        #expect(table.entry(for: "found")?.isOwnHeadword == true)
        #expect(table.entry(for: "swore")?.isOwnHeadword == false)
        #expect(reading.failed.isEmpty && reading.wasCurrent == false)
    }

    @Test func theTableIsStoredAndTheNextPassReadsNoBody() throws {
        let scratch = TemporaryDirectory()
        let store = FormTableStore(directory: scratch.url)
        let calls = Mutex(0)
        let provide: (DictionaryBundle, String) throws -> InflectionInventory = { _, _ in
            calls.withLock { $0 += 1 }
            return Self.inventory(["swore": [Reading(lemma: "swear", partOfSpeech: "verb")]])
        }
        let first = FormTableReader.table(for: [Self.bundle("a")], store: store, inventory: provide)
        #expect(store.read() == first.table)
        let second = FormTableReader.table(for: [Self.bundle("a")], store: store, inventory: provide)
        #expect(second.wasCurrent)
        #expect(second.table == first.table)
        #expect(calls.withLock { $0 } == 1, "a current table was rebuilt")
    }

    /// **`sources` decides, never the file's presence.** Another set of dictionaries, or another extraction,
    /// is a different table, and a stored one built from the old is stale by definition.
    @Test func aTableBuiltFromOtherSourcesIsRebuilt() throws {
        let scratch = TemporaryDirectory()
        let store = FormTableStore(directory: scratch.url)
        try store.write(FormTable(sources: ["a\tunreadable"], forms: ["x": [.init(lemma: "y", partOfSpeech: "")]], ownHeadwords: []))
        let calls = Mutex(0)
        let reading = FormTableReader.table(for: [Self.bundle("a")], store: store) { _, _ in
            calls.withLock { $0 += 1 }
            return Self.inventory(["swore": [Reading(lemma: "swear", partOfSpeech: "verb")]])
        }
        #expect(calls.withLock { $0 } == 1)
        #expect(reading.table?.entry(for: "swore") != nil && reading.table?.entry(for: "x") == nil)
    }

    @Test func theExtractionsOwnVersionIsPartOfTheSources() throws {
        let scratch = TemporaryDirectory()
        let reading = FormTableReader.table(for: [Self.bundle("a")], store: FormTableStore(directory: scratch.url)) { _, _ in
            Self.inventory(["swore": [Reading(lemma: "swear", partOfSpeech: "verb")]])
        }
        #expect(reading.table?.sources.last == InflectionInventory.formatVersion)
    }

    /// **Named and skipped, never stored as though read.** The unread dictionary is absent from the sources,
    /// so the next launch finds the table stale and tries again.
    @Test func aDictionaryThatCannotBeReadIsNamedAndTriedAgainNextTime() throws {
        let scratch = TemporaryDirectory()
        let store = FormTableStore(directory: scratch.url)
        let reported = Mutex<[String]>([])
        let calls = Mutex(0)
        let provide: (DictionaryBundle, String) throws -> InflectionInventory = { bundle, _ in
            if bundle.identifier == "bad" { calls.withLock { $0 += 1 }; throw Boom() }
            return Self.inventory(["swore": [Reading(lemma: "swear", partOfSpeech: "verb")]])
        }
        let first = FormTableReader.table(for: [Self.bundle("good"), Self.bundle("bad")], store: store,
                                          inventory: provide) { why in reported.withLock { $0.append(why) } }
        #expect(first.failed == ["bad"] && first.read == ["good"])
        #expect(first.table?.count == 1)
        #expect(reported.withLock { $0 }.contains { $0.contains("bad") })
        _ = FormTableReader.table(for: [Self.bundle("good"), Self.bundle("bad")], store: store, inventory: provide)
        #expect(calls.withLock { $0 } == 2, "the failed dictionary was never retried")
    }

    @Test func whenNothingCanBeReadTheStoredTableIsKeptNotReplacedByNothing() throws {
        let scratch = TemporaryDirectory()
        let store = FormTableStore(directory: scratch.url)
        let old = FormTable(sources: ["old"], forms: ["x": [.init(lemma: "y", partOfSpeech: "")]], ownHeadwords: [])
        try store.write(old)
        let reading = FormTableReader.table(for: [Self.bundle("bad")], store: store) { _, _ in throw Boom() }
        #expect(reading.table == old)
        #expect(store.read() == old)
    }

    @Test func noEnglishDictionaryMeansNoBuildAndSaysWhy() {
        let scratch = TemporaryDirectory()
        let reported = Mutex<[String]>([])
        let reading = FormTableReader.table(
            for: [Self.bundle("de", english: false)], store: FormTableStore(directory: scratch.url),
            inventory: { _, _ in Issue.record("a bilingual was read"); return Self.inventory([:]) }) { why in
            reported.withLock { $0.append(why) }
        }
        #expect(reading.table == nil)
        #expect(!reported.withLock { $0 }.isEmpty, "silence reads as success")
    }

    @Test func aStoreThatCannotBeWrittenStillAnswers() throws {
        let scratch = TemporaryDirectory()
        let blocker = scratch.appending("blocked")
        try Data().write(to: blocker)
        let reported = Mutex<[String]>([])
        let reading = FormTableReader.table(
            for: [Self.bundle("a")], store: FormTableStore(directory: blocker.appending(path: "inside")),
            inventory: { _, _ in Self.inventory(["swore": [Reading(lemma: "swear", partOfSpeech: "verb")]]) }) { why in
            reported.withLock { $0.append(why) }
        }
        #expect(reading.table?.count == 1)
        #expect(reported.withLock { $0 }.contains { $0.contains("store") })
    }

    /// **A form is a headword if any dictionary says so**, not only the one that printed it.
    @Test func aFormPrintedByOneDictionaryAndTitledByAnotherIsAHeadword() throws {
        let scratch = TemporaryDirectory()
        let reading = FormTableReader.table(
            for: [Self.bundle("a"), Self.bundle("b")], store: FormTableStore(directory: scratch.url)) { bundle, _ in
            bundle.identifier == "a"
                ? Self.inventory(["found": [Reading(lemma: "find", partOfSpeech: "verb")]], headwords: ["find"])
                : Self.inventory([:], headwords: ["found"])
        }
        #expect(reading.table?.entry(for: "found")?.isOwnHeadword == true)
    }

    /// **The version the reader hashed is the one the inventory is given**, so a rebuild reads each file once.
    @Test func theReadersHashIsHandedToTheInventoryNotComputedAgain() throws {
        let scratch = TemporaryDirectory()
        let given = Mutex<[String]>([])
        _ = FormTableReader.table(for: [Self.bundle("a")], store: FormTableStore(directory: scratch.url)) { _, version in
            given.withLock { $0.append(version) }
            return Self.inventory([:])
        }
        #expect(given.withLock { $0 } == [Self.bundle("a").contentVersion()])
    }
}
