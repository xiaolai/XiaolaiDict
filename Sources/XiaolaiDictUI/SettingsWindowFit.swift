import AppKit
import SwiftUI

/// Resizes the settings window to the pane it is showing — **the one thing that does**, from
/// outside layout, with the title bar held where the reader last saw it.
///
/// Two ways of letting SwiftUI do it were measured and both were wrong. Animated through a content
/// frame, the window's *frame* followed the pane's *content* height, 88 points short — the title bar
/// and tabs — so it overshot by exactly that and a second movement pulled it back: the bottom edge
/// shuddered on every pane change (Dictionary went 785 → 580 → 668). Set outright, the resize
/// happened inside a layout pass, which re-entered layout until AppKit aborted the process with
/// "needing another Update Constraints in Window pass". The panes now only report how tall they
/// want to be, and this moves the window — TYPE's arrangement, arrived at from the same two faults.
@MainActor
enum SettingsWindowFit {
    /// **A change this small is rounding, and nothing moves for it.**
    ///
    /// A pane's first scroll geometry after the content swaps can report its content a single point
    /// off its container, which is the scroll view rounding rather than a pane asking for room.
    /// Acting on it moved the window a point and straight back — measured 2026-10-01 going to the
    /// Reading pane, 710 → 709 → 788 — which `--settings-report` correctly calls a shudder: one
    /// reversal, one point of overshoot.
    ///
    /// **The number has to sit below the instrument's noise floor, not on it.** `FrameTrajectory`
    /// counts a change of a whole point as a movement, so while this guard admitted one too, the
    /// smallest move the window would make was exactly the smallest the instrument would report —
    /// and whether the gate went red depended on where a layout happened to round. The same bundle
    /// failed once and passed on the next run. `theWindowNeverMovesAtTheInstrumentsNoiseFloor`
    /// holds the two apart.
    static let rounding: CGFloat = 1

    /// How far the window has to move for a pane to fit: what the pane wants against what its
    /// scroll view was given. **Both are the scroll view's own numbers**, so whatever AppKit counts
    /// as content under a toolbar cancels out — the chrome is never counted, and so never
    /// miscounted, which is the error that made the window overshoot.
    ///
    /// Nil while the scroll view has not been given a height at all: it is laid out at zero before
    /// its window has a size, and fitting against that zero grew the first pane by its whole height
    /// — measured, Reading opened at 891 points for 533 of content.
    ///
    /// **`ceiling` is where growing stops and scrolling takes over.** The lookup panel bounds its
    /// scrolling region at `cardMaxHeight`, so a window taller than that would hold empty space under
    /// the content: the reader would get a window that grew for nothing instead of a list that
    /// scrolls. Nil for a surface with no ceiling of its own — the settings window and the setup
    /// board are bounded by the screen instead, which `move` applies.
    ///
    /// Shrinking is never bounded by it. A ceiling is a limit on growth; applied to a shrink it
    /// would pad a two-line answer out to the cap, which is this same defect wearing the other sign.
    static func shortfall(wanted: CGFloat, given: CGFloat, ceiling: CGFloat? = nil) -> CGFloat? {
        guard given > 0 else { return nil }
        return min(wanted, ceiling ?? wanted) - given
    }

