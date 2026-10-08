import AppKit
import Capture

/// **`Capture`'s screen, read off AppKit's** — the adapter between the two, so the policy measures a display without
/// binding the framework that reports one. Hover asks it for the height its points flip about, the history drawer for
/// the frame it docks in. Declared beside the drawer until the capture readers left the app (2026-10-08, P5).
extension ScreenMetrics {
    /// The AppKit screen as the drawer's geometry needs it.
    public init(_ screen: NSScreen) {
        self.init(frame: UpRect(screen.frame), visibleFrame: UpRect(screen.visibleFrame))
    }
}
