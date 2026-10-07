import CoreGraphics
import Foundation
import Testing
@testable import Capture

/// **A capture with no size joins nothing.**
///
/// `sameRow` multiplies both sides of its comparison by the region, so a `.zero` region compared `0 <= 0`
/// and answered *true* for every pair of boxes that shared a horizontal band — the whole page as one row.
/// Nothing could reach it, because `block(around:in:region:)` has a `precondition` against a degenerate
/// region and the live path cannot produce one. That made a loud guard load-bearing for a silent wrong
/// answer in a different function; the guard stays, and this is what makes removing it a *split* row
/// rather than a merged page — ADR-0042.
struct DegenerateRegionTests {
    private let left = CGRect(x: 0.0, y: 0.5, width: 0.1, height: 0.02)
    /// Far to the right on the same line: a second column, or the other pane of a split terminal.
    private let farRight = CGRect(x: 0.8, y: 0.5, width: 0.1, height: 0.02)

    @Test func azeroRegionJoinsNothing() {
        #expect(!LineJoiner.sameRow(left, farRight, .zero))
        #expect(!LineJoiner.sameRow(left, left, .zero), "a box was in the same row as itself with no region")
        #expect(!LineJoiner.sameRow(left, farRight, CGSize(width: 1000, height: 0)))
        #expect(!LineJoiner.sameRow(left, farRight, CGSize(width: 0, height: 1000)))
    }

    /// The positive control. Without it the checks above would pass on a rule that joined nothing ever.
    @Test func aneighbourOnTheSameLineStillJoinsWithArealRegion() {
        let beside = CGRect(x: 0.105, y: 0.5, width: 0.1, height: 0.02)
        #expect(LineJoiner.sameRow(left, beside, CGSize(width: 1000, height: 1000)))
        #expect(!LineJoiner.sameRow(left, farRight, CGSize(width: 1000, height: 1000)),
                "the other pane of a split terminal joined the reader's line")
    }
}

/// **A size-less capture is answered, not fatal.** `block(around:in:region:)` had a `precondition`, on
/// the reasoning that a `.zero` fallback was silently wrong — which was true while `sameRow` answered
/// `true` for everything. With `sameRow` refusing it, the fallback is the seed line alone: under-joined,
/// which this file calls the safe direction, and said in the log — ADR-0042.
struct BlockWithNoRegionTests {
    private func line(_ text: String, x: CGFloat, y: CGFloat) -> RecognisedLine {
        let box = CGRect(x: x, y: y, width: 0.1, height: 0.02)
        return RecognisedLine(
            text: text, box: box,
            runs: [RecognisedRun(text: text, utf16Offset: 0, box: box)])
    }

    @Test func azeroRegionGivesTheSeedLineAloneRatherThanEndingTheProcess() {
        let lines = [line("first", x: 0.0, y: 0.50), line("second", x: 0.105, y: 0.50)]
        let block = LineJoiner.block(around: 0, in: lines, region: .zero)
        #expect(block.lineIndices == [0], "a size-less capture joined lines it cannot compare")
        #expect(block.text == "first")
    }

    /// The positive control: with a real region the same two lines do join, so the check above is about
    /// the region and not about these two lines never joining.
    @Test func arealRegionJoinsTheSameTwoLines() {
        let lines = [line("first", x: 0.0, y: 0.50), line("second", x: 0.105, y: 0.50)]
        let block = LineJoiner.block(around: 0, in: lines, region: CGSize(width: 1000, height: 1000))
        #expect(block.lineIndices == [0, 1])
    }
}