    /// Grows or shrinks the window by `delta`, keeping its top edge, at the panes' `width`. A
    /// settings window grows down from its title bar; one that kept its bottom edge would walk up
    /// the screen on every click.
    ///
    /// **Growth stops at `lowestBottom`** — the bottom of the screen's usable area. The top edge is
    /// pinned, so a pane taller than the room below it would push the window's bottom, and the
    /// pane's last controls, off the screen: the 700-point ceiling is the design and says nothing
    /// about where the reader left the window. Capped, the pane scrolls inside the window instead.
    /// Shrinking is never held up by it, and asking to grow never makes the window smaller.
    /// `recentres` is for a window **SwiftUI placed at a default width of its own**; a window its
    /// owner placed deliberately must keep where it was put. The lookup panel goes below and to the
    /// right of the pointer, and centring it on a width change would throw that away — the reader
    /// pointed at a word and the answer would appear in the middle of the screen.
    /// **`width` is nil for a window whose width is already right.** The lookup panel's is sized from
    /// its content by the scene — measured at 398 for a 396-point card — and correctly so; only its
    /// height is not. Passing a width there would mean deriving the window's width from the card's
    /// plus the shadow padding, which is a number to keep in step for no gain.
    static func move(
        _ window: NSWindow, by delta: CGFloat, width: CGFloat?, lowestBottom: CGFloat?,
        animated: Bool, recentres: Bool = true
    ) {
        let current = window.frame
        let width = width ?? current.width
        var height = current.height + delta
        if let lowestBottom, delta > 0 {
            height = max(current.height, min(height, current.maxY - lowestBottom))
        }
        let widthChange = width - current.width
        // More than a point: a point or less is rounding, and moving for it would restart the
        // animation on a window already where it belongs — and put a reversal in front of the
        // instrument that watches for one. `rounded()` took half a point to one, so this does not
        // use it.
        guard abs(height - current.height) > rounding || abs(widthChange) > rounding else { return }
        var frame = current
        frame.size = CGSize(width: width, height: height)
        frame.origin.y = current.maxY - height
        guard animated else {
            window.setFrame(frame, display: true)
            // SwiftUI opened the window at a default width of its own — measured at 900 — and
            // placed it for that width. Narrowed where it stands, it would sit off to one side, so
            // it goes where a newly opened window goes. Only then: a window already at the panes'
            // width was placed by the reader, and stays where they put it.
            if recentres, abs(widthChange) > rounding { window.center() }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Token.Motion.paneResize
            context.timingFunction = Token.Motion.paneResizeCurve
            window.animator().setFrame(frame, display: true)
        }
    }
}

/// **A window that is as tall as the scrolling content it shows.**
///
/// A grouped `Form` is a scroll view, so it offers its window no height of its own and SwiftUI
/// opens the window at a default — 450 points, whatever the form holds. Measured 2026-09-23 on the
/// setup board of a Mac with no model downloaded: 933 points of content in a window ending at 800,
/// with the model row's **Download** and **Not now** below the fold. That row is what the board
/// exists to act on, and a reader who does not think to scroll never sees it. It is the same defect
/// the settings window had — "every pane at 450, SwiftUI's default" — and this is the same
/// arrangement that fixed it, reduced to the single-pane case: the content reports what it wants
/// and what it was given, and the window moves by the difference, outside the layout pass.
private struct FitsItsContent: ViewModifier {
    let width: CGFloat?
    /// Where growing stops and scrolling takes over, for a surface that bounds its own scrolling
    /// region. Nil where the screen is the only ceiling.
    var ceiling: CGFloat?
    /// **Animated for a window the reader is looking at while it changes** — a settings pane they
    /// clicked to. Not for one that is filling in: the lookup panel is shown before the dictionaries
    /// answer and grows as the entry, the memory and the sense arrive, so an animation per arrival
    /// would draw the eye to the latency rather than to the answer, and each would restart the last.
    /// It is also why the history drawer never animates its window: animating a frame relayouts the
    /// whole hierarchy every frame.
    var animates = true
    var recentres = true
    /// **What the fit saw, for the instrument that measures it.** The window's height is observable
    /// from outside; the two numbers it was computed from are not, and without them a window that is
    /// the wrong size cannot be told from one that was asked for the wrong size. Nil everywhere but
    /// the lookup panel, which is the surface `--panel-report` measures.
    var report: ((CGFloat, CGFloat) -> Void)?
    @State private var window: NSWindow?
    /// **The newest fit, in a box, and one move in flight at a time.**
    ///
    /// A value in `@State` is a snapshot: the closure handed to `DispatchQueue.main.async` carries
    /// the numbers from the body evaluation that made it, not the numbers as they are when it runs.
    /// Several changes arrive before any block runs, so each applied a delta computed before the
    /// previous one had landed — **the same shortfall applied twice**, which overshoots past the
    /// target and makes the next fit overshoot back.
    ///
    /// Measured on the lookup panel, 2026-09-30: a card wanting a steady 242 points drove the
    /// window between 404 and 120 for as long as it was up — 257 distinct heights in 15 seconds,
    /// `given` alternating 384 and 100, exactly two deltas of 142 where one was due. The fit
    /// arithmetic was never wrong; `theFitIsAFixedPoint` holds `wanted` constant and passes, and a
    /// fixed point is not reached by applying the step twice.
    ///
    /// A reference type because it must outlive a body evaluation and be read at application time.
    @State private var fit = PendingFit()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ContentFit.self) { ContentFit(of: $0) }
            action: { _, latest in
                report?(latest.wanted, latest.given)
                fit.wanted = latest.wanted
                fit.given = latest.given
                apply()
            }
            // **Attaching retries the fit.** `WindowReader` only assigned, and both `apply`
            // calls give up when there is no window yet — so a geometry change and `onAppear`
            // that both landed before attachment were discarded, and nothing asked again. The
            // pane kept its default size until some later geometry change happened to arrive.
            .background(WindowReader { attached in
                window = attached
                if attached != nil { apply() }
            })
            .onAppear { apply() }
            // **And the window is let go when the view does.** Held past disappearance, a queued
            // move could resize a window this modifier no longer belongs to.
            .onDisappear { window = nil; fit.scheduled = false }
    }

    /// Moves the window to the newest fit, once per runloop turn.
    ///
    /// Nothing is lost by coalescing: the box holds the latest numbers, so a change that arrives
    /// while a move is pending is the one that move will read. And the move itself changes what
    /// the content is given, which brings the next fit — so a settled window simply computes a
    /// delta of nothing and stops.
    private func apply() {
        guard let window, !fit.scheduled else { return }
        fit.scheduled = true
        _ = window
        // Outside the layout pass this runs in: resizing a window from inside one re-enters layout
        // until AppKit gives up, which is measured in this file's own history.
        DispatchQueue.main.async {
            // **Cleared after the move, not before it.** Clearing first let a geometry callback
            // arriving during an animated resize schedule a second move toward the same
            // destination, and the setup window retargeted itself repeatedly on one change.
            defer { fit.scheduled = false }
            // **Still this modifier's window, and still a window.** The block captured the
            // window it was scheduled with, so one queued before the view disappeared — or
            // before the window was replaced — resized something this view no longer owns.
            guard let live = self.window, live === window else { return }
            guard let delta = SettingsWindowFit.shortfall(
                wanted: fit.wanted, given: fit.given, ceiling: ceiling) else { return }
            SettingsWindowFit.move(
                live, by: delta, width: width,
                lowestBottom: live.screen?.visibleFrame.minY,
                animated: animates && live.isVisible, recentres: recentres)
        }
    }

}

