import DictionaryModel
import Foundation
import Testing
import XiaolaiDictCore
import XiaolaiDictUI
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **The erase command's wire.** WI-006's surface.
///
/// The Core is covered by `StudyRecoveryTests`; these assert the three-stage shape the reader sees,
/// because the thing that makes this command safe is that nothing destructive happens on the first
/// click and the preview is a real count.
@MainActor
struct EraseWiringTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func scratch() -> (String, () -> Void) {
        let path = ScratchFile.path("erase")
        return (path, { ScratchFile.remove(path) })
    }

    private func saved(_ path: String) throws -> Ledger {
        let ledger = try Ledger(path: path)
        let lookup = try ledger.record(LookupRecord(
            surface: "fine", lemma: "fine", context: "He paid the fine.", lemmaBasis: .tagger,
            language: "en", contextRange: nil, place: ReadingPlace(bundleID: "com.apple.Safari", name: "Safari"),
            lookedUpAt: now, result: .found, answeredBy: .dictionaryService, quality: nil))
        try ledger.enroll(
            .sense(dictionary: "noad", entryID: "e1", senseKey: "e1.1", senseKeyKind: .publisher),
            issuer: .live, language: "en", chosenBy: .reader,
            answer: StudyAnswer(origin: .dictionary, text: "a penalty"), lookupID: lookup, at: now)
        try ledger.backUp(to: path + ".schema7.backup")
        return ledger
    }

    /// **Nothing destructive on the first click**, and the preview is counted rather than guessed.
    @Test func thefirstClickOnlyCounts() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try saved(path)
        let model = EraseModel(store: Wiring.store(path))
        #expect(model.presentation.stage == .idle)

        model.act(.preview)
        try await settle {
            if case .previewing = model.presentation.stage { return true }
            return false
        }
        guard case .previewing(let impact) = model.presentation.stage else { return }
        #expect(impact.lookups == 1)
        #expect(impact.cardsLeftWithoutASentence == 1, "the card loses its sentence and says so")
        #expect(impact.backups == 1, "and the copy this app made is counted")
        #expect(try ledger.history(of: "fine").count == 1, "a preview deleted something")
    }

    /// The erase takes the history and the app's own copies, and keeps the card.
    @Test func theeraseTakesTheHistoryAndTheCopiesAndKeepsTheCard() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        _ = try saved(path)
        let model = EraseModel(store: Wiring.store(path))
        model.act(.preview)
        try await settle {
            if case .previewing = model.presentation.stage { return true }
            return false
        }
        model.act(.erase)
        try await settle {
            if case .erased = model.presentation.stage { return true }
            return false
        }
        guard case .erased(let report) = model.presentation.stage else { return }
        #expect(report.lookupsRemoved == 1)
        #expect(report.backupsLeft.isEmpty)

        let reopened = try Ledger(path: path)
        #expect(try reopened.history(of: "fine").isEmpty)
        #expect(try reopened.notes().count == 1, "the reader's cards were not theirs to take")
        #expect(Ledger.appManagedBackups(besides: path).isEmpty)
    }

    /// Cancelling puts it back to where it started, with nothing done.
    @Test func cancellingLeavesEverything() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try saved(path)
        let model = EraseModel(store: Wiring.store(path))
        model.act(.preview)
        try await settle {
            if case .previewing = model.presentation.stage { return true }
            return false
        }
        model.act(.cancel)
        #expect(model.presentation.stage == .idle)
        #expect(try ledger.history(of: "fine").count == 1)
    }

    /// **Generous on purpose.** Each of these opens a ledger, runs every migration and takes a
    /// backup, and the suite runs them in parallel with the rest — a budget tuned to one test alone
    /// fails under load and reads as a defect in the code rather than in the wait.
    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the model never reached the expected state")
    }
}

