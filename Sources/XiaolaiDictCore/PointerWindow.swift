import CoreGraphics
import Foundation

/// A window as the compositor lists it, reduced to the two facts that answer "whose pixel is this":
/// who owns it, and where it is.
public struct ListedWindow: Sendable, Equatable {
    public let pid: Int32
    /// Global screen points with a top-left origin — `kCGWindowBounds`' own space, which is also the
    /// space a hover point arrives in.
    public let bounds: CGRect

    public init(pid: Int32, bounds: CGRect) {
        self.pid = pid
        self.bounds = bounds
    }
}

/// Which process owns the pixel under the pointer — **asked of the compositor, before Accessibility**.
///
/// `AXUIElementCopyElementAtPosition` cannot be used to find this out, and a `pid` check on what it
/// returns is a check made one call too late. Where the window at that point belongs to *this*
/// process, Accessibility services the request **in-process, on the calling thread**:
/// `-[NSApplication accessibilityHitTest:]` runs, `NSHostingView` answers it, and SwiftUI evaluates
/// the panel's body wherever the call was made from. Off the main actor the first `@MainActor` call
/// in that body traps — measured, crash report 2026-09-25: `EXC_BREAKPOINT` in `dispatch_assert_queue`
/// under `LookupPanelContent.content`, reached from `ScreenWordReader.target(at:)` on a
/// cooperative-pool thread. Nothing in the reply can prevent it; only not asking can.
public enum PointerWindow {
    /// The owner of the frontmost window containing `point`, or nil where no listed window does.
    ///
    /// `windows` are front to back, which is `CGWindowListCopyWindowInfo`'s documented order and the
    /// order the compositor answers a hit test in.
    public static func owner(at point: CGPoint, in windows: [ListedWindow]) -> Int32? {
        windows.first { $0.bounds.contains(point) }?.pid
    }

    /// `CGWindowListCopyWindowInfo`'s dictionaries as the two facts above, in the order given.
    ///
    /// **Every level survives, and that is the load-bearing part.** The recogniser's own window search
    /// keeps `kCGWindowLayer == 0`, because it is looking for the ordinary window of the app the reader
    /// is reading. The same filter here would skip the lookup panel, which the app puts at `.floating`
    /// — the one window this exists to find. A window missing either fact is dropped rather than
    /// guessed at: an unplaced window cannot contain a point.
    public static func listed(_ info: [[String: Any]]) -> [ListedWindow] {
        info.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({
                      CGRect(dictionaryRepresentation: $0 as CFDictionary)
                  })
            else { return nil }
            return ListedWindow(pid: pid, bounds: bounds)
        }
    }
}
