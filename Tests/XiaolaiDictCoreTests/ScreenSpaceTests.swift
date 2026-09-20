import CoreGraphics
import Testing

@testable import XiaolaiDictCore

/// The two screen spaces, and the one conversion between them.
///
/// AppKit's is y up from the bottom-left of the primary display; Accessibility's and CGEvent's is
/// y down from its top-left. Both were bare `CGPoint` until `UpPoint` separated them, and the
/// mistake showed as a plausible position rather than an error — which is why the flip is a named
/// operation taking an explicit reference height rather than a global assumption.
struct ScreenSpaceTests {
    /// The primary display: 2560×1440, origin at the global origin.
    private let primaryHeight: CGFloat = 1440

    @Test func theTopOfThePrimaryDisplayIsZeroGoingDown() {
        let top = UpPoint(x: 100, y: 1440)
        #expect(top.flipped(aboutPrimaryHeight: primaryHeight) == DownPoint(x: 100, y: 0))
    }

    @Test func theBottomOfThePrimaryDisplayIsItsHeightGoingDown() {
        let bottom = UpPoint(x: 100, y: 0)
        #expect(bottom.flipped(aboutPrimaryHeight: primaryHeight) == DownPoint(x: 100, y: 1440))
    }

    @Test func theFlipLeavesTheHorizontalAlone() {
        let far = UpPoint(x: 4820, y: 700)
        #expect(far.flipped(aboutPrimaryHeight: primaryHeight).cg.x == 4820)
    }

    /// A display stacked above the primary has y-up values past the primary's height, which are
    /// negative in the y-down space. That is correct, not an error to clamp away: CGEvent's origin
    /// is the primary's top-left, and there is screen above it.
    @Test func aDisplayAboveThePrimaryHasNegativeDownwardCoordinates() {
        let above = UpPoint(x: 200, y: 2000)
        #expect(above.flipped(aboutPrimaryHeight: primaryHeight) == DownPoint(x: 200, y: -560))
    }

    @Test func aDisplayBelowThePrimaryIsPastItsHeightGoingDown() {
        let below = UpPoint(x: 200, y: -300)
        #expect(below.flipped(aboutPrimaryHeight: primaryHeight) == DownPoint(x: 200, y: 1740))
    }

    /// The flip is its own inverse about the same height, so a value that makes a round trip is
    /// unchanged. A conversion that lost a point per hop would drift the longer hover ran.
    @Test func flippingTwiceAboutTheSameHeightChangesNothing() {
        for y in [CGFloat(0), 1, 719.5, 1440, 2000, -300] {
            let start = UpPoint(x: 37, y: y)
            let there = start.flipped(aboutPrimaryHeight: primaryHeight)
            #expect(there.flipped(aboutPrimaryHeight: primaryHeight) == start, "y = \(y)")
        }
    }

    /// The reference height is a parameter because the right one depends on the arrangement. A
    /// caller that passes a different height gets a different answer, and that is the point: the
    /// type will not pick one for it.
    @Test func theReferenceHeightIsTheCallersToChoose() {
        let point = UpPoint(x: 0, y: 100)
        #expect(point.flipped(aboutPrimaryHeight: 1440) != point.flipped(aboutPrimaryHeight: 1080))
    }
}
