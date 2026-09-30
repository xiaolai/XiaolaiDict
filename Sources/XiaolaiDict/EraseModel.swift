import Foundation
import Observation
import SwiftUI
import XiaolaiDictCore
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

    init(store: @escaping @MainActor () -> Task<LedgerStore, any Error>?) {
        self.store = store
    }

    func act(_ action: EraseAction) {
        switch action {
        case .preview: Task { await preview() }
        case .erase: Task { await erase() }
        case .cancel: presentation = ErasePresentation()
        }
    }

    private func preview() async {
        guard let opening = store() else { return }
        guard let ledger = try? await opening.value else {
            presentation = ErasePresentation(stage: .failed(
                String(localized: "The ledger could not be opened.",
                       comment: "Shown when the erase command cannot reach the reader's ledger")))
            return
        }
        // The store's own path, not one this model guessed: a guess would reach the reader's
        // ledger from a test, or a test's from the reader's.
        let impact: (lookups: Int, notesLeftWithoutACue: Int, backups: Int)
        do {
            impact = try await ledger.readingErasureImpact()
        } catch {
            presentation = ErasePresentation(stage: .failed(error.localizedDescription))
            return
        }
        presentation = ErasePresentation(stage: .previewing(ErasePresentation.Impact(
            lookups: impact.lookups, cardsLeftWithoutASentence: impact.notesLeftWithoutACue,
            backups: impact.backups)))
    }

    private func erase() async {
        guard let opening = store() else { return }
        do {
            let ledger = try await opening.value
            let report = try await ledger.eraseReadingData()
            presentation = ErasePresentation(stage: .erased(ErasePresentation.Report(
                lookupsRemoved: report.lookupsRemoved,
                backupsLeft: report.backupsLeft.map { "\($0.key): \($0.value)" }.sorted())))
        } catch {
            // **Not an erase that removed nothing** — an erase that did not happen. The two read
            // very differently to someone who just asked for their history to be deleted.
            presentation = ErasePresentation(stage: .failed(error.localizedDescription))
        }
    }
}
