import AppKit
import SwiftUI

/// The icon of the app a word was read in.
///
/// Cached because a drawer draws fifty cards and `NSWorkspace` has to go to disk for each one, and
/// because the answer cannot change while XiaolaiDict is running in any way the reader would notice.
/// **Misses are cached too**: an app that has been deleted would otherwise be looked up again on
/// every scroll, which is the expensive case rather than the cheap one.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]

    /// Rasterised once at this size and kept. A card draws the icon at a fraction of an em, and
    /// `NSWorkspace` hands back a multi-representation icon up to 1024 pt — downscaling that on
    /// every card is work nobody asked for.
    ///
    /// It is also flattened into **sRGB**, and that is not housekeeping. An app icon carries HDR
    /// representations, and one of them in a SwiftUI hierarchy switches the whole rendered output
    /// to `kCGColorSpaceITUR_2100_PQ` — measured: a 0.96 white backdrop came back at 146 rather
    /// than 245, so every pixel test that had an icon anywhere in frame would read as though the
    /// app had dimmed. `ImageRenderer.colorMode` does not change it; the colour space follows the
    /// content, so the content is what has to be fixed.
    private static var drawnAt: NSSize {
        NSSize(width: Token.Panel.appIconRaster, height: Token.Panel.appIconRaster)
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let known = cache[bundleID] { return known }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            .flatMap(flattened)
        cache[bundleID] = found
        return found
    }

    private static func flattened(_ icon: NSImage) -> NSImage? {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(drawnAt.width), pixelsHigh: Int(drawnAt.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        representation.size = drawnAt

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(origin: .zero, size: drawnAt))
        context.flushGraphics()

        let flat = NSImage(size: drawnAt)
        flat.addRepresentation(representation)
        return flat
    }

    /// For the tests, which must not inherit whatever the last one looked up.
    static func forget() { cache.removeAll() }

    /// Whether an answer for `bundleID` is held — **including a miss**, which is the half of this
    /// cache nothing else can observe.
    ///
    /// A second `icon(for:)` returning nil looks identical whether it came from here or from
    /// another trip to `NSWorkspace`, so asking twice and comparing the answers cannot tell a
    /// working cache from one that had stopped keeping misses. That is the case worth keeping: an
    /// app the reader has deleted is searched for on every card of every scroll.
    static func remembers(_ bundleID: String) -> Bool { cache.index(forKey: bundleID) != nil }
}
