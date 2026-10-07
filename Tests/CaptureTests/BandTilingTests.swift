import CoreGraphics
import Foundation
import Testing
@testable import Capture

/// **A wide band is read in tiles, and read back as the one band it was.**
///
/// Vision reads small text only in an image up to ~2400 px wide (measured 2026-10-05, ADR-0016 addendum): the
/// window's whole width — 5120 px on the dev Mac — read 47% of uncommon words and 2000 px strips 100%. But the
/// sentence the reader pointed into is the reason for the band, so the width cannot simply be cut: the band is
/// split into overlapping tiles, each read at the accuracy of a narrow strip, and their runs are put back
/// together by position. Two tiles that both read a word give two boxes over the same ink; the one read **further
/// from its tile's edge** is kept and the other dropped, so nothing is read twice, a word the boundary falls through
/// is kept whole, and a fragment cut by a tile's edge loses to the tile that saw the word entire.
///
/// An earlier version gave each tile the places it "owned" and kept the runs whose centre was in them. On real Ghostty
/// pixels the same word's centre came back as 1701 in one tile and 1698 in the next with the boundary at 1700, and
/// **both tiles dropped it** — `buckjumper` vanished from the sentence. A decision made twice from two noisy
/// measurements can disagree with itself; this one is made once, over both.
struct BandTilingTests {
    // MARK: - The plan

    @Test func aBandWithinTheLimitIsOneTile() {
        let tiles = BandTiling.tiles(forWidth: 1800, maximum: 2000, overlap: 600)
        #expect(tiles == [BandTile(x: 0, width: 1800)])
    }

    @Test func theMeasuredCase() {
        // 2560 pt at 2x: four tiles, the last one flush with the right edge.
        let tiles = BandTiling.tiles(forWidth: 5120, maximum: 2000, overlap: 600)
        #expect(tiles.map(\.x) == [0, 1400, 2800, 3120])
        #expect(tiles.allSatisfy { $0.width == 2000 })
    }

    /// The properties that make the merge right, for every width rather than the ones someone thought of.
    @Test func everyPlanCoversTheBandAndOverlapsEnough() {
        for width in stride(from: 1, through: 13_000, by: 7) {
            let tiles = BandTiling.tiles(forWidth: width, maximum: 2000, overlap: 600)
            #expect(!tiles.isEmpty, "width \(width)")
            #expect(tiles.allSatisfy { $0.width <= 2000 && $0.width > 0 }, "width \(width): a tile is over the limit")
            #expect(tiles.first?.x == 0, "width \(width)")
            #expect(tiles.last.map { $0.x + $0.width } == width, "width \(width): the last tile stops short of the edge")
            for (a, b) in zip(tiles, tiles.dropFirst()) {
                #expect(b.x > a.x, "width \(width): tiles do not advance")
                // A word up to the overlap long, wherever it falls, is whole in at least one tile.
                #expect(a.x + a.width - b.x >= 600, "width \(width): neighbouring tiles overlap by less than the overlap")
            }
        }
    }

    /// A nonsense limit is a caller's mistake and must not trap or loop: the band is one tile, as it was.
    @Test(arguments: [(2000, 2000), (2000, 3000), (0, 0), (-5, 10)])
    func aNonsenseLimitIsOneTile(maximum: Int, overlap: Int) {
        let tiles = BandTiling.tiles(forWidth: 5120, maximum: maximum, overlap: overlap)
        #expect(tiles == [BandTile(x: 0, width: 5120)])
    }

    @Test func noWidthIsNoTiles() {
        #expect(BandTiling.tiles(forWidth: 0, maximum: 2000, overlap: 600).isEmpty)
    }

    // MARK: - The merge

