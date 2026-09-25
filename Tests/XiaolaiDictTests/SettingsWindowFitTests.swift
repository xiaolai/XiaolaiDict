import AppKit
import Testing

@testable import XiaolaiDictUI

/// **The settings window is resized by one thing, from outside layout, top edge pinned.**
///
/// Letting SwiftUI resize it from the panes' measured heights was measured two ways, and both were
/// wrong. Animated through a content frame, the window's *frame* tracked the pane's *content*
/// height — 88 points short, the title bar and tabs — overshot by that much, and a second movement
/// corrected it: the bottom edge shuddered on every pane change (Dictionary 785 → 580 → 668).
/// Set outright, it resized the window from inside a layout pass, which re-entered layout until
/// AppKit aborted the process. So the panes only report, and this moves the window.
@MainActor struct SettingsWindowFitTests {
    private func window(height: CGFloat) -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 580, height: height),
            styleMask: [.titled], backing: .buffered, defer: true)
    }

    /// Growing moves the bottom edge down and leaves the title bar where the reader last saw it.
    @Test func growingKeepsTheTopEdge() {
        let window = window(height: 300)
        let before = window.frame
        SettingsWindowFit.move(window, by: 120, width: 580, lowestBottom: nil, animated: false)
        #expect(window.frame.height == before.height + 120)
        #expect(window.frame.maxY == before.maxY, "the title bar moved")
        #expect(window.frame.minX == before.minX)
    }

    @Test func shrinkingKeepsTheTopEdge() {
        let window = window(height: 500)
        let before = window.frame
        SettingsWindowFit.move(window, by: -200, width: 580, lowestBottom: nil, animated: false)
        #expect(window.frame.height == before.height - 200)
        #expect(window.frame.maxY == before.maxY, "the title bar moved")
    }

    /// Less than a point is rounding, not a change of pane: moving for it would restart the
    /// animation on a window that is already where it belongs.
    @Test func lessThanAPointIsNotAMove() {
        let window = window(height: 400)
        let before = window.frame
        SettingsWindowFit.move(window, by: 0.4, width: 580, lowestBottom: nil, animated: false)
        #expect(window.frame == before)
    }

    /// Half a point either way is still rounding. `rounded()` took 0.6 to 1 and moved the window
    /// for it, which the rule above says it must not do.
    @Test func halfAPointEitherWayIsNotAMove() {
        let window = window(height: 400)
        let before = window.frame
        // Asserted after each, not after both: two wrong moves in opposite directions would
        // cancel and leave the window where it started.
        SettingsWindowFit.move(window, by: 0.6, width: 580, lowestBottom: nil, animated: false)
        #expect(window.frame == before)
        SettingsWindowFit.move(window, by: -0.6, width: 580, lowestBottom: nil, animated: false)
        #expect(window.frame == before)
    }

    /// **Growing stops at the bottom of the screen.** The top edge is pinned, so a pane taller than
    /// the room below it would push the window's bottom — and the pane's last controls — off the
    /// screen: the 700-point ceiling is the design, and it says nothing about where the reader left
    /// the window. Capped, the pane scrolls inside the window instead.
    @Test func growingStopsAtTheBottomOfTheScreen() {
        let window = window(height: 300)
        let before = window.frame
        let floor = before.minY - 50
        SettingsWindowFit.move(window, by: 400, width: 580, lowestBottom: floor, animated: false)
        #expect(window.frame.minY == floor, "the bottom edge went to \(window.frame.minY), below \(floor)")
        #expect(window.frame.maxY == before.maxY, "the title bar moved")
    }

    /// And shrinking is never held up by it — a window already below the floor may still get
    /// smaller, which only brings its bottom back up.
    @Test func shrinkingIgnoresTheBottomOfTheScreen() {
        let window = window(height: 500)
        let before = window.frame
        SettingsWindowFit.move(window, by: -200, width: 580, lowestBottom: before.minY + 400, animated: false)
        #expect(window.frame.height == before.height - 200)
        #expect(window.frame.maxY == before.maxY)
    }

    /// The difference, not the target: what the pane wants against what its scroll view was
    /// given. Both are the scroll view's own numbers, so the window's chrome — whatever AppKit
    /// counts as content under a toolbar — cannot be miscounted, which is the error that shook it.
    @Test func theMoveIsWhatThePaneIsShortBy() {
        #expect(SettingsWindowFit.shortfall(wanted: 533, given: 362) == 171)
        #expect(SettingsWindowFit.shortfall(wanted: 306, given: 580) == -274)
    }

    /// **A scroll view not yet given a height has not said anything.** It is laid out at zero
    /// before its window has a size, and fitting against that zero grew the first pane by its whole
    /// height: measured, Reading opened at 891 points for 533 of content.
    @Test func aPaneNotYetLaidOutAsksForNothing() {
        #expect(SettingsWindowFit.shortfall(wanted: 533, given: 0) == nil)
    }

    /// The window is the panes' width, whatever SwiftUI opened it at — measured at its own default
    /// of 900, with the 580-point panes adrift inside it.
    @Test func theWidthIsThePanes() {
        let window = window(height: 400)
        window.setFrame(NSRect(x: 100, y: 200, width: 900, height: 400), display: false)
        SettingsWindowFit.move(window, by: 0, width: 580, lowestBottom: nil, animated: false)
        #expect(window.frame.width == 580)
        #expect(window.frame.height == 400)
    }
}

