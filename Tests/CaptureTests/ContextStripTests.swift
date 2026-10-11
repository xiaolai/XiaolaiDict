import CoreGraphics
import DictionaryModel
import Foundation
import Testing
@testable import Capture

/// A window of recognised text, laid out in **points**, and the strips a capture of it would read.
///
/// Every fixture here is synthetic: invented sentences set at the geometry the 2026-10-11 measurements
/// found — a terminal at 2x with rows about 14 pt tall on a 20 pt pitch, so a five-row paragraph is about
/// 100 pt tall, and two panes in a window 2672 pt (5344 px) wide. No screen text is in this file.
struct StripPage {
    let size: CGSize
    private(set) var rows: [(text: String, x: CGFloat, y: CGFloat, height: CGFloat, charWidth: CGFloat)] = []

    init(width: CGFloat = 2672, height: CGFloat = 1000) {
        size = CGSize(width: width, height: height)
    }

    /// One observation: `text` set from `x`, its top at `y`, each character `charWidth` wide.
    mutating func add(_ text: String, x: CGFloat, y: CGFloat, height: CGFloat = 14, charWidth: CGFloat = 8) {
        rows.append((text, x, y, height, charWidth))
    }

    /// `text` wrapped into rows of at most `columns` characters at word boundaries, from `top` on a `pitch`.
    /// Answers the y below the last row.
    @discardableResult
    mutating func paragraph(
        _ text: String, x: CGFloat, top: CGFloat, columns: Int, pitch: CGFloat = 20, indent: CGFloat = 0
    ) -> CGFloat {
        var y = top
        for (index, row) in Self.wrapped(text, columns: columns).enumerated() {
            add(row, x: index == 0 ? x : x + indent, y: y)
            y += pitch
        }
        return y
    }

    static func wrapped(_ text: String, columns: Int) -> [String] {
        var rows: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if !current.isEmpty, current.count + 1 + word.count > columns {
                rows.append(current)
                current = ""
            }
            current += current.isEmpty ? String(word) : " " + word
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    /// What a capture of the strip `top ..< top + height`, the window's full width, reads: every row wholly inside it,
    /// normalised to the strip. A row the strip's edge cuts is not read, which is what Vision does with half a line.
    ///
    /// With `readingCutRows`, a row the edge cuts is read too, its box clipped to the strip — what Vision does with a row
    /// mostly inside, measured on the E2E Mac 2026-10-11: the clipped row's short box ended the paragraph there.
    func strip(top: CGFloat, height: CGFloat, readingCutRows: Bool = false) -> (lines: [RecognisedLine], region: CGSize) {
        let region = CGSize(width: size.width, height: height)
        let inside = rows.filter {
            readingCutRows ? $0.y < top + height && $0.y + $0.height > top : $0.y >= top && $0.y + $0.height <= top + height
        }
        let lines = inside.map { original -> RecognisedLine in
            let clippedTop = max(original.y, top), clippedBottom = min(original.y + original.height, top + height)
            let row = (text: original.text, x: original.x, y: clippedTop, height: clippedBottom - clippedTop,
                       charWidth: original.charWidth)
            var runs: [RecognisedRun] = []
            var offset = 0
            var column = 0
            for piece in row.text.split(separator: " ", omittingEmptySubsequences: false) {
                if !piece.isEmpty {
                    runs.append(RecognisedRun(
                        text: String(piece), utf16Offset: offset,
                        box: CGRect(
                            x: (row.x + CGFloat(column) * row.charWidth) / region.width,
                            y: (row.y - top) / region.height,
                            width: CGFloat(piece.count) * row.charWidth / region.width,
                            height: row.height / region.height)))
                }
                offset += piece.utf16.count + 1
                column += piece.count + 1
            }
            return RecognisedLine(
                text: row.text,
                box: CGRect(
                    x: row.x / region.width, y: (row.y - top) / region.height,
                    width: CGFloat(row.text.count) * row.charWidth / region.width, height: row.height / region.height),
                runs: runs)
        }
        return (lines, region)
    }

    /// The index of the observation holding `fragment`.
    static func index(of fragment: String, in lines: [RecognisedLine]) -> Int? {
        lines.firstIndex { $0.text.contains(fragment) }
    }
}

enum StripText {
    /// One sentence, long enough to wrap over five rows of 60 characters.
    static let fiveRows = "The keeper of the northern light counted every ship that passed the rocks after "
        + "dusk and wrote each name into a ledger whose pages had gone soft with salt and lamp smoke "
        + "until the winter storms closed the harbour and nothing sailed again before spring."
    static let otherPane = "A different pane holds a different story about a market town whose clock "
        + "ran seven minutes fast for a century while nobody thought to mend it."
    static let command = "• clear the stale checkouts with git worktree prune and git worktree list piped "
        + "through grep stale and awk print one and xargs git worktree remove force and then pkill "
        + "the old server and echo done when it is finished so the shell returns quietly to its prompt "
        + "and the next task can begin without any leftover process holding a port or a lock file open "
        + "anywhere on the machine at all and then the job is really over for the day"
    static let nextBullet = "• then rebuild everything from a clean tree"
    static let before = "An earlier paragraph closes here with its own full stop."
    static let after = "A later paragraph opens here and has nothing to do with the first one."
}

// MARK: - Columns

struct ColumnLayoutTests {
    /// Two panes split by an empty gutter; `gutterAt` is where the right pane starts, in points.
    private static func twoPanes(gutterAt split: CGFloat, leftColumns: Int, rightColumns: Int) -> StripPage {
        var page = StripPage()
        page.paragraph(StripText.fiveRows, x: 10, top: 100, columns: leftColumns)
        page.paragraph(StripText.otherPane, x: split, top: 100, columns: rightColumns)
        page.paragraph(StripText.otherPane, x: split, top: 200, columns: rightColumns)
        return page
    }