    /// A one-run line at band pixels `from..<to`, as the tile at `tile` reports it: normalised to that tile.
    private static func seen(_ word: String, from: CGFloat, to: CGFloat, by tile: BandTile, y: CGFloat = 0.4) -> RecognisedLine {
        let box = CGRect(x: (from - CGFloat(tile.x)) / CGFloat(tile.width), y: y,
                         width: (to - from) / CGFloat(tile.width), height: 0.2)
        return RecognisedLine(text: word, box: box, runs: [RecognisedRun(text: word, utf16Offset: 0, box: box)], confidence: 1)
    }

    private static func runTexts(_ lines: [RecognisedLine]) -> [String] { lines.flatMap(\.runs).map(\.text) }

    /// A line of runs laid out on a tile: each word `step` normalised units wide, starting at `from`.
    private static func line(_ words: [String], from: CGFloat, step: CGFloat, y: CGFloat = 0.4) -> RecognisedLine {
        var text = ""
        var runs: [RecognisedRun] = []
        for (i, word) in words.enumerated() {
            if !text.isEmpty { text += " " }
            runs.append(RecognisedRun(
                text: word, utf16Offset: text.utf16.count,
                box: CGRect(x: from + CGFloat(i) * step, y: y, width: step * 0.9, height: 0.2)))
            text += word
        }
        let box = CGRect(x: from, y: y, width: step * CGFloat(words.count), height: 0.2)
        return RecognisedLine(text: text, box: box, runs: runs, confidence: 0.8)
    }

    /// **The defect real Ghostty pixels found.** One word, `buckjumper`, on the boundary: the first tile boxed it at
    /// 1600–1802 and the second at 1599–1798, so its centre was 1701 in one and 1698 in the other with the boundary at
    /// 1700 — and a tile that keeps "what is mine by centre" dropped it twice. It is one word, kept once.
    @Test func aWordOnTheBoundaryWhoseBoxesDisagreeIsKeptOnce() {
        let tiles = BandTiling.tiles(forWidth: 5120, maximum: 2000, overlap: 600)
        let merged = BandTiling.merged([
            (tiles[0], []),
            (tiles[1], [Self.seen("buckjumper", from: 1600, to: 1802, by: tiles[1])]),
            (tiles[2], [Self.seen("buckjumper", from: 1599, to: 1798, by: tiles[2])]),
            (tiles[3], []),
        ], bandWidth: 5120)
        #expect(Self.runTexts(merged) == ["buckjumper"])
    }

    /// The same, from every offset the jitter could take: gone twice or kept twice at none of them.
    @Test func noJitterLosesAWordOrKeepsItTwice() {
        let tiles = BandTiling.tiles(forWidth: 3000, maximum: 2000, overlap: 600)
        #expect(tiles.count == 2)
        for shift in -12...12 {
            let merged = BandTiling.merged([
                (tiles[0], [Self.seen("middle", from: 1450, to: 1650, by: tiles[0])]),
                (tiles[1], [Self.seen("middle", from: CGFloat(1450 + shift), to: CGFloat(1650 + shift), by: tiles[1])]),
            ], bandWidth: 3000)
            #expect(Self.runTexts(merged) == ["middle"], "shift \(shift): \(Self.runTexts(merged))")
        }
    }

    /// **A word one tile cut at its edge loses to the tile that saw it whole**, as real Ghostty pixels showed:
    /// `anomaloflorous` whole at 1315–1595 in one tile, and `aloflorous` at the next tile's left edge, 1400–1596.
    @Test func aFragmentCutByATilesEdgeLosesToTheWholeWord() {
        let tiles = BandTiling.tiles(forWidth: 5120, maximum: 2000, overlap: 600)
        let merged = BandTiling.merged([
            (tiles[0], [Self.seen("anomaloflorous", from: 1315, to: 1595, by: tiles[0])]),
            (tiles[1], [Self.seen("aloflorous", from: 1400, to: 1596, by: tiles[1])]),
        ], bandWidth: 5120)
        #expect(Self.runTexts(merged) == ["anomaloflorous"])
    }

