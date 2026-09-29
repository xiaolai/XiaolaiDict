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

extension LibraryWiringTests {
    /// **A destructive action must affect exactly what the footer says.**
    ///
    /// The selection was pruned into the *presentation* and not in the model, so selecting two rows
    /// and then searching until one was visible showed "Remove 1" over a command that removed both.
    /// The reader sees a count and presses a button; those have to be the same set.
    @Test func abulkActionCannotReachRowsTheReaderCanNoLongerSee() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let fine = try save(ledger, "fine")
        let hold = try save(ledger, "hold")

        let model = model(path)
        await model.reload()
        model.act(.select([fine.id, hold.id]))
        try await settle { model.presentation.selection.count == 2 }

        // Narrow until only one of them is on screen.
        model.act(.search("hold"))
        try await settle { model.presentation.rows.count == 1 }
        #expect(model.presentation.selection == [hold.id], "the footer counts what is visible")

        model.act(.removeFromStudy)
        try await settle { model.presentation.rows.isEmpty }

        let reopened = try Ledger(path: path)
        let left = try reopened.library(LibraryQuery())
        #expect(left.map(\.id) == [fine.id],
                "the action reached a row the reader could not see")
    }
}

extension LibraryWiringTests {
    /// **A status with no remedy is a diagnosis.** The library showed "Confirm the meaning" and
    /// offered no way to confirm, so a proposal the reader saved stayed out of review for ever.
    @Test func thereaderCanConfirmAproposalFromTheLibrary() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let lookup = try ledger.record(LookupRecord(
            surface: "fine", lemma: "fine", context: "He paid the fine.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: nil, name: nil),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: .latin))
        // Enrolled as the model proposed it: saved, and not askable.
        let note = try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e1", senseKey: "e1.1", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .model,
            answer: StudyAnswer(origin: .dictionary, text: "a penalty"), lookupID: lookup, at: now)
        #expect(try ledger.dueCards(at: now, limit: 10, dictionary: nil).isEmpty)

        let model = model(path)
        await model.reload()
        #expect(model.presentation.rows.first?.status == .needsConfirmation)
        model.act(.select([note.id]))
        try await settle { model.presentation.canConfirm }
        model.act(.confirm)
        try await settle { model.presentation.rows.first?.status == nil }

        let reopened = try Ledger(path: path)
        #expect(try reopened.readiness(of: note.id) == .ready)
        #expect(try reopened.dueCards(at: now, limit: 10, dictionary: nil).count == 1,
                "and it can now be asked")
    }

    /// **Everything that matched is reachable.** The model asked for one page and the view offered
    /// no continuation, so a library of 201 counted 201 and could show only 200 — and the 201st was
    /// reachable only by guessing a search term that narrowed to it.
    @Test func everyMatchingRowIsReachable() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let total = LibraryModel.pageSize + 1
        for index in 0..<total {
            try save(ledger, "word\(String(format: "%04d", index))")
        }
        let model = model(path)
        await model.reload()
        #expect(model.presentation.total == total)
        #expect(model.presentation.rows.count == LibraryModel.pageSize)
        #expect(model.presentation.hasMore, "no way to reach the rest")

        model.act(.showMore)
        try await settle { model.presentation.rows.count == total }
        #expect(!model.presentation.hasMore, "and nothing offers more than there is")
        #expect(model.presentation.rows.contains { $0.word == "word0000" }, "the oldest is reachable")
    }
}

/// **WI-007's surfaces, at the wire.** Tags, export and suggestions are Core features with library
/// controls; each of these asserts the control reaches the ledger, because a feature nothing calls
/// is not one.
@MainActor
struct LibraryOrganisationWiringTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() -> (String, () -> Void) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("xiaolaidict-org-\(UUID().uuidString).sqlite").path
        return (path, { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } })
    }

    @discardableResult
    private func save(_ ledger: Ledger, _ word: String) throws -> StudyNote {
        let lookup = try ledger.record(LookupRecord(
            surface: word, lemma: word, context: "A sentence with \(word).", lemmaBasis: .tagger,
            language: "en", contextRange: nil,
            place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil,
            script: .latin))
        return try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e-\(word)", senseKey: "e-\(word).1",
                   senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .reader, text: "what \(word) means"),
            lookupID: lookup, at: now)
    }

    private func model(_ path: String) -> LibraryModel {
        LibraryModel(store: { Task { try LedgerStore(path: path) } },
                     studyScripts: { [.latin] }, clock: { self.now })
    }

    @Test func taggingTheSelectionReachesTheLedger() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        let note = try save(ledger, "fine")
        let model = model(path)
        await model.reload()
        model.act(.select([note.id]))
        try await settle { model.presentation.selection == [note.id] }
        model.act(.tag("law"))
        try await settle { (try? Ledger(path: path).tags(of: note.id)) == ["law"] }
        #expect(try Ledger(path: path).tags(of: note.id) == ["law"])
    }

    /// **The file lands where the reader is told it lands**, and holds no publisher gloss.
    @Test func exportingWritesAfileAndSaysWhere() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        try save(ledger, "fine")
        let model = model(path)
        await model.reload()
        model.act(.export)
        try await settle { model.presentation.exported != nil }

        let written = try #require(model.presentation.exported)
        defer { try? FileManager.default.removeItem(atPath: written) }
        #expect(FileManager.default.fileExists(atPath: written), "no file at \(written)")
        let text = try String(contentsOfFile: written, encoding: .utf8)
        #expect(text.contains("what fine means"), "the reader's own answer should travel")
        #expect(text.contains("#columns:XiaolaiDictID"))
    }

    /// Suggestions appear under their own filter and are **offered, never enrolled**.
    @Test func suggestionsAreOfferedAndTakingOneEnrolsNothing() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try Ledger(path: path)
        for offset in [0.0, 86_400.0] {
            _ = try ledger.record(LookupRecord(
                surface: "recondite", lemma: "recondite", context: "A recondite point.",
                lemmaBasis: .tagger, language: "en", contextRange: nil,
                place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
                lookedUpAt: now.addingTimeInterval(offset), result: .found,
                answeredBy: .dictionaryService, quality: nil, script: .latin))
        }
        let model = model(path)
        model.act(.filter(.suggested))
        try await settle { !model.presentation.suggestions.isEmpty
            || model.presentation.problem != nil }
        #expect(model.presentation.problem == nil, "reload failed: \(model.presentation.problem ?? "")")
        #expect(model.presentation.suggestions.first?.lemma == "recondite")
        #expect(model.presentation.suggestions.first?.days == 2)

        model.act(.study(lemma: "recondite"))
        #expect(model.takeSuggestion() == "recondite", "the app is handed the word to look up")
        #expect(model.takeSuggestion() == nil, "and it cannot be taken up twice by a redraw")
        #expect(try Ledger(path: path).notes().isEmpty, "a suggestion enrolled something")

        model.act(.ignore(lemma: "recondite", language: "en"))
        try await settle { model.presentation.suggestions.isEmpty }
        #expect(try Ledger(path: path).notes().isEmpty, "\"already know\" made a card")
        #expect(try Ledger(path: path).history(of: "recondite").count == 2, "and erased nothing")
    }

    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the model never reached the expected state")
    }
}