    @Test(arguments: [
        // Centred, off centre to the right, and off centre with a left pane wider than one 2000 px tile (1000 pt at 2x).
        (CGFloat(1340), 160, 160),
        (CGFloat(1700), 200, 110),
        (CGFloat(2100), 250, 60),
    ])
    func aGutterIsFoundWhereverItIs(split: CGFloat, leftColumns: Int, rightColumns: Int) throws {
        let page = Self.twoPanes(gutterAt: split, leftColumns: leftColumns, rightColumns: rightColumns)
        let (lines, region) = page.strip(top: 0, height: 400)
        let columns = ColumnLayout.columns(of: lines, region: region)
        try #require(columns.count == 2, "found \(columns)")
        // The boundary lies inside the empty band: after the left pane's ink and before the right pane's.
        let leftInk = lines.filter { $0.box.minX * region.width < split }.map { $0.box.maxX * region.width }.max() ?? 0
        #expect(columns[0].upperBound > leftInk && columns[0].upperBound < split, "\(columns) for ink to \(leftInk)")
        #expect(columns[1].lowerBound > leftInk && columns[1].lowerBound <= split)
    }

    /// The left pane is wider than one tile and is read in fragments split at the tile seam, as `BandTiling.merged`
    /// hands them back. The seam is not a gutter: the fragments of one row sit a space apart.
    @Test func aLeftPaneWiderThanOneTileIsOneColumn() throws {
        var page = StripPage()
        var y: CGFloat = 100
        for row in StripPage.wrapped(StripText.fiveRows + " " + StripText.fiveRows, columns: 150) {
            // Split each row at the word nearest 1000 pt — the edge of the first 2000 px tile.
            let words = row.split(separator: " ")
            var head = ""
            for word in words where CGFloat((head + " " + word).count) * 8 < 990 {
                head += head.isEmpty ? String(word) : " " + word
            }
            let tail = String(row.dropFirst(head.count + 1))
            page.add(head, x: 10, y: y)
            page.add(tail, x: 10 + CGFloat(head.count + 1) * 8, y: y)
            y += 20
        }
        page.paragraph(StripText.otherPane, x: 1400, top: 100, columns: 140)
        let (lines, region) = page.strip(top: 0, height: 400)
        let columns = ColumnLayout.columns(of: lines, region: region)
        try #require(columns.count == 2, "found \(columns)")
        #expect(columns[0].upperBound > 1200 && columns[0].upperBound < 1400, "\(columns)")
    }

    /// One column with a ragged right edge: the space right of the short rows reaches the window's edge, with nothing
    /// beyond it, so it is margin and not a gutter.
    @Test func aRaggedSingleColumnIsOneColumn() {
        var page = StripPage()
        page.add("short", x: 10, y: 100)
        page.add("a much longer row that reaches well across the window from its left margin", x: 10, y: 120)
        page.add("tiny", x: 10, y: 140)
        page.add("also short", x: 10, y: 160)
        let (lines, region) = page.strip(top: 0, height: 300)
        #expect(ColumnLayout.columns(of: lines, region: region).count == 1)
    }