    /// Two tiles that read one word differently keep one reading, not both: the one further from its tile's edge.
    @Test func twoReadingsOfOneWordKeepTheMoreInteriorOne() {
        let tiles = BandTiling.tiles(forWidth: 3000, maximum: 2000, overlap: 600)
        #expect(tiles.map(\.x) == [0, 1000])
        // The word is at band px 1700–1900: 100 px from the first tile's right edge, 700 px from the second's left.
        let merged = BandTiling.merged([
            (tiles[0], [Self.seen("rendltion", from: 1700, to: 1900, by: tiles[0])]),
            (tiles[1], [Self.seen("rendition", from: 1700, to: 1900, by: tiles[1])]),
        ], bandWidth: 3000)
        #expect(Self.runTexts(merged) == ["rendition"])
        // And the other way round, so it is the distance that decided and not the order.
        let swapped = BandTiling.merged([
            (tiles[0], [Self.seen("rendition", from: 1300, to: 1500, by: tiles[0])]),
            (tiles[1], [Self.seen("rendltion", from: 1300, to: 1500, by: tiles[1])]),
        ], bandWidth: 3000)
        // 1300–1500: 500 px from tile 0's right edge, 300 px from tile 1's left edge: tile 0 is more interior.
        #expect(Self.runTexts(swapped) == ["rendition"])
    }

    /// Distinct words are never merged however near: two identical neighbours, a word and its repeat, are both kept.
    @Test func identicalNeighboursAreBothKept() {
        let tile = BandTile(x: 0, width: 2000)
        let a = Self.seen("the", from: 100, to: 160, by: tile)
        let b = Self.seen("the", from: 180, to: 240, by: tile)
        let other = BandTile(x: 1400, width: 2000)
        let merged = BandTiling.merged([
            (tile, [a, b]),
            (other, [Self.seen("the", from: 1500, to: 1560, by: other)]),
        ], bandWidth: 3400)
        #expect(Self.runTexts(merged) == ["the", "the", "the"])
    }

    /// Words only one tile sees are kept, in reading order.
    @Test func wordsOnlyOneTileSeesAreAllKept() {
        let tiles = BandTiling.tiles(forWidth: 3000, maximum: 2000, overlap: 600)
        let merged = BandTiling.merged([
            (tiles[0], [Self.seen("alpha", from: 100, to: 300, by: tiles[0]), Self.seen("beta", from: 400, to: 600, by: tiles[0])]),
            (tiles[1], [Self.seen("omega", from: 2500, to: 2700, by: tiles[1])]),
        ], bandWidth: 3000)
        #expect(Self.runTexts(merged) == ["alpha", "beta", "omega"])
    }

    /// **A word that lost is not a reason to drop the words it overlapped** (audit finding 2). Tile 0 reads `aa` at
    /// 1400–1500 and `cc` at 1550–1650; tile 1 reads one run `bbbb` across 1400–1650. `bbbb` loses to `aa`; `cc` would
    /// lose to `bbbb` — but `bbbb` is gone, so `cc` has nothing left to lose to and must stay.
    @Test func aLoserDoesNotSuppressWhatItOverlapped() {
        let tiles = BandTiling.tiles(forWidth: 3000, maximum: 2000, overlap: 600)
        #expect(tiles.map(\.x) == [0, 1000])
        let merged = BandTiling.merged([
            (tiles[0], [Self.seen("aa", from: 1400, to: 1500, by: tiles[0]), Self.seen("cc", from: 1550, to: 1650, by: tiles[0])]),
            (tiles[1], [Self.seen("bbbb", from: 1400, to: 1650, by: tiles[1])]),
        ], bandWidth: 3000)
        #expect(Self.runTexts(merged) == ["aa", "cc"], "\(Self.runTexts(merged))")
    }

