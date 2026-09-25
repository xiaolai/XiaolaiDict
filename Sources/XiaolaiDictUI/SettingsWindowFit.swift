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
        // Whole points: less than one is rounding, and moving for it would restart the animation on
        // a window already where it belongs. `rounded()` took half a point to one, so this does
        // not use it.
        guard abs(height - current.height) >= 1 || abs(widthChange) >= 1 else { return }
        var frame = current
        frame.size = CGSize(width: width, height: height)
        frame.origin.y = current.maxY - height
        guard animated else {
            window.setFrame(frame, display: true)
            // SwiftUI opened the window at a default width of its own — measured at 900 — and
            // placed it for that width. Narrowed where it stands, it would sit off to one side, so
            // it goes where a newly opened window goes. Only then: a window already at the panes'
            // width was placed by the reader, and stays where they put it.
            if recentres, abs(widthChange) >= 1 { window.center() }
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
    @State private var wanted: CGFloat = 0
    @State private var given: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ContentFit.self) { geometry in
                // Insets on both sides of the comparison, so whatever sits over the content is in
                // each and cancels.
                ContentFit(
                    wanted: geometry.contentSize.height + geometry.contentInsets.top
                        + geometry.contentInsets.bottom,
                    given: geometry.containerSize.height)
            } action: { _, fit in
                wanted = fit.wanted
                given = fit.given
                report?(fit.wanted, fit.given)
            }
            .background(WindowReader { window = $0 })
            .onChange(of: ContentFit(wanted: wanted, given: given), initial: true) { _, fit in
                guard let window, let delta = SettingsWindowFit.shortfall(
                    wanted: fit.wanted, given: fit.given, ceiling: ceiling) else { return }
                // Outside the layout pass this runs in: resizing a window from inside one
                // re-enters layout until AppKit gives up, which is measured in this file's own
                // history.
                DispatchQueue.main.async {
                    SettingsWindowFit.move(
                        window, by: delta, width: width,
                        lowestBottom: window.screen?.visibleFrame.minY,
                        animated: animates && window.isVisible, recentres: recentres)
                }
            }
    }

    private struct ContentFit: Equatable {
        let wanted: CGFloat
        let given: CGFloat
    }
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