    /// Ordinary word spaces, even aligned down a column of rows, are narrower than a gutter.
    @Test func wordSpacesAreNotGutters() {
        var page = StripPage()
        for (index, row) in ["alpha beta gamma delta", "omega theta kappa sigma", "lorem ipsum dolor amet"].enumerated() {
            page.add(row, x: 10, y: 100 + CGFloat(index) * 20)
        }
        let (lines, region) = page.strip(top: 0, height: 300)
        #expect(ColumnLayout.columns(of: lines, region: region).count == 1)
    }

    /// A title across both panes crosses the gutter on one row; the gutter is still there on the rest.
    @Test func aRowCrossingTheGutterDoesNotHideIt() throws {
        var page = Self.twoPanes(gutterAt: 1340, leftColumns: 160, rightColumns: 160)
        page.add("a heading set right across the middle of the window", x: 1100, y: 40)
        let (lines, region) = page.strip(top: 0, height: 400)
        let columns = ColumnLayout.columns(of: lines, region: region)
        try #require(columns.count == 2, "found \(columns)")
    }

    /// A right pane with a single row is still a pane: the gutter is empty on every row.
    @Test func aSparsePaneIsStillAColumn() throws {
        var page = StripPage()
        page.paragraph(StripText.fiveRows, x: 10, top: 100, columns: 120)
        page.add("$ prompt", x: 1500, y: 100)
        let (lines, region) = page.strip(top: 0, height: 400)
        #expect(ColumnLayout.columns(of: lines, region: region).count == 2)
    }

    @Test func nothingReadIsOneColumn() {
        #expect(ColumnLayout.columns(of: [], region: CGSize(width: 100, height: 100)).count == 1)
    }
}

// MARK: - The paragraph around the pointer

struct ParagraphFinderTests {
    private static func find(
        _ page: StripPage, top: CGFloat, height: CGFloat, pointingAt fragment: String
    ) throws -> (StripParagraph, [RecognisedLine]) {
        let (lines, region) = page.strip(top: top, height: height)
        let index = try #require(StripPage.index(of: fragment, in: lines), "\(fragment) is not in the strip")
        return (ParagraphFinder.paragraph(around: index, in: lines, region: region), lines)
    }

    /// The owner's measurement: the pointer on the first row of a five-row paragraph about 100 pt tall. A 300 pt
    /// strip centred there holds all five rows and the space around them, so both sides are closed.
    @Test func aFiveRowParagraphIsReadWholeFromAThreeHundredPointStrip() throws {
        var page = StripPage()
        page.paragraph(StripText.fiveRows, x: 10, top: 400, columns: 60)
        let (found, _) = try Self.find(page, top: 400 - 150, height: 300, pointingAt: "keeper")
        #expect(found.block.text == StripText.fiveRows, "\(found.block.text)")
        #expect(found.open.isEmpty, "open \(found.open)")
    }

    /// **The positive control: 140 pt cuts that paragraph.** Centred on its first row, the strip holds three of the
    /// five rows; the bottom of what was read is the strip's edge, not the paragraph's, and it must say so.
    @Test func aOneFortyPointStripCutsItAndSaysSo() throws {
        var page = StripPage()
        page.paragraph(StripText.fiveRows, x: 10, top: 400, columns: 60)
        let (found, _) = try Self.find(page, top: 400 - 70, height: 140, pointingAt: "keeper")
        #expect(found.block.text != StripText.fiveRows)
        #expect(found.open == [.below], "open \(found.open)")
        #expect(found.growable == [.below])
    }

    @Test func theTopEdgeCuttingAParagraphOpensOnlyTheTop() throws {
        var page = StripPage()
        page.paragraph(StripText.fiveRows, x: 10, top: 400, columns: 60)
        // The strip starts between rows two and three: rows three to five are read, with clear space below.
        let (found, _) = try Self.find(page, top: 438, height: 300, pointingAt: "soft")
        #expect(found.open == [.above], "open \(found.open)")
    }

