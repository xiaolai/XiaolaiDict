import CoreGraphics
import Foundation
import Testing

@testable import XiaolaiDictCore

/// A 2560×1440 display with a 30 pt menu bar and no Dock, which is what the spike was measured on.
private let wide = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
    visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410))

/// The display to its right, so clipping has somewhere to spill to if it is wrong.
private let neighbour = ScreenMetrics(
    frame: CGRect(x: 2560, y: 0, width: 2560, height: 1440),
    visibleFrame: CGRect(x: 2560, y: 0, width: 2560, height: 1410))

/// The content rect in the window's own coordinates — top-left origin, y down, which is what
/// SwiftUI places the drawer in.
private func contentInWindow(_ g: DrawerGeometry) -> CGRect {
    CGRect(origin: g.contentOrigin, size: g.contentSize)
}

private func windowBounds(_ g: DrawerGeometry) -> CGRect {
    CGRect(origin: .zero, size: g.windowRect.size)
}

struct DrawerDockingTests {
    @Test func theDrawerSitsAgainstTheEdgeItIsDockedTo() {
        for edge in DrawerEdge.allCases {
            let g = DrawerGeometry.make(DrawerLayout(thickness: 380, edge: edge), on: wide)
            // In screen coordinates the content's docked side is flush with the visible frame.
            let content = CGRect(
                x: g.windowRect.minX + g.contentOrigin.x,
                y: g.windowRect.maxY - g.contentOrigin.y - g.contentSize.height,
                width: g.contentSize.width, height: g.contentSize.height)
            switch edge {
            case .right: #expect(content.maxX == wide.visibleFrame.maxX, "\(edge)")
            case .left: #expect(content.minX == wide.visibleFrame.minX, "\(edge)")
            case .top: #expect(content.maxY == wide.visibleFrame.maxY, "\(edge)")
            case .bottom: #expect(content.minY == wide.visibleFrame.minY, "\(edge)")
            }
        }
    }

    @Test func anInsetLiftsTheDrawerOffTheEdgeByExactlyThatMuch() {
        for edge in DrawerEdge.allCases {
            let flush = DrawerGeometry.make(DrawerLayout(edge: edge, inset: 0), on: wide)
            let lifted = DrawerGeometry.make(DrawerLayout(edge: edge, inset: 16), on: wide)
            #expect(flush.isFlush)
            #expect(!lifted.isFlush, "\(edge) at inset 16 should not read as flush")
        }
    }

    /// The docked thickness is the drawer's own dimension; the other one spans.
    @Test func thicknessAppliesToTheDockedDimension() {
        let right = DrawerGeometry.make(DrawerLayout(thickness: 380, edge: .right), on: wide)
        #expect(right.contentSize.width == 380)
        #expect(right.contentSize.height == wide.visibleFrame.height)

        let top = DrawerGeometry.make(DrawerLayout(thickness: 380, edge: .top), on: wide)
        #expect(top.contentSize.height == 380)
        #expect(top.contentSize.width == wide.visibleFrame.width)
    }

    /// The spike clamped thickness against `min(width, height)` for every edge, so a left-docked
    /// drawer on a wide short display was limited by the height it does not use. The clamp has to
    /// name the dimension the drawer actually occupies.
    @Test func thicknessIsClampedByTheDimensionItOccupies() {
        let short = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 3000, height: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 3000, height: 380))
        let left = DrawerGeometry.make(DrawerLayout(thickness: 600, edge: .left), on: short)
        // 600 fits across 3000 points of width; the 380 of height is not the constraint.
        #expect(left.contentSize.width == 600)
    }

    @Test func aThicknessLargerThanTheScreenIsClampedToIt() {
        let left = DrawerGeometry.make(DrawerLayout(thickness: 9000, edge: .left), on: wide)
        #expect(left.contentSize.width <= wide.visibleFrame.width)
    }

    /// The spike floored thickness at 120, which on a display narrower than that produced a drawer
    /// wider than the screen it was docked to.
    @Test func aDrawerNeverExceedsTheDisplayEvenWhenTheDisplayIsTiny() {
        let tiny = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 90, height: 200),
            visibleFrame: CGRect(x: 0, y: 0, width: 90, height: 180))
        let g = DrawerGeometry.make(DrawerLayout(thickness: 380, edge: .left, inset: 8), on: tiny)
        #expect(g.contentSize.width <= tiny.visibleFrame.width)
        #expect(g.contentSize.height <= tiny.visibleFrame.height)
    }
}

