import Foundation
import Testing
import XiaolaiDictCore
@testable import XiaolaiDict

/// That the migrations are **called**, not that they work.
///
/// `StateMigrationTests` covers the moving. This covers the wire, because this project has
/// shipped a complete, correct, fully unit-tested type that nothing ever constructed:
/// `HoverPause` had three durations, a pause and a resume, and `HoverReader.pause` defaulted to
/// a fresh never-paused value built on every call, so the gate could not fire for months under a
/// green suite. A migration nothing calls fails the same way and costs the reader more.
struct StateMigrationWiringTests {
    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-wiring-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seedLegacyLedger(under root: URL, lemmas: [String]) throws {
        let directory = root.appendingPathComponent(StateMigration.legacyDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledger = try Ledger(path: directory.appendingPathComponent(StateMigration.ledgerFileName).path)
        for lemma in lemmas {
            _ = try ledger.record(LookupRecord(
                surface: lemma, lemma: lemma, context: "A sentence with \(lemma) in it.",
                lemmaBasis: .tagger, language: "en", lookedUpAt: noon, result: .found,
                answeredBy: .dictionaryService, quality: nil))
        }
    }

    /// The store the app actually opens migrates on its way to opening.
    @Test func openDefaultCarriesTheLegacyLedgerAcross() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacyLedger(under: root, lemmas: ["hold", "fine", "sanction"])

        let store = try await LedgerStore.openDefault(applicationSupport: root)

        // Read through the store the app uses, not through the file: what is being claimed is
        // that the reader's history is there when the app asks for it.
        let recent = try await store.recentLookups(since: noon.addingTimeInterval(-60), limit: 10)
        #expect(recent.count == 3)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(StateMigration.legacyDirectoryName).path) == false)
    }

    /// The order inside `openDefault` is the whole of it. Creating the directory before migrating
    /// would leave the move refusing for ever, and this is what would catch that: the destination
    /// exists afterwards either way, so only the rows can tell the two orders apart.
    @Test func theDirectoryIsNotCreatedBeforeTheMoveIsAttempted() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedLegacyLedger(under: root, lemmas: ["temper"])

        _ = try await LedgerStore.openDefault(applicationSupport: root)

        let moved = try Ledger(path: root
            .appendingPathComponent(StateMigration.directoryName, isDirectory: true)
            .appendingPathComponent(StateMigration.ledgerFileName).path)
        #expect(try moved.lookupCount() == 1)
    }

    /// A first-ever launch has nothing to carry, and still gets a working ledger.
    @Test func openDefaultWorksWhenThereIsNoLegacyDirectory() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await LedgerStore.openDefault(applicationSupport: root)

        #expect(try await store.recentLookups(since: noon, limit: 10).isEmpty)
    }

    /// The app's initialiser migrates settings, and does it before the stores read them — a value
    /// carried across after construction would not reach the reader until the next launch.
    @Test @MainActor func theAppCarriesSettingsAcrossBeforeItsStoresRead() throws {
        let legacy = "xiaolaidict.wiring.old.\(UUID().uuidString)"
        let current = "xiaolaidict.wiring.new.\(UUID().uuidString)"
        defer { for name in [legacy, current] { UserDefaults.standard.removePersistentDomain(forName: name) } }
        let source = try #require(UserDefaults(suiteName: legacy))
        source.set("frosted", forKey: "DrawerGlass")
        let destination = try #require(UserDefaults(suiteName: current))

        _ = XiaolaiDictApp(defaults: destination, migratingFrom: legacy, into: current)

        #expect(destination.string(forKey: "DrawerGlass") == "frosted")
    }

    /// And does not, when it is given no legacy domain — which is what every other test relies on
    /// to keep the reader's real settings out of its throwaway suite.
    @Test @MainActor func theAppCarriesNothingAcrossWhenGivenNoLegacyDomain() throws {
        let current = "xiaolaidict.wiring.new.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: current) }
        let destination = try #require(UserDefaults(suiteName: current))

        _ = XiaolaiDictApp(defaults: destination)

        #expect(destination.string(forKey: "DrawerGlass") == nil)
    }
}
