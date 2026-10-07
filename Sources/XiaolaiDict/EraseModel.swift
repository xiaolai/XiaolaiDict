import Foundation
import Observation
import StudyKit
import SwiftUI
import XiaolaiDictUI

/// **The erase command's model.** WI-006's surface.
///
/// Small, and deliberately three-staged: nothing destructive happens on the first click. The preview
/// is a real count from the ledger rather than an estimate, because the reader is about to make a
/// decision they cannot reverse and a number that turns out to be wrong afterwards is worse than no
/// number at all.
@MainActor
@Observable
final class EraseModel {
    private(set) var presentation = ErasePresentation()

    private let store: @MainActor () -> Task<LedgerStore, any Error>?
    /// Told when an erase has changed the ledger, as every other write tells it. A parameter so a test
    /// can watch its own.
    private let changes: LedgerChanges

    /// Which preview is the one still wanted. **Each click on the first button counts in a task of its
    /// own, and a count is published whenever it arrives** — so one that arrived after Cancel reopened
    /// the preview the reader had put away, and one that arrived while an erase ran replaced the erasing
    /// surface with a fresh preview, Delete live again over an erase still deleting (audit-fix round 3,
    /// C2 and #1). Moved by each preview, Cancel and Delete, so only the latest preview, asked for since
    /// the last Cancel or Delete, may publish.
    private var previewGeneration = 0

    init(store: @escaping @MainActor () -> Task<LedgerStore, any Error>?, changes: LedgerChanges = .shared) {
        self.store = store
        self.changes = changes
    }

    func act(_ action: EraseAction) {
        // **One erase at a time, decided here, synchronously** (audit-fix round 2). The task below does
        // not run at the point it is made, so a second click queued a second erase, which found nothing
        // and replaced the first one's report. Nothing else is taken while one runs either: Cancel would
        // put the preview away over an erase that is still deleting.
        guard !presentation.isErasing else { return }
        switch action {
        case .preview:
            previewGeneration += 1
            let mine = previewGeneration
            Task { await preview(mine) }
        case .erase:
            // Only from the preview, which is the second click; the first deletes nothing.
            guard case .previewing = presentation.stage else { return }
            previewGeneration += 1
            presentation = ErasePresentation(stage: presentation.stage, isErasing: true)
            Task { await erase() }
        case .cancel:
            previewGeneration += 1
            presentation = ErasePresentation()
        }
    }

    private func preview(_ mine: Int) async {
        guard let opening = store() else { return }
        guard let ledger = try? await opening.value else {
            guard mine == previewGeneration else { return }
            presentation = ErasePresentation(stage: .failed(
                // "Reading history", which is what the reader asked to delete. It said "the
                // ledger", the store's name inside this codebase and nowhere a reader has seen.
                String(localized: "Your reading history could not be opened.",
                       comment: "Shown when the command that deletes reading history cannot open it")))
            return
        }
        // The store's own path, not one this model guessed: a guess would reach the reader's
        // ledger from a test, or a test's from the reader's.
        let impact: (lookups: Int, notesLeftWithoutACue: Int, backups: Int)
        do {
            impact = try await ledger.readingErasureImpact()
        } catch {
            guard mine == previewGeneration else { return }
            presentation = ErasePresentation(stage: .failed(error.localizedDescription))
            return
        }
        guard mine == previewGeneration else { return }
        presentation = ErasePresentation(stage: .previewing(ErasePresentation.Impact(
            lookups: impact.lookups, cardsLeftWithoutASentence: impact.notesLeftWithoutACue,
            backups: impact.backups)))
    }

    private func erase() async {
        guard let opening = store() else {
            presentation = ErasePresentation(stage: presentation.stage)
            return
        }
        do {
            let ledger = try await opening.value
            let report = try await ledger.eraseReadingData()
            presentation = ErasePresentation(stage: .erased(ErasePresentation.Report(report)))
            // **Announced, complete or not** (audit-fix round 2): the rows are gone either way, and the
            // Library, the lookup card and the reminders draw and plan from what is left.
            changes.committed()
        } catch {
            // **Not an erase that removed nothing** — an erase that did not happen. The two read
            // very differently to someone who just asked for their history to be deleted. A step that
            // fails after the rows have gone is in the report, never here.
            presentation = ErasePresentation(stage: .failed(error.localizedDescription))
        }
    }
}

extension ErasePresentation.Report {
    /// What the surface says of an erase, from what the ledger did — **one mapping**, for Settings'
    /// erase and the Library's permanent delete alike.
    init(_ report: Ledger.ErasureReport) {
        self.init(
            lookupsRemoved: report.lookupsRemoved,
            backupsLeft: report.backupsLeft.map { "\($0.key): \($0.value)" }.sorted(),
            unreached: report.unreached.map {
                switch $0 {
                case .backupsNotListed(let reason): .backupsNotListed(reason)
                case .writeAheadLogBusy: .writeAheadLogBusy
                case .notRewritten(let reason): .notRewritten(reason)
                }
            })
    }
}
