import DictionaryModel
import Foundation
import Testing
import XiaolaiDictCore
import XiaolaiDictUI
@testable import XiaolaiDict

/// **The Library window against a real ledger.** WI-005's wire.
///
/// `StudyLibraryTests` proves the query; these prove that the reader's filter reaches it, that a bulk
/// action lands on the set they selected, and that the row says why a card is not being asked.
@MainActor
struct LibraryWiringTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() -> (String, () -> Void) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-library-\(UUID().uuidString).sqlite").path
        return (path, { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } })
    }

    @discardableResult
    private func save(_ ledger: Ledger, _ word: String, script: ProbeScript = .latin) throws -> StudyNote {
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence with \(word) in it.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil, script: script))
        return try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-\(word)", senseKey: "e-\(word).1", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "what \(word) means"),
            lookupID: lookup, at: now)
    }

    private func model(_ path: String, scripts: Set<ProbeScript> = [.latin]) -> LibraryModel {
        LibraryModel(store: { Task { try LedgerStore(path: path) } },
                     studyScripts: { scripts }, clock: { self.now })
    }

    @Test func thelibraryListsWhatTheReaderSaved() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine")
        try save(ledger, "hold")

        let model = model(path)
        await model.reload()
        #expect(model.presentation.rows.count == 2)
        #expect(model.presentation.total == 2)
        #expect(model.presentation.rows.allSatisfy { !$0.answer.isEmpty }, "the row carries its answer")
        #expect(model.presentation.rows.allSatisfy { $0.status == nil }, "and nothing is wrong with it")
    }

    /// The search reaches the query, not a filter applied to the page after it.
    @Test func searchingNarrowsTheQuery() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine")
        try save(ledger, "hold")

        let model = model(path)
        model.act(.search("hold"))
        try await settle { model.presentation.rows.count == 1 }
        #expect(model.presentation.rows.first?.word == "hold")
        #expect(model.presentation.total == 1, "the count is of what matched, not of the page")
    }

    /// **M10, at the wire.** The script filter is off until the reader asks for it.
    @Test func thescriptFilterIsOffUntilAsked() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine", script: .latin)
        try save(ledger, "水", script: .han)

        let model = model(path, scripts: [.latin])
        await model.reload()
        #expect(model.presentation.rows.count == 2, "a card outside the reader's scripts is not hidden")
        model.act(.filterScripts(true))
        try await settle { model.presentation.rows.count == 1 }
        #expect(model.presentation.scriptFiltered)
    }

    /// A bulk action lands on exactly the selection and clears it afterwards.
    @Test func abulkArchiveAffectsTheSelectionAndClearsIt() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let fine = try save(ledger, "fine")
        try save(ledger, "hold")

        let model = model(path)
        await model.reload()
        model.act(.select([fine.id]))
        try await settle { model.presentation.selection == [fine.id] }
        model.act(.archive)
        try await settle { model.presentation.selection.isEmpty }

        let reopened = try Ledger(path: path)
        let rows = try reopened.library(LibraryQuery())
        #expect(rows.first(where: { $0.id == fine.id })?.note.enrollment == .archived)
        #expect(rows.first(where: { $0.id != fine.id })?.note.enrollment == .active)
    }

    /// **Remove from study keeps the reading.** The row goes; the lookup does not.
    @Test func removingFromStudyLeavesTheReading() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let fine = try save(ledger, "fine")

        let model = model(path)
        await model.reload()
        model.act(.select([fine.id]))
        try await settle { model.presentation.selection == [fine.id] }
        model.act(.removeFromStudy)
        try await settle { model.presentation.rows.isEmpty }

        let reopened = try Ledger(path: path)
        #expect(try reopened.history(of: "fine").count == 1, "the reader's reading was not theirs to take")
    }

    /// The row says why a card is not being asked, so the library can show what needs attention.
    @Test func arowSaysWhyAcardIsNotBeingAsked() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        // Saved with no answer at all rather than reaching into the schema: a test that writes SQL
        // is a test that keeps working after the schema stops meaning what it did.
        let lookup = try ledger.record(LookupRecord(
            surface: "fine", lemma: "fine", context: "A sentence with fine in it.",
            lemmaBasis: .tagger, language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: .latin))
        let broken = try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-broken", senseKey: "e-broken.1",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader, answer: nil, lookupID: lookup, at: now)
        let paused = try save(ledger, "hold")
        try ledger.setPaused(true, ofNotes: [paused.id])

        let model = model(path)
        await model.reload()
        #expect(model.presentation.rows.first(where: { $0.id == broken.id })?.status == .needsRepair)
        #expect(model.presentation.rows.first(where: { $0.id == paused.id })?.status == .paused)
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the model never reached the expected state")
    }
}