/// **The lookup panel is the third surface to meet "a window does not take its content's height",
/// and the first where the content was never the problem.**
///
/// `PanelHeightTests` measures the hosted view's `fittingSize` at 267 pt for a one-line sentence and
/// 405 for a long one, capped — so the view reports what it wants perfectly well. The window did not
/// take it: `LookupPanelController.show` sets the frame to `Token.Panel.cardOpeningHeight`, 240, on
/// open **and again on every reuse**, and a frame set by hand is not a frame SwiftUI will revisit.
/// Measured on this Mac 2026-09-25 by `--panel-report`, three runs, three different cards: 398 × 240
/// every time, with the footer — the dictionary control, translate, explain, copy and pin — below a
/// fold the panel gives no sign of having.
///
/// The fit is bounded by the same cap the scrolling region has, because past it the answer is to
/// scroll rather than to grow: a window taller than the cap would be a window with empty space in it.
@MainActor
struct PanelFitTests {
    /// Growing: the content wants more than the window gives, and the shortfall is the difference.
    @Test func aWindowShorterThanItsContentGrowsByTheDifference() {
        #expect(SettingsWindowFit.shortfall(wanted: 405, given: 240, ceiling: 500) == 165)
    }

    /// **Shrinking, which is the half a cap alone never covers.** A two-line answer must not be
    /// padded out to the opening height — that is the same defect wearing the other sign.
    @Test func aWindowTallerThanItsContentShrinks() {
        #expect(SettingsWindowFit.shortfall(wanted: 180, given: 240, ceiling: 500) == -60)
    }

    /// **Growth stops at the ceiling.** Past it the scrolling region is capped, so a taller window
    /// would hold empty space under the content — and the reader would have a window that grew for
    /// nothing rather than a list that scrolls.
    @Test func growthStopsAtTheCeiling() {
        #expect(SettingsWindowFit.shortfall(wanted: 900, given: 240, ceiling: 384) == 144)
        #expect(SettingsWindowFit.shortfall(wanted: 900, given: 384, ceiling: 384) == 0)
    }

    /// **It settles.** The window is resized, which changes what the content is given, which is read
    /// again — so a fit that never reached zero would resize for ever. Applying it to its own answer
    /// twice must reach nothing left to do.
    @Test func theFitIsAFixedPoint() throws {
        var given: CGFloat = 240
        let wanted: CGFloat = 405, ceiling: CGFloat = 384
        for _ in 0..<5 {
            let delta = try #require(SettingsWindowFit.shortfall(wanted: wanted, given: given, ceiling: ceiling))
            given += delta
        }
        #expect(SettingsWindowFit.shortfall(wanted: wanted, given: given, ceiling: ceiling) == 0)
        #expect(given == ceiling)
    }

    /// A ceiling of nil is the settings window's case — no ceiling but the screen's, which `move`
    /// applies rather than this.
    @Test func withNoCeilingTheContentDecidesAlone() {
        #expect(SettingsWindowFit.shortfall(wanted: 900, given: 240, ceiling: nil) == 660)
    }

    /// Still nil while the scroll view has not been given a height: fitting against that zero grew
    /// the first pane by its whole height, measured.
    @Test func nothingIsFittedBeforeTheContainerHasASize() {
        #expect(SettingsWindowFit.shortfall(wanted: 405, given: 0, ceiling: 384) == nil)
    }
}
