import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit

/// **The screen as composited, kept as a PNG** — what an instrument hands a person who has to look at a surface rather than
/// believe a number about it: `--history-report`'s backdrops, and `--placement-report --capture`'s card on its word
/// (plan-card-refinements D3, 2026-10-10). One copy, moved here from the history report so the two cannot capture
/// differently. **And the one door an instrument posts an input event through.**
///
/// **Neither is built into a release** (ADR-0010, addendum of 2026-10-10). Each is a deputy for whoever runs the
/// instrument, with the reader's grants: Screen Recording writes any region of the screen to a file the caller names, and
/// the Accessibility grant posts a click or a drag wherever the caller aims it — `--placement-report` did both, in a
/// release, from a rectangle on its command line. So a release answers `notBuiltIn` and `false`, and holds neither the
/// whole-display capture nor a mouse event at all, which `verify_capture_instruments` reads off the binary.
extension Instrument {
    enum ScreenCaptureFailure: Error, Equatable {
        case displayMissing
        /// A release: no instrument captures the screen.
        case notBuiltIn
    }

    /// The screen as composited — every window — over `source`, display-local and top-left (what ScreenCaptureKit's
    /// `sourceRect` means), at `size` pixels.
    nonisolated static func screenImage(
        of source: CGRect, size: CGSize, onDisplay displayID: CGDirectDisplayID
    ) async throws -> CGImage {
#if !XIAOLAIDICT_CAPTURE_INSTRUMENTS
        throw ScreenCaptureFailure.notBuiltIn
#else
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
#endif
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

    /// **One left-button mouse event at `point`** — global, y down, as a `CGEvent` is — posted at the HID level. Its
    /// modifiers are stated, none, never inherited from the session: a click made with Command still held is a
    /// Command-click (AGENTS.md). `source` is the caller's where it has one. False where the event could not be made —
    /// and always in a release, which makes none.
    nonisolated static func postMouse(_ type: CGEventType, at point: CGPoint, source: CGEventSource? = nil) -> Bool {
#if !XIAOLAIDICT_CAPTURE_INSTRUMENTS
        false
#else
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: .left) else { return false }
        event.flags = []
        event.post(tap: .cghidEventTap)
        return true
#endif
    }
}
