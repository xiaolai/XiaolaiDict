import CoreGraphics

/// **A system process's window over a whole display, which draws next to nothing.** The compositor's front-to-back list
/// names it in front of every point, and a check of *what is drawn* at a point must look past it; a check of whose window
/// is *there* (hover's `PointerWindow.captureWindow`, which already logs the topmost as `obscuredBy` and refuses
/// nothing) is unaffected. Measured on a Mac mini, 2026-10-12, by capturing each window alone:
///
/// - **The Dock's**, 1920 × 1080 at the Dock's level: every one of 2,073,600 pixels fully transparent.
/// - **Notification Center's**, 1920 × 1080 one level above: 71,748 pixels drawn — two notification banners in the top
///   right corner — and the other 96.5% transparent. The `panel` stage named it in front of 24 unpin controls it was
///   not drawn over, a day after the Dock's had named 24 others; the other E2E Mac has neither window.
///
/// **What this does not see:** a banner that really is over a control. The stage's real click and Accessibility's own
/// hit test are what catch that.
///
/// Named by owner and one whole display, above ordinary windows, so an app's full-screen window (layer 0) and the
/// Dock's real bar are not taken for one.
public enum SystemOverlaySurface {
    /// The processes whose whole-display window was measured to be drawn sparsely, if at all.
    public static let owners: Set<String> = ["Dock", "Notification Center"]

    public static func isOne(owner: String?, layer: Int, bounds: CGRect, displays: [CGRect]) -> Bool {
        guard let owner, owners.contains(owner) else { return false }
        return layer > 0 && displays.contains(bounds)
    }
}