    /// **An observation with no runs never suppresses a run** (audit finding 3): it cannot be picked, so letting it
    /// win would turn one tile's failed box extraction into a lost word. It is dropped where a run covers it.
    @Test func anObservationWithoutRunsNeverSuppressesARun() {
        let tiles = BandTiling.tiles(forWidth: 3000, maximum: 2000, overlap: 600)
        // The run is 50 px from tile 0's edge; the runless observation sits 700 px inside tile 1 — deeper — over the same ink.
        let runBox = CGRect(x: 1900.0 / 2000, y: 0.4, width: 50.0 / 2000, height: 0.2)
        let withRun = RecognisedLine(
            text: "word", box: runBox, runs: [RecognisedRun(text: "word", utf16Offset: 0, box: runBox)], confidence: 1)
        let runless = RecognisedLine(
            text: "word", box: CGRect(x: 900.0 / 2000, y: 0.4, width: 50.0 / 2000, height: 0.2), runs: [], confidence: 1)
        let merged = BandTiling.merged([(tiles[0], [withRun]), (tiles[1], [runless])], bandWidth: 3000)
        #expect(Self.runTexts(merged) == ["word"], "the run is what a pointer can pick")
        #expect(merged.count == 1, "the runless observation over the same ink is the run's duplicate")
    }

    /// **A word that covers part of a sentence does not take the sentence with it** (audit round 2). A run at 1900–1950 in
    /// one tile and a runless observation, a whole sentence, at 1700–1990 in the next: the run is a sixth of it, and
    /// the text outside it has no other source.
    @Test func aRunCoveringPartOfARunlessObservationLeavesItAlone() {
        let tiles = BandTiling.tiles(forWidth: 3000, maximum: 2000, overlap: 600)
        let sentence = RecognisedLine(
            text: "a whole sentence the runs never saw",
            box: CGRect(x: 700.0 / 2000, y: 0.4, width: 290.0 / 2000, height: 0.2), runs: [], confidence: 1)
        let merged = BandTiling.merged([
            (tiles[0], [Self.seen("word", from: 1900, to: 1950, by: tiles[0])]),
            (tiles[1], [sentence]),
        ], bandWidth: 3000)
        #expect(merged.map(\.text).sorted() == ["a whole sentence the runs never saw", "word"], "\(merged.map(\.text))")
    }

    /// And where runs together cover most of it, the observation is their duplicate and goes — its words are not told twice.
    @Test func runsThatTogetherCoverAnObservationReplaceIt() {
        let tiles = BandTiling.tiles(forWidth: 3000, maximum: 2000, overlap: 600)
        let sentence = RecognisedLine(
            text: "one two three", box: CGRect(x: 700.0 / 2000, y: 0.4, width: 290.0 / 2000, height: 0.2),
            runs: [], confidence: 1)
        let merged = BandTiling.merged([
            (tiles[0], [Self.seen("one", from: 1700, to: 1760, by: tiles[0]), Self.seen("two", from: 1780, to: 1840, by: tiles[0]),
                        Self.seen("three", from: 1860, to: 1920, by: tiles[0])]),
            (tiles[1], [sentence]),
        ], bandWidth: 3000)
        #expect(merged.map(\.text) == ["one", "two", "three"], "\(merged.map(\.text))")
    }

    /// **Coverage is the union of what the runs cover, not the sum** (audit round 2). Two runs at 1800–1830 and 1810–1840,
    /// overlapping, over a runless observation at 1800–1900: they cover 40 of its 100, and counted twice they would "cover"
    /// 60 and take the observation's text with them.
    @Test func overlappingRunsAreCountedOnceWhenTheyCoverAnObservation() {
        let tiles = BandTiling.tiles(forWidth: 3000, maximum: 2000, overlap: 600)
        let observation = RecognisedLine(
            text: "the whole of it", box: CGRect(x: 800.0 / 2000, y: 0.4, width: 100.0 / 2000, height: 0.2), runs: [], confidence: 1)
        let merged = BandTiling.merged([
            (tiles[0], [Self.seen("aa", from: 1800, to: 1830, by: tiles[0]), Self.seen("bb", from: 1810, to: 1840, by: tiles[0])]),
            (tiles[1], [observation]),
        ], bandWidth: 3000)
        #expect(merged.map(\.text).contains("the whole of it"), "\(merged.map(\.text))")
    }

