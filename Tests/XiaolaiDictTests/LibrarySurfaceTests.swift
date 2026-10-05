import Foundation
import SwiftUI
import Testing
@testable import XiaolaiDictUI

/// The Library window's rules that are decided as values, so they are tested as values: what a
/// sidebar click means, what a key means to a collection, what a selection is counted in, and what
/// a right-click acts on. The view only carries the answers out.
@MainActor
struct LibrarySurfaceTests {
    // MARK: - The sidebar

    /// The pane is always current; under Saved its filter is current too, so two rows are marked.
    @Test func theSidebarMarksThePaneAndUnderSavedItsFilter() {
        #expect(LibrarySidebar.selection(pane: .history, filter: .due) == [.pane(.history)])
        #expect(LibrarySidebar.selection(pane: .saved, filter: .due) == [.pane(.saved), .filter(.due)])
    }

    /// A click is read as what it added. The system's list hands back the whole new selection —
    /// one row for a plain click, the old ones and a new one for a Command-click.
    @Test func aSidebarClickChoosesTheRowItAdded() {
        let shown = LibrarySidebar.selection(pane: .saved, filter: .all)
        #expect(LibrarySidebar.chosen(from: shown, to: [.pane(.review)]) == .pane(.review))
        #expect(LibrarySidebar.chosen(from: shown, to: [.filter(.paused)]) == .filter(.paused))
        #expect(LibrarySidebar.chosen(from: shown, to: shown.union([.filter(.archived)])) == .filter(.archived))
    }

    /// Clicking what is already current changes nothing — it must not, for one, clear the filter.
    @Test func clickingACurrentRowChoosesNothing() {
        let shown = LibrarySidebar.selection(pane: .saved, filter: .due)
        #expect(LibrarySidebar.chosen(from: shown, to: [.pane(.saved)]) == nil)
        #expect(LibrarySidebar.chosen(from: shown, to: [.filter(.due)]) == nil)
        #expect(LibrarySidebar.chosen(from: shown, to: []) == nil)
    }

    /// Every pane and every filter draws its symbol and name from the one table, and no two rows
    /// of the sidebar share a symbol — Saved and All were both `tray.full`, History and Due both
    /// `clock`, Discarded and Archived both `archivebox`.
    @Test func noTwoSidebarRowsShareASymbol() {
        let symbols = LibraryPane.allCases.map(\.action.symbol)
            + LibraryPresentation.Filter.allCases.map(\.action.symbol)
        #expect(Set(symbols).count == symbols.count, "\(symbols)")
        #expect(LibraryPane.discarded.action.symbol != ActionSymbol.archive.symbol)
    }

    // MARK: - Keys

    @Test func commandASelectsEverythingAndShiftCommandALetsGo() {
        #expect(LibraryCollectionCommand.command(for: "a", modifiers: .command) == .selectAll)
        #expect(LibraryCollectionCommand.command(for: "a", modifiers: [.command, .shift]) == .deselectAll)
        // With Shift held the key arrives as the capital.
        #expect(LibraryCollectionCommand.command(for: "A", modifiers: [.command, .shift]) == .deselectAll)
    }

    @Test func escapeDeleteAndReturnEachMeanOneThing() {
        #expect(LibraryCollectionCommand.command(for: .escape, modifiers: []) == .clearSelection)
        #expect(LibraryCollectionCommand.command(for: .delete, modifiers: []) == .delete)
        #expect(LibraryCollectionCommand.command(for: .deleteForward, modifiers: []) == .delete)
        #expect(LibraryCollectionCommand.command(for: .return, modifiers: []) == .toggleInspector)
    }

    /// **The positive control: the rule can say no.** A bare letter is typing, and a key some
    /// other part of the system owns is not taken.
    @Test func otherKeysAreNotCommands() {
        #expect(LibraryCollectionCommand.command(for: "a", modifiers: []) == nil)
        #expect(LibraryCollectionCommand.command(for: "b", modifiers: .command) == nil)
        #expect(LibraryCollectionCommand.command(for: "a", modifiers: [.command, .option]) == nil)
        #expect(LibraryCollectionCommand.command(for: .delete, modifiers: .command) == nil)
        #expect(LibraryCollectionCommand.command(for: .return, modifiers: .shift) == nil)
    }

    @Test func selectingEverythingAnchorsAtTheFirstCard() {
        var interaction = LibraryCollectionInteraction<Int>()
        let ordered = [4, 5, 6, 7]
        _ = interaction.click(6, ordered: ordered, selection: [], command: false, shift: false)
        #expect(interaction.selectAll(ordered: ordered) == [4, 5, 6, 7])
        // The keyboard stays on the card it was on; a Shift-click now extends from the top.
        #expect(interaction.focused == 6)
        #expect(interaction.click(5, ordered: ordered, selection: [4, 5, 6, 7], command: false, shift: true) == [4, 5])
    }

