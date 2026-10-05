import AppKit
import SwiftUI
import Testing

@testable import XiaolaiDictUI

/// One symbol per action, and every one of them a symbol this macOS has.
///
/// A misspelt SF Symbol name is silent: `Image(systemName:)` draws nothing, the button keeps its
/// 28 pt target, and what the reader sees is a gap that still clicks. So every name is resolved.
struct ActionSymbolTests {
    private static func exists(_ symbol: String) -> Bool {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
    }

    @Test func everySymbolExistsOnThisSystem() {
        let missing = ActionSymbol.allCases.filter { !Self.exists($0.symbol) }
        #expect(missing.isEmpty, "no such SF Symbol: \(missing.map { "\($0) → \($0.symbol)" })")
        // A table of nothing resolves perfectly.
        #expect(ActionSymbol.allCases.count >= 50)
    }

    /// **The positive control**: the check can say no. One transposed letter is all it takes.
    @Test func aMisspeltSymbolDoesNotResolve() {
        #expect(Self.exists("archivebox"))
        #expect(!Self.exists("archviebox"))
        #expect(!Self.exists(""))
    }

    /// The cases that share a symbol **on purpose**, each for a reason. Anything else sharing one
    /// is two controls that look like the same action — which is the defect this enum exists for.
    private static let deliberatelyShared: [Set<ActionSymbol>] = [
        // A pane, and the actions that put something in it: a meaning, and a phrase (ADR-0049). Saving
        // either is one act with one destination, so it is one glyph; the name says which.
        [.savedPane, .saveMeaning, .savePhrase],
        [.discardedPane, .discardReading],
        [.reviewPane, .reviewSelected],
        // A filter, and the action that puts something under it.
        [.archive, .archivedFilter],
        // The filter, and the button that takes the reader to the same list.
        [.needsAttentionFilter, .findUnconfirmed],
        // The filter, and the button that goes back to it from an empty search.
        [.allFilter, .showEverything],
        // Both finish what the reader was in the middle of; never on screen together.
        [.done, .saveAnswer],
    ]

    /// Every group of cases with one symbol, which is what `deliberatelyShared` has to equal.
    private static func sharing(_ table: [(ActionSymbol, String)]) -> Set<Set<ActionSymbol>> {
        Set(Dictionary(grouping: table, by: \.1).values.map { Set($0.map(\.0)) }.filter { $0.count > 1 })
    }

    @Test func noTwoActionsShareASymbolExceptTheNamedPairs() {
        let found = Self.sharing(ActionSymbol.allCases.map { ($0, $0.symbol) })
        let allowed = Set(Self.deliberatelyShared)
        #expect(found.subtracting(allowed).isEmpty, "symbols shared without a reason: \(found.subtracting(allowed))")
        #expect(allowed.subtracting(found).isEmpty, "a pair listed as shared no longer is: \(allowed.subtracting(found))")
    }

    /// **The positive control** for the collision check, on the collision the audit found:
    /// `archivebox` for Discard as well as for Archive.
    @Test func theOldArchiveboxCollisionWouldBeCaught() {
        var table = ActionSymbol.allCases.map { ($0, $0.symbol) }
        table.removeAll { $0.0 == .discardReading }
        table.append((.discardReading, ActionSymbol.archive.symbol))
        let found = Self.sharing(table)
        #expect(found.contains([.archive, .archivedFilter, .discardReading]))
        #expect(!found.subtracting(Set(Self.deliberatelyShared)).isEmpty)
    }

    /// The meanings the audit found doubled up are apart now.
    @Test func theCollisionsTheAuditFoundAreGone() {
        #expect(ActionSymbol.discardReading.symbol != ActionSymbol.archive.symbol)
        #expect(ActionSymbol.savedPane.symbol != ActionSymbol.allFilter.symbol)
        #expect(ActionSymbol.historyPane.symbol != ActionSymbol.dueFilter.symbol)
        #expect(ActionSymbol.undo.symbol != ActionSymbol.offerAgain.symbol)
        #expect(ActionSymbol.saveMeaning.symbol != ActionSymbol.anotherBatch.symbol)
        #expect(ActionSymbol.done.symbol != ActionSymbol.alreadyKnow.symbol)
        // A grade is not Close, and the pair is not Cancel and OK.
        #expect(ActionSymbol.forgot.symbol != "xmark")
        #expect(ActionSymbol.remembered.symbol != "checkmark")
        #expect(ActionSymbol.findUnconfirmed.symbol != ActionSymbol.warning.symbol)
    }

    /// Every action has a name, and a name is a button's: no full stop, first letter capital.
    @Test func everyActionIsNamedLikeAButton() throws {
        for action in ActionSymbol.allCases {
            let title = String(localized: action.title)
            let first = try #require(title.first, "\(action) has no title")
            #expect(first.isUppercase, "\(action): \(title)")
            #expect(!title.hasSuffix("."), "\(action): \(title)")
        }
        // The vocabulary: saved, discarded, and one irreversible verb.
        #expect(String(localized: ActionSymbol.saveMeaning.title) == "Save This Meaning")
        // **Save, not "collect"**: the owner asked to collect a phrase as a card, and the card lands in
        // Saved. A second verb for the one act is how a reader pressed Keep and looked under Saved.
        #expect(String(localized: ActionSymbol.savePhrase.title) == "Save This Phrase")
        #expect(String(localized: ActionSymbol.discardReading.title) == "Discard")
        #expect(String(localized: ActionSymbol.deletePermanently.title) == "Delete Permanently")
        #expect(String(localized: ActionSymbol.removeFromSaved.title) == "Remove from Saved")
    }

    /// Destructive is what cannot simply be taken back. Discarding can.
    @Test func onlyWhatDestroysIsDestructive() {
        let destructive = Set(ActionSymbol.allCases.filter { $0.role == .destructive })
        #expect(destructive == [.deletePermanently, .removeFromSaved])
    }
}