    /// A runless observation nothing else covers is kept — its text still belongs to the sentence — and two tiles' runless
    /// observations of one ink keep one.
    @Test func runlessObservationsAreKeptOnceWhereNothingBetterCoversThem() {
        let tiles = BandTiling.tiles(forWidth: 3000, maximum: 2000, overlap: 600)
        func bare(_ x: CGFloat, in tile: BandTile) -> RecognisedLine {
            RecognisedLine(
                text: "bare", box: CGRect(x: (x - CGFloat(tile.x)) / CGFloat(tile.width), y: 0.4, width: 50.0 / 2000, height: 0.2),
                runs: [], confidence: 1)
        }
        let alone = BandTiling.merged([(tiles[0], [bare(100, in: tiles[0])])], bandWidth: 3000)
        #expect(alone.count == 1)
        let both = BandTiling.merged([(tiles[0], [bare(1800, in: tiles[0])]), (tiles[1], [bare(1800, in: tiles[1])])], bandWidth: 3000)
        #expect(both.count == 1)
    }

    /// Positions come back in the band's own normalised space, so the pointer's cursor means what it did.
    @Test func runsAreReportedAgainstTheWholeBand() {
        let tile = BandTile(x: 1400, width: 2000)
        // a run at 0.5 of the tile is at px 1400 + 1000 = 2400 of 5120.
        let local = RecognisedLine(
            text: "word", box: CGRect(x: 0.5, y: 0.3, width: 0.1, height: 0.2),
            runs: [RecognisedRun(text: "word", utf16Offset: 0, box: CGRect(x: 0.5, y: 0.3, width: 0.1, height: 0.2))],
            confidence: 0.7)
        let merged = BandTiling.merged([(tile, [local])], bandWidth: 5120)
        let run = merged[0].runs[0]
        #expect(abs(run.box.minX - 2400.0 / 5120.0) < 1e-9)
        #expect(abs(run.box.width - 200.0 / 5120.0) < 1e-9)
        #expect(run.box.minY == 0.3 && run.box.height == 0.2, "the vertical axis is the tile's and the band's alike")
        #expect(merged[0].confidence == 0.7)
    }

    /// A fragment keeps the line's own spacing, and its runs index into the fragment's text.
    @Test func aFragmentKeepsTheLinesSpacingAndRebasesItsRuns() {
        let tile = BandTile(x: 0, width: 2000)
        let line = Self.line(["one", "two", "three"], from: 0.0, step: 0.2)
        let merged = BandTiling.merged([(tile, [line])], bandWidth: 2000)
        #expect(merged.count == 1)
        #expect(merged[0].text == "one two three")
        #expect(merged[0].runs.map(\.utf16Offset) == [0, 4, 8])
    }

