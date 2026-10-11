import CoreGraphics

/// **The Dock's own window over a whole display, which draws nothing.** Some Macs have one — measured on a Mac mini,
/// 2026-10-12: 1920 × 1080 at the Dock's level, alpha 1 in the window list, every pixel fully transparent, a click
/// through it reaching the window below — and the compositor's front-to-back list names it in front of every point. A
/// check of *what is drawn* at a point must look past it; a check of whose window is *there* (hover's
/// `PointerWindow.captureWindow`, which already logs the topmost as `obscuredBy` and refuses nothing) is unaffected.
///
/// Named by what was measured — the Dock's level, the Dock's name, one whole display — so the Dock's real bar, a window
/// at the same level that is drawn, is not taken for it.
public enum DockEventSurface {
    /// `kCGDockWindowLevel`, asked of the system rather than written down.
    public static var level: Int { Int(CGWindowLevelForKey(.dockWindow)) }

    public static func isOne(owner: String?, layer: Int, bounds: CGRect, displays: [CGRect]) -> Bool {
        owner == "Dock" && layer == level && displays.contains(bounds)
    }
}
