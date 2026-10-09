import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit

/// **The screen as composited, kept as a PNG** — what an instrument hands a person who has to look at a surface rather than
/// believe a number about it: `--history-report`'s backdrops, and `--placement-report --capture`'s card on its word
/// (plan-card-refinements D3, 2026-10-10). One copy, moved here from the history report so the two cannot capture
/// differently.
extension Instrument {
    enum ScreenCaptureFailure: Error { case displayMissing }

    /// The screen as composited — every window — over `source`, display-local and top-left (what ScreenCaptureKit's
    /// `sourceRect` means), at `size` pixels.
    nonisolated static func screenImage(
        of source: CGRect, size: CGSize, onDisplay displayID: CGDirectDisplayID
    ) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureFailure.displayMissing
        }
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
    }

    /// Writes a capture as PNG, and answers why not when it could not be. **A measurement whose evidence cannot be looked
    /// at can only be believed** — the first reading the history report produced was implausible enough that it had to be
    /// looked at — so a failed write is reported, not dropped.
    static func keep(_ image: CGImage, as url: URL) -> String? {
        guard let file = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return "could not create \(url.path)"
        }
        CGImageDestinationAddImage(file, image, nil)
        return CGImageDestinationFinalize(file) ? nil : "could not write \(url.path)"
    }
}