    /// **Dropping a run in the middle of a line splits it into fragments, and each is rebased to its own text.**
    /// The first tile reads `aa bb cc dd`; the next reads `cc dd` further from its edge, so those two are dropped
    /// from the first and the line is what is left of it.
    @Test func droppedRunsSplitALineAndEachPartIsRebased() {
        let first = BandTile(x: 0, width: 2000)
        let second = BandTile(x: 1400, width: 2000)
        func run(_ text: String, at offset: Int, from: CGFloat, to: CGFloat, of width: CGFloat) -> RecognisedRun {
            RecognisedRun(text: text, utf16Offset: offset, box: CGRect(x: from / width, y: 0.4, width: (to - from) / width, height: 0.2))
        }
        let line = RecognisedLine(
            text: "aa bb cc dd", box: CGRect(x: 0.5, y: 0.4, width: 0.5, height: 0.2),
            runs: [run("aa", at: 0, from: 1000, to: 1080, of: 2000), run("bb", at: 3, from: 1100, to: 1180, of: 2000),
                   run("cc", at: 6, from: 1900, to: 1990, of: 2000), run("dd", at: 9, from: 1960, to: 2000, of: 2000)],
            confidence: 1)
        // The same "cc" and "dd" in band pixels 1900–1990 and 1960–2000 seen from the second tile (starting at 1400).
        let again = RecognisedLine(
            text: "cc dd", box: CGRect(x: 500.0 / 2000, y: 0.4, width: 160.0 / 2000, height: 0.2),
            runs: [run("cc", at: 0, from: 500, to: 590, of: 2000), run("dd", at: 3, from: 560, to: 600, of: 2000)],
            confidence: 1)
        let merged = BandTiling.merged([(first, [line]), (second, [again])], bandWidth: 3400)
        #expect(Self.runTexts(merged) == ["aa", "bb", "cc", "dd"], "\(Self.runTexts(merged))")
        for fragment in merged {
            #expect(fragment.runs.first?.utf16Offset == 0)
            #expect(fragment.runs.allSatisfy { run in
                (fragment.text as NSString).substring(with: NSRange(location: run.utf16Offset, length: run.text.utf16.count)) == run.text
            })
        }
    }

    // MARK: - What the band is for

    /// **The sentence survives the tiling.** One sentence laid across three tiles, the pointer in the middle one:
    /// the word read is the one pointed at and the sentence handed on is whole, not the third that one tile saw.
    @Test func aSentenceAcrossThreeTilesIsStillOneSentence() throws {
        let words = ["Serendipity", "favours", "the", "prepared", "mind", "and", "rewards", "the", "patient", "reader."]
        let bandWidth = 4800
        let tiles = BandTiling.tiles(forWidth: bandWidth, maximum: 2000, overlap: 600)
        #expect(tiles.count == 3)
        // Words are laid out evenly over the band, each 480 px apart.
        let pitch = CGFloat(bandWidth) / CGFloat(words.count)
        func tileLines(_ tile: BandTile) -> [RecognisedLine] {
            var text = ""
            var runs: [RecognisedRun] = []
            for (i, word) in words.enumerated() {
                let left = CGFloat(i) * pitch + 20, right = left + pitch - 40   // a 40 px gap: one cell of a terminal at 2x
                // Only what the tile can see whole, as Vision would.
                guard left >= CGFloat(tile.x), right <= CGFloat(tile.x + tile.width) else { continue }
                if !text.isEmpty { text += " " }
                runs.append(RecognisedRun(
                    text: word, utf16Offset: text.utf16.count,
                    box: CGRect(x: (left - CGFloat(tile.x)) / CGFloat(tile.width), y: 0.4,
                                width: (right - left) / CGFloat(tile.width), height: 0.2)))
                text += word
            }
            guard let first = runs.first, let last = runs.last else { return [] }
            return [RecognisedLine(
                text: text, box: CGRect(x: first.box.minX, y: 0.4, width: last.box.maxX - first.box.minX, height: 0.2),
                runs: runs, confidence: 1)]
        }
        let merged = BandTiling.merged(tiles.map { ($0, tileLines($0)) }, bandWidth: bandWidth)
        #expect(Self.runTexts(merged) == words, "every word once, in reading order")

        // Point at "prepared" (index 3), which sits in the middle tile.
        let cursor = CGPoint(x: (3 * pitch + pitch / 2) / CGFloat(bandWidth), y: 0.5)
        let region = CGSize(width: 2400, height: 140)
        let pick = try #require(RecognisedTextPicker.pick(at: cursor, in: merged, slack: .zero, region: region))
        let run = merged[pick.line].runs[pick.run]
        #expect(run.text == "prepared")
        let block = LineJoiner.block(around: pick.line, in: merged, region: region)
        #expect(block.text == words.joined(separator: " "), "context from all three tiles: \(block.text)")
    }
}