    /// **A row the strip's edge cuts is no boundary.** Read with a short box, it failed the size test and closed the
    /// paragraph there as `complete` — the E2E Mac's first run of this change. It is the strip's edge, and the side is
    /// open: on the bottom and on the top alike.
    @Test func aRowCutByTheEdgeLeavesThatSideOpen() throws {
        var page = StripPage()
        page.paragraph(StripText.fiveRows, x: 40, top: 400, columns: 60)
        // The bottom edge at 468 cuts row four (460 ..< 474) in half; the top edge at 426 cuts row two (420 ..< 434).
        let (below, _) = page.strip(top: 300, height: 168, readingCutRows: true)
        let seedBelow = try #require(StripPage.index(of: "keeper", in: below))
        let foundBelow = ParagraphFinder.paragraph(around: seedBelow, in: below, region: CGSize(width: 2672, height: 168))
        #expect(foundBelow.open == [.below], "open \(foundBelow.open)")
        let (above, _) = page.strip(top: 426, height: 300, readingCutRows: true)
        let seedAbove = try #require(StripPage.index(of: "soft", in: above))
        let foundAbove = ParagraphFinder.paragraph(around: seedAbove, in: above, region: CGSize(width: 2672, height: 300))
        #expect(foundAbove.open == [.above], "open \(foundAbove.open)")
    }

    @Test func aParagraphBreakEndsTheParagraphOnBothSides() throws {
        var page = StripPage()
        page.paragraph(StripText.before, x: 10, top: 300, columns: 60)
        var y = page.paragraph(StripText.fiveRows, x: 10, top: 340, columns: 60)
        y = page.paragraph(StripText.after, x: 10, top: y + 20, columns: 60)
        let (found, _) = try Self.find(page, top: 250, height: 300, pointingAt: "salt")
        #expect(found.block.text == StripText.fiveRows, "\(found.block.text)")
        #expect(found.open.isEmpty, "open \(found.open)")
    }

    /// **The case the owner's ledger holds**: a bullet-led command soft-wrapped over eight rows, the pointer in the
    /// middle of it. The bullet starts it, the next bullet ends it, and the hanging indent continues it.
    @Test func aBulletLedCommandWrappedOverEightRowsIsReadWhole() throws {
        var page = StripPage()
        page.paragraph(StripText.before, x: 10, top: 180, columns: 60)
        let end = page.paragraph(StripText.command, x: 10, top: 200, columns: 60, indent: 16)
        page.paragraph(StripText.nextBullet, x: 10, top: end, columns: 60)
        #expect(StripPage.wrapped(StripText.command, columns: 60).count == 8)
        let (found, _) = try Self.find(page, top: 120, height: 300, pointingAt: "pkill")
        #expect(found.block.text == StripText.command, "\(found.block.text)")
        #expect(found.open.isEmpty, "open \(found.open)")
    }

    @Test func aSingleLongLineIsItsOwnParagraph() throws {
        var page = StripPage()
        page.add("one long line standing alone in the middle of an otherwise empty window", x: 10, y: 500)
        let (found, _) = try Self.find(page, top: 350, height: 300, pointingAt: "alone")
        #expect(found.block.text.hasPrefix("one long line"))
        #expect(found.open.isEmpty)
    }

    @Test func theOtherPaneIsNotInTheParagraph() throws {
        var page = StripPage()
        page.paragraph(StripText.fiveRows, x: 10, top: 400, columns: 60)
        page.paragraph(StripText.otherPane, x: 1500, top: 400, columns: 60)
        page.paragraph(StripText.otherPane, x: 1500, top: 480, columns: 60)
        let (found, _) = try Self.find(page, top: 300, height: 300, pointingAt: "keeper")
        #expect(found.block.text == StripText.fiveRows, "\(found.block.text)")
        #expect(!found.block.text.contains("market"))
    }

    /// The pointer in the right pane reads the right pane, and nothing of the left.
    @Test func theRightPaneIsReadFromTheRightPane() throws {
        var page = StripPage()
        page.paragraph(StripText.fiveRows, x: 10, top: 400, columns: 150)
        page.paragraph(StripText.otherPane, x: 1500, top: 400, columns: 60)
        let (found, _) = try Self.find(page, top: 300, height: 300, pointingAt: "market")
        #expect(found.block.text == StripText.otherPane, "\(found.block.text)")
    }

    /// **A hard cap.** Rows past it are not joined, and a side stopped by the cap is open — but growing the strip
    /// cannot close it, so it is not growable.
    @Test func theLengthIsCappedAndACappedSideIsNotGrowable() throws {
        var page = StripPage()
        let half = Array(repeating: "every row of this paragraph runs on without a single stop", count: 30)
            .joined(separator: " ")
        page.paragraph(half + " lighthouse " + half, x: 10, top: 300, columns: 300, pitch: 20)
        let (found, _) = try Self.find(page, top: 0, height: 1000, pointingAt: "lighthouse")
        #expect(found.block.text.contains("lighthouse"))
        #expect(found.block.text.utf16.count <= ContextStrip.maximumCharacters)
        #expect(found.open == [.above, .below], "open \(found.open)")
        #expect(found.growable.isEmpty, "growable \(found.growable)")
    }

