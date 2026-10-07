import CaptureModel
import DictionaryModel
import Foundation
import StudyKit
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
        #expect(try Ledger.appManagedBackups(besides: path).isEmpty)
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

    /// **One erase at a time, and the surface says one is running** (audit-fix round 2). Delete stayed
    /// live while the erase ran, so a second click queued a second erase behind it, which found nothing
    /// and replaced the first one's report — "0 readings deleted" over the reader's whole history.
    @Test func asecondClickWhileErasingIsRefusedAndTheFirstReportStands() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        _ = try saved(path)
        let model = EraseModel(store: Wiring.store(path), changes: LedgerChanges())
        model.act(.preview)
        try await settle {
            if case .previewing = model.presentation.stage { return true }
            return false
        }
        model.act(.erase)
        #expect(model.presentation.isErasing, "nothing on the surface says an erase is running")
        model.act(.erase)
        model.act(.cancel)
        try await settle {
            if case .erased = model.presentation.stage { return true }
            return false
        }
        guard case .erased(let report) = model.presentation.stage else { return }
        #expect(report.lookupsRemoved == 1, "a second erase replaced the first one's report")
        #expect(!model.presentation.isErasing)
    }

    /// **An erase is a ledger change, and is announced as one** (audit-fix round 2) — even an incomplete
    /// one, whose rows are gone all the same. Nothing told the Library, the lookup card or the reminders,
    /// which went on drawing and planning from readings that no longer existed.
    @Test func theEraseIsAnnouncedToWhateverDrawsTheLedger() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        _ = try saved(path)
        let changes = LedgerChanges()
        let model = EraseModel(store: Wiring.store(path), changes: changes)
        model.act(.preview)
        try await settle {
            if case .previewing = model.presentation.stage { return true }
            return false
        }
        #expect(changes.revision == 0, "a preview announced a change it did not make")
        model.act(.erase)
        try await settle {
            if case .erased = model.presentation.stage { return true }
            return false
        }
        #expect(changes.revision == 1, "the erase changed the ledger and told nobody")
    }

    /// **A retry after an incomplete erase is a click away** (audit-fix round 2): with every reading gone
    /// and a copy left, the preview counts zero readings and one copy, and Delete must still be live —
    /// the copy is what the reader is owed the deletion of.
    @Test func copiesLeftBehindStillOfferTheDelete() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        let ledger = try saved(path)
        try ledger.deleteLookups(after: 0)
        let model = EraseModel(store: Wiring.store(path), changes: LedgerChanges())
        model.act(.preview)
        try await settle {
            if case .previewing = model.presentation.stage { return true }
            return false
        }
        guard case .previewing(let impact) = model.presentation.stage else { return }
        #expect(impact.lookups == 0 && impact.backups == 1)
        #expect(impact.hasAnythingToDelete, "a copy left behind was not something to delete")
        model.act(.erase)
        try await settle {
            if case .erased = model.presentation.stage { return true }
            return false
        }
        #expect(try Ledger.appManagedBackups(besides: path).isEmpty)
    }

    /// **A preview that lands late says nothing** (audit-fix round 3, C2 and #1). Each click on the first
    /// button counts in a task of its own, and the count is published whenever it arrives: one that
    /// arrived after Cancel reopened the preview the reader had put away, and one that arrived while an
    /// erase was running replaced the erasing surface with a fresh preview — Delete live again over an
    /// erase still deleting. Only the latest preview still wanted may publish.
    @Test func apreviewThatLandsAfterCancelOrDuringAnEraseSaysNothing() async throws {
        let (path, clean) = scratch()
        defer { clean() }
        _ = try saved(path)
        let opened = try LedgerStore(path: path)
        let previewGate = Gate(), eraseGate = Gate()
        let calls = Counter()
        // The first opening is free, the second waits on `previewGate`, the third on `eraseGate`.
        let model = EraseModel(store: {
            calls.value += 1
            let gate: Gate? = switch calls.value {
            case 2: previewGate
            case 3: eraseGate
            default: nil
            }
            return Task { await gate?.wait(); return opened }
        }, changes: LedgerChanges())

        // **After Cancel.** The first preview is held at its opening while the reader cancels.
        calls.value = 1
        model.act(.preview)
        try await settle { calls.value == 2 }
        model.act(.cancel)
        await previewGate.open()
        await landed(on: opened)
        #expect(model.presentation.stage == .idle, "a preview landing after Cancel reopened it")

        // **During an erase.** A counted preview, a second click held at its opening, then Delete.
        calls.value = 0
        model.act(.preview)
        try await settle {
            if case .previewing = model.presentation.stage { return true }
            return false
        }
        await previewGate.close()
        model.act(.preview)
        try await settle { calls.value == 2 }
        model.act(.erase)
        try await settle { calls.value == 3 }
        try #require(model.presentation.isErasing)
        await previewGate.open()
        await landed(on: opened)
        #expect(model.presentation.isErasing, "a preview landing during the erase made Delete live again")
        await eraseGate.open()
        try await settle {
            if case .erased = model.presentation.stage { return true }
            return false
        }
        guard case .erased(let report) = model.presentation.stage else { return }
        #expect(report.lookupsRemoved == 1)
    }

    /// **Until a held task has published, or decided not to.** A task the gate releases resumes on the
    /// main actor and then asks the ledger, which serves its callers in order: a read of our own queued
    /// behind it returns after its answer, and the main actor runs the task's last step before ours.
    private func landed(on ledger: LedgerStore) async {
        for _ in 0..<3 {
            _ = try? await ledger.readingErasureImpact()
            for _ in 0..<20 { await Task.yield() }
        }
    }

    private actor Gate {
        private var opened = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func open() {
            opened = true
            for continuation in waiting { continuation.resume() }
            waiting.removeAll()
        }
        func close() { opened = false }
    }

    @MainActor private final class Counter { var value = 0 }

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

