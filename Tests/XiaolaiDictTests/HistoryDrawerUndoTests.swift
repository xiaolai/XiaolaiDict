import Foundation
import Testing
@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// **Undo puts back the discard it was asked to, and clears only that discard's receipt.**
///
/// The undo awaits the ledger. A discard made in that wait installs its own receipt, and clearing
/// the receipt unconditionally afterwards erased the newer one — the reader lost the only control
/// that could bring back what they had just discarded.
@MainActor
struct HistoryDrawerUndoTests {
    private func entry(_ id: Int) -> ReadingEntry {
        ReadingEntry(
            id: id, lemma: "word\(id)", surface: "word\(id)", sentence: "A sentence.", sentenceRange: nil,
            place: ReadingPlace(name: "TextEdit"), at: Date(timeIntervalSince1970: 1_800_000_000),
            result: .found, quality: nil)
    }

    /// Waits for work the model started and did not await, with a deadline rather than a guess.
    private func eventually(_ what: Comment, _ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), what)
    }

    @Test func anUndoKeepsADiscardMadeWhileItWasRunning() async throws {
        let model = HistoryDrawerModel()
        let first = DispositionResult(operation: UUID(), affected: 1, skipped: 0)
        let second = DispositionResult(operation: UUID(), affected: 1, skipped: 0)
        var receipts = [first, second]
        model.discard = { _ in receipts.removeFirst() }
        let (release, releasing) = AsyncStream<Void>.makeStream()
        var undone: [UUID] = []
        model.undoDiscard = { operation in
            undone.append(operation)
            for await _ in release { break }
            // Skipped, so the undo leaves a mark that it finished — the receipt line runs right after.
            return DispositionResult(operation: operation, affected: 0, skipped: 1)
        }

        model.remove(entry(1))
        try await eventually("the first discard's receipt") { model.discardedReceipt == first }
        model.undoLastDiscard()
        try await eventually("the undo is waiting on the ledger") { undone == [first.operation] }
        model.remove(entry(2))
        try await eventually("the second discard's receipt") { model.discardedReceipt == second }
        releasing.yield()
        try await eventually("the undo finished") { model.problem != nil }
        #expect(model.discardedReceipt == second, "the newer discard is still undoable")
    }

    /// Positive control: with nothing in between, an undo does clear its own receipt.
    @Test func anUndoClearsItsOwnReceipt() async throws {
        let model = HistoryDrawerModel()
        let only = DispositionResult(operation: UUID(), affected: 1, skipped: 0)
        model.discard = { _ in only }
        var finished = false
        model.undoDiscard = { operation in
            defer { finished = true }
            return DispositionResult(operation: operation, affected: 1, skipped: 0)
        }
        model.remove(entry(1))
        try await eventually("the discard's receipt") { model.discardedReceipt == only }
        model.undoLastDiscard()
        try await eventually("the receipt cleared") { finished && model.discardedReceipt == nil }
    }
}
