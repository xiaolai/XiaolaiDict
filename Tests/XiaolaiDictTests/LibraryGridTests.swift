import Foundation
import Testing
@testable import XiaolaiDictUI

/// How many columns the library's grid has, and which card goes in which.
///
/// The count follows the width the grid is given; the cards are dealt into the columns in turn, and
/// each column packs its own cards from the top. A `LazyVGrid` centred the cards of a row against
/// each other, so two cards of different heights sat with their top edges apart — seen 2026-10-01,
/// a card with no sentence beside one with a sentence.
@MainActor
struct LibraryGridTests {
    private let scale = Scale.standard

    /// The width a grid of `columns` cards at their narrowest needs, padding included.
    private func width(for columns: Int) -> CGFloat {
        let space = scale.space
        return CGFloat(columns) * space.cardMinWidth + CGFloat(columns - 1) * space.stack
            + space.padAcross + space.padAcross
    }

    @Test func aWidthThatFitsOneCardGivesOneColumn() {
        #expect(LibraryGridMetrics(availableWidth: width(for: 1), scale: scale).columns == 1)
        // Narrower than a card: still one, never none.
        #expect(LibraryGridMetrics(availableWidth: 0, scale: scale).columns == 1)
    }

    @Test(arguments: [2, 3, 4])
    func aColumnAppearsTheMomentItsCardFits(columns: Int) {
        #expect(LibraryGridMetrics(availableWidth: width(for: columns), scale: scale).columns == columns)
        // A point short of fitting, and the grid has one column fewer.
        #expect(LibraryGridMetrics(availableWidth: width(for: columns) - 1, scale: scale).columns == columns - 1)
    }

    /// **The window opens wide enough that selecting a card does not rearrange the grid.** The
    /// inspector takes its width from the collection; at 920 pt that took the grid from two columns
    /// to one, so the card the reader had just clicked moved under their pointer. It opens holding
    /// two columns *beside* the inspector, at the standard text size.
    @Test func theOpeningWindowKeepsTwoColumnsBesideTheInspector() {
        let detail = Token.Library.width - Token.Library.sidebarWidth
        let beside = detail - scale.space.libraryInspectorWidth
        #expect(LibraryGridMetrics(availableWidth: beside, scale: scale).columns == 2)
        #expect(LibraryGridMetrics(availableWidth: detail, scale: scale).columns >= 2)
    }

    /// **Never more than the cap, however wide the window.** Newest-to-oldest runs across a rank and
    /// then down, and a rank of seven is not something an eye follows back from.
    @Test func aVeryWideWindowStopsAtTheCap() {
        let cap = Token.Library.maxColumns
        #expect(LibraryGridMetrics(availableWidth: width(for: cap + 1), scale: scale).columns == cap)
        #expect(LibraryGridMetrics(availableWidth: width(for: cap) * 3, scale: scale).columns == cap)
    }

    /// The cards and the gaps between them take the whole width, at every count including the cap.
    @Test(arguments: [300, 700, 1_000, 1_400, 2_600] as [CGFloat])
    func theCardsFillTheWidth(available: CGFloat) {
        let metrics = LibraryGridMetrics(availableWidth: available, scale: scale)
        let space = scale.space
        let usable = max(0, available - space.padAcross - space.padAcross)
        let drawn = CGFloat(metrics.columns) * metrics.cardWidth + CGFloat(metrics.columns - 1) * space.stack
        #expect(abs(drawn - usable) < 0.001)
    }

    /// **List layout is one column of the same cards, drawn by the same code.** It was the system's
    /// `List`, which paints its own selection behind a row and turns the row's text white — over a
    /// white card that left a blue slab with the card's words gone, seen 2026-10-02 — while the
    /// pane's own selection ran on the same click.
    @Test func listLayoutIsOneColumnHoweverWideTheWindow() throws {
        #expect(LibraryGridMetrics(availableWidth: width(for: 4), scale: scale, single: true).columns == 1)
        let usable = width(for: 4) - scale.space.padAcross - scale.space.padAcross
        #expect(LibraryGridMetrics(availableWidth: width(for: 4), scale: scale, single: true).cardWidth == usable)
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Sources/XiaolaiDictUI/LibraryCollection.swift"),
            encoding: .utf8)
        #expect(!source.contains("List(rows"), "the system list brings its own selection and its own look")
    }

    /// Dealt in turn, so the first rank is the newest cards left to right and each column keeps the
    /// order it was given.
    @Test func cardsAreDealtIntoTheColumnsInTurn() {
        let metrics = LibraryGridMetrics(availableWidth: width(for: 2), scale: scale)
        #expect(metrics.dealt(Array(0..<5)) == [[0, 2, 4], [1, 3]])
        let three = LibraryGridMetrics(availableWidth: width(for: 3), scale: scale)
        #expect(three.dealt(Array(0..<7)) == [[0, 3, 6], [1, 4], [2, 5]])
    }

    /// Fewer cards than columns leaves the later columns empty rather than missing: the columns are
    /// the grid's shape, and a column that vanished would let the others spread into its place.
    @Test func everyColumnIsThereEvenWithNothingInIt() {
        let metrics = LibraryGridMetrics(availableWidth: width(for: 3), scale: scale)
        #expect(metrics.dealt([7]) == [[7], [], []])
        #expect(metrics.dealt([Int]()) == [[], [], []])
    }

    /// **The arrow keys and the arrangement are one rule.** Down is `+columns` and right is `+1` in
    /// the order the rows arrive in — and in columns dealt in turn those are exactly the card below
    /// in the same column and the next card of the same rank.
    @Test func downIsTheCardBelowAndRightIsTheCardBeside() {
        let metrics = LibraryGridMetrics(availableWidth: width(for: 3), scale: scale)
        let ordered = Array(0..<8)
        let columns = metrics.dealt(ordered)
        func place(_ id: Int) -> (column: Int, rank: Int)? {
            for (column, cards) in columns.enumerated() {
                if let rank = cards.firstIndex(of: id) { return (column, rank) }
            }
            return nil
        }
        var interaction = LibraryCollectionInteraction<Int>()
        _ = interaction.click(1, ordered: ordered, selection: [], command: false, shift: false)
        let below = interaction.move(.down, ordered: ordered, selection: [1], columns: metrics.columns, extend: false)
        #expect(below == [4])
        #expect(place(4)?.column == place(1)?.column)
        #expect(place(4)?.rank == (place(1)?.rank).map { $0 + 1 })
        let beside = interaction.move(.right, ordered: ordered, selection: below, columns: metrics.columns, extend: false)
        #expect(beside == [5])
        #expect(place(5)?.rank == place(4)?.rank)
        #expect(place(5)?.column == (place(4)?.column).map { $0 + 1 })
    }

    /// **The view draws what `dealt` answers, in columns pinned to the top.** Read from the source,
    /// the way `NoMagicValuesTests` reads it: `ImageRenderer` draws a `ScrollView` as one flat tone,
    /// so the arrangement cannot be pixel-tested, and a `dealt` nothing calls would pass every test
    /// above while the grid went on centring its rows.
    @Test func theGridDrawsTheDealtColumnsFromTheTop() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Sources/XiaolaiDictUI/LibraryCollection.swift"),
            encoding: .utf8)
        #expect(source.contains("metrics.dealt(rows)"), "the grid does not draw the dealt columns")
        #expect(source.contains("HStack(alignment: .top"), "the columns are not pinned to the top")
        #expect(source.contains("LazyVStack("), "a column is not lazy")
        #expect(!source.contains("LazyVGrid("), "a row-based grid centres cards of unequal height")
    }
}