    /// The cap is the dictionary service's own bound on a sentence, so a longer context can never break it.
    @Test func theCapIsTheServicesSentenceBound() {
        #expect(ContextStrip.maximumCharacters == LookupRequest.maximumSentenceLength)
    }
}

// MARK: - Growing the strip

struct StripGrowthTests {
    private static let window: ClosedRange<CGFloat> = 0...1200

    @Test func aStripGrowsUpwardOnlyWhenOnlyTheTopIsOpen() throws {
        let grown = try #require(ContextStrip.grown(400...700, toward: [.above], within: Self.window))
        #expect(grown == (400 - ContextStrip.growthStep)...700)
    }

    @Test func aStripGrowsDownwardOnlyWhenOnlyTheBottomIsOpen() throws {
        let grown = try #require(ContextStrip.grown(400...700, toward: [.below], within: Self.window))
        #expect(grown == 400...(700 + ContextStrip.growthStep))
    }

    @Test func bothSidesGrowWhenBothAreOpen() throws {
        let grown = try #require(ContextStrip.grown(400...700, toward: [.above, .below], within: Self.window))
        #expect(grown == (400 - ContextStrip.growthStep)...(700 + ContextStrip.growthStep))
    }

    @Test func nothingGrowsWhenNothingIsOpen() {
        #expect(ContextStrip.grown(400...700, toward: [], within: Self.window) == nil)
    }

    /// **Stop at the window's edge**, side by side: a strip at the top cannot grow upward, and can still grow down.
    @Test func theWindowsEdgeStopsThatSideAlone() throws {
        #expect(ContextStrip.grown(0...300, toward: [.above], within: Self.window) == nil)
        #expect(ContextStrip.grown(900...1200, toward: [.below], within: Self.window) == nil)
        let partly = try #require(ContextStrip.grown(50...350, toward: [.above], within: Self.window))
        #expect(partly == 0...350)
        let down = try #require(ContextStrip.grown(0...300, toward: [.above, .below], within: Self.window))
        #expect(down == 0...(300 + ContextStrip.growthStep))
    }

    /// **Stop at the maximum height**, whichever side asked.
    @Test func theMaximumHeightStopsGrowth() throws {
        let full = (300 as CGFloat)...(300 + ContextStrip.maximumHeight)
        #expect(ContextStrip.grown(full, toward: [.above], within: Self.window) == nil)
        #expect(ContextStrip.grown(full, toward: [.below], within: Self.window) == nil)
        let nearly = (300 as CGFloat)...(300 + ContextStrip.maximumHeight - 50)
        let grown = try #require(ContextStrip.grown(nearly, toward: [.above, .below], within: Self.window))
        #expect(grown.upperBound - grown.lowerBound == ContextStrip.maximumHeight)
    }

    @Test func theHeightsAreOrdered() {
        #expect(ContextStrip.initialHeight > 140)
        #expect(ContextStrip.initialHeight < ContextStrip.maximumHeight)
        #expect(ContextStrip.growthStep > 0)
    }

    /// **A growth read is started only where it can finish inside the budget**, estimated from the read just made.
    @Test func growthIsAffordableOnlyInsideTheBudget() {
        #expect(ContextStrip.affordable(elapsed: .milliseconds(900), lastRead: .milliseconds(800)))
        #expect(!ContextStrip.affordable(elapsed: .milliseconds(2500), lastRead: .milliseconds(800)))
        #expect(!ContextStrip.affordable(elapsed: .milliseconds(100), lastRead: ContextStrip.growthBudget))
    }

    /// Every growth an open side asks for ends: from the initial strip, at most this many reads reach the maximum.
    @Test func growthEndsAtTheMaximumInBoundedSteps() {
        var strip: ClosedRange<CGFloat> = 450...(450 + ContextStrip.initialHeight)
        var reads = 1
        while let next = ContextStrip.grown(strip, toward: [.above], within: 0...5000) {
            strip = next
            reads += 1
            if reads > 10 { break }
        }
        #expect(strip.upperBound - strip.lowerBound == ContextStrip.maximumHeight)
        #expect(reads <= 3)
    }
}
