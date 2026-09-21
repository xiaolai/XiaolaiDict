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
