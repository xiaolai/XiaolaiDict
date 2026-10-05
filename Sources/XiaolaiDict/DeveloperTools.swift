import Foundation
import XiaolaiDictCore
import XiaolaiDictUI

#if XIAOLAIDICT_CAPTURE_INSTRUMENTS
/// **The developer pane's operations, in the app.** A development build only: a release does not define
/// `XIAOLAIDICT_CAPTURE_INSTRUMENTS`, so this file compiles to nothing there and `build-bundle.sh` checks it.
///
/// Both operations work on the reader's real ledger — the dev bundle shares its path with a release — which
/// is why a clear takes a timestamped copy first and a deploy refuses anything but an empty ledger.
@MainActor
final class DeveloperTools {
    private let store: @MainActor () -> Task<LedgerStore, any Error>?
    private let changes: LedgerChanges
    private let dictionary: StudyDictionary

    init(store: @escaping @MainActor () -> Task<LedgerStore, any Error>?, changes: LedgerChanges = .shared,
         dictionary: StudyDictionary) {
        self.store = store
        self.changes = changes
        self.dictionary = dictionary
    }

    var choice: DeveloperChoice {
        DeveloperChoice(
            counts: { [self] in await counts() },
            clear: { [self] in await clear() },
            deploy: { [self] in await deploy() },
            backupName: "ledger.sqlite.dev-before-clear-<time>.backup")
    }

    private func opening() async throws -> LedgerStore {
        guard let task = store() else { throw DeveloperToolsError.noLedger }
        return try await task.value
    }

    private func counts() async -> DeveloperCounts? {
        guard let ledger = try? await opening(), let found = try? await ledger.developerCounts() else { return nil }
        return DeveloperCounts(lookups: found.lookups, notes: found.notes)
    }

    private func clear() async -> DeveloperOutcome {
        do {
            let ledger = try await opening()
            let cleared = try await ledger.clearForDeveloper(now: .now)
            dictionary.store.resetForDeveloper()
            changes.committed()
            // Re-derived and re-pinned against the now-empty ledger, so the study dictionary shows what a
            // fresh install would.
            await dictionary.refresh(revalidate: true)
            return .done("Cleared \(cleared.rows) rows. Copy kept as \((cleared.backup as NSString).lastPathComponent).")
        } catch {
            return .failed("Clear failed: \(error)")
        }
    }

    private func deploy() async -> DeveloperOutcome {
        do {
            let report = try await opening().deployForDeveloper(now: .now)
            changes.committed()
            return .done("Deployed \(report.lookups) readings, \(report.notes) study notes, \(report.reviewed) reviewed cards.")
        } catch DeveloperDataError.ledgerNotEmpty {
            return .failed("The ledger is not empty. Clear it first.")
        } catch {
            return .failed("Deploy failed: \(error)")
        }
    }
}

private enum DeveloperToolsError: Error { case noLedger }
#endif
