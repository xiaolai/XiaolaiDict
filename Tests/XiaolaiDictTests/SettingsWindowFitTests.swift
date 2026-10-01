import AppKit
import SwiftUI
import Testing

@testable import XiaolaiDict
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

    /// **A whole point is rounding too, and this is the instance that cost a red gate.** A pane's
    /// first scroll geometry after the content swaps reported its content one point off its
    /// container; the window moved down a point and straight back up, and `--settings-report` read
    /// that as a shudder — one reversal, one point of overshoot, going to the Reading pane.
    @Test func aWholePointIsNotAMove() {
        let window = window(height: 400)
        let before = window.frame
        SettingsWindowFit.move(window, by: 1, width: 580, lowestBottom: nil, animated: false)
        #expect(window.frame == before)
        SettingsWindowFit.move(window, by: -1, width: 580, lowestBottom: nil, animated: false)
        #expect(window.frame == before)
    }

    /// **The positive control.** Every assertion above is satisfied by a `move` that does nothing at
    /// all, so one of them has to be a move that lands — otherwise raising the guard would read as
    /// four rules holding rather than as the window having stopped resizing.
    @Test func justOverAPointIsAMove() {
        let window = window(height: 400)
        let before = window.frame
        SettingsWindowFit.move(window, by: 2, width: 580, lowestBottom: nil, animated: false)
        #expect(window.frame.height == before.height + 2)
    }

    /// **The mover's threshold must sit above the instrument's noise floor, never on it.**
    ///
    /// `FrameTrajectory` counts a change of a whole point as a movement, and `move` admitted a
    /// delta of a whole point — so the smallest move the window would make was exactly the
    /// smallest the instrument would call a shudder, and whether the gate went red depended on
    /// where a layout rounded. Measured 2026-10-01: the same bundle, the same four pane heights,
    /// failed once and passed on the next run.
    ///
    /// Written as the relationship rather than as two numbers, because either one moving on its own
    /// is what put them level in the first place.
    @Test func theWindowNeverMovesAtTheInstrumentsNoiseFloor() {
        #expect(FrameTrajectory.noise <= SettingsWindowFit.rounding,
                "the instrument sees less than the window moves for, so a move is invisible to it")
        let window = window(height: 400)
        let before = window.frame
        SettingsWindowFit.move(
            window, by: FrameTrajectory.noise, width: 580, lowestBottom: nil, animated: false)
        #expect(window.frame == before,
                "the window moves by exactly what the instrument calls the smallest movement")
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

/// **What a pane wants is its content, and what it has is its container — the toolbar is in
/// neither.**
///
/// Measured 2026-10-02 in a `Settings` scene with toolbar tabs: a three-row grouped form in a
/// 450-point window reported `contentSize` 176, `contentInsets.top` 88 and `containerSize` 362.
/// The container is already the room below the title bar and tabs. Adding the inset to what the
/// pane wanted counted the chrome on one side only, and every pane that did not scroll ended in
/// 88 points of empty window.
@MainActor
struct ContentFitTests {
    private func geometry(content: CGFloat, topInset: CGFloat, container: CGFloat) -> ScrollGeometry {
        ScrollGeometry(
            contentOffset: CGPoint(x: 0, y: -topInset),
            contentSize: CGSize(width: 580, height: content),
            contentInsets: EdgeInsets(top: topInset, leading: 0, bottom: 0, trailing: 0),
            containerSize: CGSize(width: 580, height: container))
    }

    /// The measured numbers. With the inset counted, `wanted` was 264 and the window settled 88
    /// points taller than its pane.
    @Test func theToolbarsInsetIsNotPartOfWhatThePaneWants() {
        let fit = ContentFit(of: geometry(content: 176, topInset: 88, container: 362))
        #expect(fit.wanted == 176)
        #expect(fit.given == 362)
        #expect(SettingsWindowFit.shortfall(wanted: fit.wanted, given: fit.given) == -186)
    }

    /// **A window that fits its pane asks for nothing more.** This is the dead band stated as a
    /// fixed point: content 176 in a container of 176 is finished, with the toolbar's 88 points
    /// reported or not.
    @Test func aPaneThatFitsItsContainerIsAtRest() {
        let fit = ContentFit(of: geometry(content: 176, topInset: 88, container: 176))
        #expect(SettingsWindowFit.shortfall(wanted: fit.wanted, given: fit.given) == 0)
    }

    /// **The inset arriving late must not change the answer.** The same scroll view reports twice
    /// as it settles — first with no inset, then with 88 — so a fit that counted it saw one pane
    /// want two heights, 88 apart, which is the size of the old shudder.
    @Test func theInsetArrivingDoesNotMoveTheTarget() {
        let before = ContentFit(of: geometry(content: 509, topInset: 0, container: 362))
        let after = ContentFit(of: geometry(content: 509, topInset: 88, container: 362))
        #expect(before == after)
    }
}

/// **Reduce Motion makes the pane resize a jump.**
@MainActor
struct SettingsWindowMotionTests {
    private func window() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 580, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true)
    }

    /// Asked to animate with the setting on, the frame is where it is going when `move` returns —
    /// an animated resize has only begun by then.
    @Test func withReduceMotionTheWindowArrivesAtOnce() {
        let window = window()
        let before = window.frame
        SettingsWindowFit.move(
            window, by: 120, width: 580, lowestBottom: nil, animated: true, reduceMotion: true)
        #expect(window.frame.height == before.height + 120)
        #expect(window.frame.maxY == before.maxY)
    }

    /// And the source reads the setting where the animation is decided, so no caller can forget.
    @Test func theMoveReadsTheSettingItself() throws {
        let fit = try SettingsSources.code("SettingsWindowFit.swift")
        #expect(fit.contains("reduceMotion: Bool = MotionPreference.systemReduceMotion"))
        #expect(fit.contains("guard animated, !reduceMotion else {"))
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