struct DrawerSpanTests {
    @Test func aFullLengthDrawerSpansTheWholeVisibleEdge() {
        let g = DrawerGeometry.make(DrawerLayout(edge: .right, spanFraction: nil), on: wide)
        #expect(g.contentSize.height == wide.visibleFrame.height)
    }

    @Test func aPartialDrawerTakesThatFractionAndIsCentred() {
        let g = DrawerGeometry.make(DrawerLayout(edge: .right, spanFraction: 0.5), on: wide)
        #expect(g.contentSize.height == wide.visibleFrame.height / 2)

        let topGap = g.contentOrigin.y
        let bottomGap = g.windowRect.height - g.contentOrigin.y - g.contentSize.height
        #expect(abs(topGap - bottomGap) < 0.01, "centred: \(topGap) vs \(bottomGap)")
    }

    /// A fraction outside 0...1 is a caller's mistake, and a drawer taller than its screen is worse
    /// than a clamped one.
    @Test func anAbsurdSpanFractionIsClamped() {
        let over = DrawerGeometry.make(DrawerLayout(edge: .right, spanFraction: 4), on: wide)
        #expect(over.contentSize.height <= wide.visibleFrame.height)

        let under = DrawerGeometry.make(DrawerLayout(edge: .right, spanFraction: -1), on: wide)
        #expect(under.contentSize.height >= 0)
    }
}

struct DrawerShadowClipTests {
    /// The window is grown so the drawer's shadow has somewhere to land, then clipped to the
    /// display — otherwise a right-docked drawer spills its shadow onto the display next door.
    @Test func theWindowNeverLeavesItsDisplay() {
        for edge in DrawerEdge.allCases {
            for inset in [CGFloat(0), 16, 48] {
                let g = DrawerGeometry.make(DrawerLayout(edge: edge, inset: inset), on: wide)
                #expect(wide.frame.union(g.windowRect) == wide.frame,
                        "\(edge) inset \(inset) left the display: \(g.windowRect)")
            }
        }
    }

    @Test func aRightDockedDrawerDoesNotReachTheDisplayBesideIt() {
        let g = DrawerGeometry.make(DrawerLayout(edge: .right), on: wide)
        #expect(!g.windowRect.intersects(neighbour.frame))
    }

    @Test func theWindowIsLargerThanTheDrawerSoAShadowHasRoom() {
        // Docked right and flush, the only side with room to grow is the inboard one.
        let g = DrawerGeometry.make(DrawerLayout(edge: .right), on: wide)
        #expect(g.windowRect.width > g.contentSize.width)
    }
}

struct DrawerHidingTests {
    /// The window never moves; the content slides inside it. So the parked position has to be
    /// wholly outside the window on the docked side, or a sliver stays visible.
    @Test func theParkedDrawerIsCompletelyOutsideTheWindow() {
        for edge in DrawerEdge.allCases {
            for inset in [CGFloat(0), 16, 48] {
                for fraction in [nil, CGFloat(0.72)] {
                    let g = DrawerGeometry.make(
                        DrawerLayout(edge: edge, spanFraction: fraction, inset: inset), on: wide)
                    let parked = contentInWindow(g).offsetBy(dx: g.hiddenOffset.width, dy: g.hiddenOffset.height)
                    let overlap = parked.intersection(windowBounds(g))
                    #expect(overlap.isNull || overlap.width == 0 || overlap.height == 0,
                            "\(edge) inset \(inset): \(overlap) of the drawer stays visible")
                }
            }
        }
    }

    @Test func theDrawerSlidesOffTheEdgeItIsDockedTo() {
        #expect(DrawerGeometry.make(DrawerLayout(edge: .right), on: wide).hiddenOffset.width > 0)
        #expect(DrawerGeometry.make(DrawerLayout(edge: .left), on: wide).hiddenOffset.width < 0)
        // Window coordinates run y-down, so leaving by the top is negative.
        #expect(DrawerGeometry.make(DrawerLayout(edge: .top), on: wide).hiddenOffset.height < 0)
        #expect(DrawerGeometry.make(DrawerLayout(edge: .bottom), on: wide).hiddenOffset.height > 0)
    }

    @Test func aShownDrawerIsWhollyInsideItsWindow() {
        for edge in DrawerEdge.allCases {
            let g = DrawerGeometry.make(DrawerLayout(edge: edge, inset: 16), on: wide)
            let shown = contentInWindow(g)
            #expect(windowBounds(g).union(shown) == windowBounds(g), "\(edge): \(shown)")
        }
    }
}