/// **What a scroll view reports: the height its content wants, and the height it has** — with
/// the insets on both sides, so whatever sits over the content is in each and cancels.
///
/// One type and one conversion, shared by the fit and by the pane that feeds it. Two copies of a
/// two-field measurement and its `onScrollGeometryChange` mapping is two places for the inset
/// rule to drift, and a window sized from one reading of it while a pane reported the other
/// would chase a target nothing agrees on.
struct ContentFit: Equatable {
    let wanted: CGFloat
    let given: CGFloat

    init(of geometry: ScrollGeometry) {
        wanted = geometry.contentSize.height + geometry.contentInsets.top
            + geometry.contentInsets.bottom
        given = geometry.containerSize.height
    }
}

/// The newest numbers the fit was computed from, and whether a move is already on its way.
///
/// **A class on purpose.** The point is to be read when the move runs rather than when it was
/// scheduled; a struct in `@State` is copied into the closure and defeats that entirely.
@MainActor
private final class PendingFit {
    var wanted: CGFloat = 0
    var given: CGFloat = 0
    var scheduled = false
}

extension View {
    /// Makes the window this view is in as tall as the view's scrolling content, at `width`.
    /// Inert where there is no window — a preview, a test — so the view is unchanged there.
    func fitsItsContent(width: CGFloat) -> some View { modifier(FitsItsContent(width: width)) }

    /// The same **for the height alone**, for a surface that bounds its own scrolling region and is
    /// placed by its owner rather than by SwiftUI: it grows to its content up to `ceiling`, scrolls
    /// past it, does not animate, is never re-centred, and keeps whatever width it has.
    ///
    /// This is the lookup panel, and it is the third surface to need this. The first two were a
    /// scroll view that offered its window no height; this one is a window whose frame its controller
    /// sets by hand — `show()` writes `Token.Panel.cardOpeningHeight` on open and on every reuse —
    /// so SwiftUI never revisits it however much the content wants. Measured 398 × 240 for every
    /// card, with the whole footer below the fold.
    func fitsItsContent(
        upTo ceiling: CGFloat, report: ((CGFloat, CGFloat) -> Void)? = nil
    ) -> some View {
        modifier(FitsItsContent(
            width: nil, ceiling: ceiling, animates: false, recentres: false, report: report))
    }
}