    @Test func lettingGoKeepsTheKeyboardWhereItWas() {
        var interaction = LibraryCollectionInteraction<Int>()
        let ordered = [1, 2, 3]
        _ = interaction.click(2, ordered: ordered, selection: [], command: false, shift: false)
        #expect(interaction.deselectAll().isEmpty)
        #expect(interaction.focused == 2)
        // The next arrow moves from there, not from the first card.
        #expect(interaction.move(.right, ordered: ordered, selection: [], columns: 1, extend: false) == [3])
    }

    // MARK: - Counting a selection

    /// Cards and readings are different counts, and both are said when they differ.
    @Test func aSelectionNamesBothCountsOnlyWhenTheyDiffer() {
        #expect(!LibrarySelectionCount(cards: 2, readings: 2).namesBoth)
        #expect(LibrarySelectionCount(cards: 2, readings: 5).namesBoth)
        // Saved counts meanings alone.
        #expect(!LibrarySelectionCount(cards: 3).namesBoth)
        #expect(LibrarySelectionCount(cards: 3).readings == 3)
    }

    // MARK: - What a right-click acts on

    /// A row; confirmable where it says it needs confirming, as the model draws one, unless told.
    private func row(_ status: LibraryPresentation.Status?, confirmable: Bool? = nil) -> LibraryPresentation.Row {
        LibraryPresentation.Row(id: UUID(), word: "fine", excerpt: "", marks: [], answer: "", status: status, due: nil,
                                isConfirmable: confirmable ?? (status == .needsConfirmation))
    }

    /// A card outside the selection is acted on alone, and described from itself — the menu used
    /// to offer Pause and Resume together, and no Confirm or Unarchive at all.
    @Test func aRightClickOutsideTheSelectionActsOnThatCardAlone() {
        let paused = row(.paused), unconfirmed = row(.needsConfirmation), archived = row(.archived), plain = row(nil)
        // A paused proposal is still one confirming would change: the pause names the row, not the remedy.
        let pausedProposal = row(.paused, confirmable: true)
        let state = LibraryPresentation(rows: [paused, unconfirmed, archived, plain, pausedProposal], total: 5,
                                        selection: [plain.id])
        #expect(state.target(of: paused) == LibrarySelectionTarget(ids: [paused.id], isPaused: true, isArchived: false, confirmable: []))
        #expect(state.target(of: unconfirmed) == LibrarySelectionTarget(ids: [unconfirmed.id], isPaused: false, isArchived: false,
                                                                        confirmable: [unconfirmed.id]))
        #expect(state.target(of: archived) == LibrarySelectionTarget(ids: [archived.id], isPaused: false, isArchived: true, confirmable: []))
        #expect(state.target(of: pausedProposal).confirmable == [pausedProposal.id])
    }

    /// A card inside the selection brings the whole selection, with the selection's own facts —
    /// exactly what the toolbar acts on, so the two cannot disagree.
    @Test func aRightClickInsideTheSelectionActsOnTheSelection() {
        let one = row(nil), two = row(.paused)
        let state = LibraryPresentation(rows: [one, two], total: 2, selection: [one.id, two.id],
                                        confirmable: [one.id], selectionIsPaused: false, selectionIsArchived: true)
        #expect(state.target(of: two) == state.selectionTarget)
        #expect(state.selectionTarget == LibrarySelectionTarget(ids: [one.id, two.id], isPaused: false,
                                                                isArchived: true, confirmable: [one.id]))
    }

    /// The dialog's count is the count of cards it will reach.
    @Test func aPendingRemovalKnowsWhatItReaches() {
        let ids: Set<UUID> = [UUID(), UUID()]
        #expect(PendingRemoval(kind: .removeFromSaved, ids: ids).ids == ids)
        #expect(PendingRemoval(kind: .removeFromSaved, ids: ids) != PendingRemoval(kind: .deleteReadings, ids: ids))
    }

    // MARK: - Colour

    /// **A saved word is the colour it is in the history: the lemma's.** Hashing the word as it
    /// was written made *meeting* one colour in Saved and another in History.
    @Test func aSavedRowAndItsInspectorAreKeyedByTheLemma() {
        let row = LibraryPresentation.Row(id: UUID(), word: "meeting", accentKey: "meet", excerpt: "", marks: [],
                                          answer: "", status: nil, due: nil)
        #expect(row.accentKey == "meet")
        let inspector = LibraryPresentation.Inspector(id: row.id, word: "meeting", accentKey: "meet", answer: "", isReaders: false)
        #expect(inspector.accentKey == "meet")
        // The premise: the two keys really are two colours, or the test above proves nothing.
        #expect(ReadingPalette.index(for: "meet") != ReadingPalette.index(for: "meeting"))
        // A card the reader wrote was never looked up, and falls back to its own word.
        #expect(self.row(nil).accentKey == "fine")
    }

    // MARK: - A History card's date

    @Test func aCardSaysTheTimeOnlyForToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12)))
        #expect(ArchiveCardDate.showsTime(noon.addingTimeInterval(-3_600), now: noon, calendar: calendar))
        // Thirteen hours earlier is yesterday evening: under a day ago, and not today.
        #expect(!ArchiveCardDate.showsTime(noon.addingTimeInterval(-13 * 3_600), now: noon, calendar: calendar))
    }
}