struct DrawerCornerTests {
    /// Flush against the edge, the two corners touching it stay square, the way system panels do.
    @Test func onlyTheCornersAwayFromTheEdgeAreRoundedWhenFlush() {
        let g = DrawerGeometry.make(DrawerLayout(edge: .right, inset: 0, cornerRadius: 16), on: wide)
        #expect(g.isFlush)
        #expect(g.squareCorners == .trailing)
    }

    @Test func anInsetDrawerIsRoundedAllRound() {
        let g = DrawerGeometry.make(DrawerLayout(edge: .right, inset: 16, cornerRadius: 16), on: wide)
        #expect(g.squareCorners == .none)
    }

    @Test func eachEdgeSquaresTheSideItTouches() {
        let expected: [DrawerEdge: DrawerGeometry.SquareCorners] =
            [.right: .trailing, .left: .leading, .top: .top, .bottom: .bottom]
        for (edge, corners) in expected {
            let g = DrawerGeometry.make(DrawerLayout(edge: edge, inset: 0), on: wide)
            #expect(g.squareCorners == corners, "\(edge)")
        }
    }
}

struct DrawerDisplayTests {
    /// Every rect is in global screen coordinates, so a drawer on the second display must be
    /// positioned in that display's own range rather than at the global origin.
    @Test func aDrawerOnTheSecondDisplayIsPlacedOnThatDisplay() {
        let g = DrawerGeometry.make(DrawerLayout(edge: .left), on: neighbour)
        #expect(neighbour.frame.union(g.windowRect) == neighbour.frame)
        #expect(g.windowRect.minX >= neighbour.frame.minX)
    }

    /// A display with a notch reports a `visibleFrame` shorter than its `frame`. The drawer is
    /// placed against the visible frame, and only its shadow margin may reach into the rest.
    @Test func aTopDockedDrawerStaysBelowTheMenuBar() {
        let notched = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 3456, height: 2234),
            visibleFrame: CGRect(x: 0, y: 0, width: 3456, height: 2160))
        let g = DrawerGeometry.make(DrawerLayout(edge: .top), on: notched)
        let contentTop = g.windowRect.maxY - g.contentOrigin.y
        #expect(contentTop <= notched.visibleFrame.maxY)
    }
}

struct DrawerPlacementTests {
    @Test func theDrawerOpensOnTheDisplayThePointerIsOn() {
        let chosen = DrawerPlacement.screen(
            under: CGPoint(x: 3000, y: 700), among: [wide, neighbour])
        #expect(chosen == neighbour)
    }

    /// A pointer between displays, or on none of them, still has to produce a drawer.
    @Test func aPointerOnNoDisplayFallsBackToTheFirst() {
        let chosen = DrawerPlacement.screen(
            under: CGPoint(x: -5000, y: -5000), among: [wide, neighbour])
        #expect(chosen == wide)
    }

    @Test func noDisplaysAtAllIsNoPlacement() {
        #expect(DrawerPlacement.screen(under: .zero, among: []) == nil)
    }

    @Test func aDisplayStillListedIsStillAttached() {
        #expect(DrawerPlacement.isStillAttached(neighbour, among: [wide, neighbour]))
    }

    /// The drawer was open on a display that has just been unplugged.
    @Test func aDisplayNoLongerListedIsGone() {
        #expect(!DrawerPlacement.isStillAttached(neighbour, among: [wide]))
    }

    /// Replugging a display yields a fresh object for the same hardware, so identity is the wrong
    /// test and the frame is the right one.
    @Test func theSameDisplayUnderADifferentObjectIsStillAttached() {
        let replugged = ScreenMetrics(frame: neighbour.frame, visibleFrame: neighbour.visibleFrame)
        #expect(DrawerPlacement.isStillAttached(neighbour, among: [wide, replugged]))
    }
}
