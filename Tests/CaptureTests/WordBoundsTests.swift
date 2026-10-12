import CoreGraphics
import Testing

@testable import Capture

/// **The rectangle of the word a hover read, carried to the panel so the card never covers it**
/// (plan-card-refinements WI-2). Accessibility answers y down from the primary display's top-left; the panel is placed y
/// up. The flip is the one `UpPoint` makes, about the same explicit height.
struct WordBoundsTests {
    private let primaryHeight: CGFloat = 1440

    @Test func aRectIsFlippedByItsTopEdgeAboutThePrimaryHeight() {
        let read = DownRect(x: 600, y: 690, width: 80, height: 20)
        // y down 690…710 is y up 730…750.
        #expect(read.flipped(aboutPrimaryHeight: primaryHeight) == UpRect(x: 600, y: 730, width: 80, height: 20))
    }

    /// A display above the primary has negative y going down and lies above the primary going up; one to the left has
    /// negative x. Neither is clamped — both are real screen.
    @Test func negativeOriginsPassThroughUnclamped() {
        let above = DownRect(x: -1200, y: -400, width: 50, height: 18)
        #expect(above.flipped(aboutPrimaryHeight: primaryHeight) == UpRect(x: -1200, y: 1822, width: 50, height: 18))
    }

    @Test func theFlipIsItsOwnInverse() {
        let read = DownRect(x: 12, y: 300, width: 40, height: 16)
        #expect(read.flipped(aboutPrimaryHeight: primaryHeight).flipped(aboutPrimaryHeight: primaryHeight) == read)
    }

    // MARK: - What may be trusted

    private let pointer = CGPoint(x: 620, y: 700)

    @Test func aBoxUnderThePointerIsKept() {
        let kept = ReadBounds.checked(CGRect(x: 600, y: 690, width: 80, height: 20), quality: .exact, near: pointer)
        #expect(kept == ReadBounds(rect: DownRect(x: 600, y: 690, width: 80, height: 20), quality: .exact))
    }

    /// **A box that cannot be the word is no box.** An empty rect is what some views answer for any range; a box far
    /// from the pointer is another occurrence or a stale layout; a non-finite one is garbage. Each falls back to the
    /// pointer rule rather than protecting the wrong place.
    @Test func aBoxThatCannotBeTheWordIsRefused() {
        let refused: [CGRect] = [
            .zero, CGRect(x: 600, y: 690, width: 0, height: 20), CGRect(x: 600, y: 690, width: 80, height: 0),
            CGRect(x: 100, y: 100, width: 80, height: 20), .null, .infinite,
            CGRect(x: CGFloat.nan, y: 690, width: 80, height: 20),
        ]
        for box in refused {
            #expect(ReadBounds.checked(box, quality: .exact, near: pointer) == nil, "\(box) was trusted")
        }
    }

    /// **A selection's box has no pointer to be near** — the shortcut is pressed wherever the mouse happens to be — so
    /// it is checked for being a box at all, and the same garbage is refused (the owner's decision of 2026-10-09).
    @Test func aBoxWithNoPointerIsCheckedForBeingABox() {
        #expect(ReadBounds.checked(CGRect(x: 100, y: 100, width: 80, height: 20), quality: .exact)
                == ReadBounds(rect: DownRect(x: 100, y: 100, width: 80, height: 20), quality: .exact))
        for box in [CGRect.zero, CGRect(x: 1, y: 1, width: 0, height: 9), .null, .infinite,
                    CGRect(x: CGFloat.nan, y: 1, width: 9, height: 9)] {
            #expect(ReadBounds.checked(box, quality: .exact) == nil, "\(box) was trusted")
        }
    }

    /// **A box Vision gives, normalised to the capture with its origin top-left, back on the screen** — the inverse of
    /// `CaptureGeometry.normalized`, so the pixel path's run can be handed on as a box in points.
    @Test func aNormalisedBoxIsPlacedBackInTheRegion() {
        let region = CGRect(x: 200, y: 300, width: 1_000, height: 140)
        let box = CaptureGeometry.box(CGRect(x: 0.1, y: 0.25, width: 0.05, height: 0.5), in: region)
        #expect(box == CGRect(x: 300, y: 335, width: 50, height: 70))
        let corner = CaptureGeometry.normalized(CGPoint(x: box.minX, y: box.minY), in: region)
        #expect(abs(corner.x - 0.1) < 1e-9 && abs(corner.y - 0.25) < 1e-9, "not the inverse of `normalized`: \(corner)")
    }

    /// The flip keeps the quality, so the panel can tell an exact box from one that only contains the word.
    @Test func theQualityTravelsWithTheFlip() {
        let read = ReadBounds(rect: DownRect(x: 600, y: 690, width: 80, height: 20), quality: .containing)
        #expect(read.flipped(aboutPrimaryHeight: primaryHeight)
                == WordBounds(rect: UpRect(x: 600, y: 730, width: 80, height: 20), quality: .containing))
    }
}
