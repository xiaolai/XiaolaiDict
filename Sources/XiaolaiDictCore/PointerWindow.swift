import CoreGraphics
import Foundation

/// A window as the compositor lists it, reduced to the two facts that answer "whose pixel is this":
/// who owns it, and where it is.
public struct ListedWindow: Sendable, Equatable {
    public let pid: Int32
    /// Global screen points with a top-left origin — `kCGWindowBounds`' own space, which is also the
    /// space a hover point arrives in.
    public let bounds: CGRect
    /// The compositor's number for it — what a capture of *this* window, and no other, is asked by.
    public let windowID: UInt32
    /// 0 for an ordinary app window; a panel, a menu or an overlay sits above.
    public let layer: Int
    /// 0 is a window nothing can see, which no pixel under the pointer belongs to.
    public let alpha: Double

    public init(pid: Int32, bounds: CGRect, windowID: UInt32 = 0, layer: Int = 0, alpha: Double = 1) {
        self.pid = pid
        self.bounds = bounds
        self.windowID = windowID
        self.layer = layer
        self.alpha = alpha
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
    /// **Whether any window of ours is at the point, at any depth.** The topmost window is not proof
    /// that Accessibility's hit test will land on it: a click-through overlay from another app, opaque
    /// in the list, can sit above our panel while the hit test goes straight through to it — in
    /// process, off the main actor. Refusing every hover over any window of ours is the safe answer;
    /// the cost is a hover over another app's window that happens to sit above one of ours.
    public static func ours(at point: CGPoint, in windows: [ListedWindow], ours: Int32) -> Bool {
        windows.contains { $0.pid == ours && $0.bounds.contains(point) }
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
            return ListedWindow(
                pid: pid, bounds: bounds,
                windowID: window[kCGWindowNumber as String] as? UInt32 ?? 0,
                layer: window[kCGWindowLayer as String] as? Int ?? 0,
                alpha: window[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }
}

/// **What hover may read, resolved once per hover** and handed to both paths — the compositor's
/// window list at the moment of asking, and which process Accessibility said owns the pointer.
///
/// The two paths used to choose separately: Accessibility named an element's app, and the capture
/// took the first ordinary window at the point. Where the app Accessibility named had a panel or a
/// sheet there, or exposed nothing while another app's window sat under it, the capture read a
/// different app from the one that was vetted.
public struct PointerTarget: Sendable, Equatable {
    public let point: CGPoint
    /// Front to back, every level.
    public let windows: [ListedWindow]
    /// The process Accessibility found an element for, if it found one.
    public let accessibilityOwner: Int32?

    public init(point: CGPoint, windows: [ListedWindow], accessibilityOwner: Int32?) {
        self.point = point
        self.windows = windows
        self.accessibilityOwner = accessibilityOwner
    }

    /// Which window a capture may read.
    public enum Capture: Sendable, Equatable {
        /// This one. `obscuredBy` is the window the compositor shows on top at the point when it is
        /// a different one — logged and counted, **not refused**: a click-through overlay from
        /// another app looks exactly like this in the list, and refusing would end hover for every
        /// reader who runs one.
        case window(ListedWindow, obscuredBy: ListedWindow?)
        /// Accessibility named this process and it has no window at the point. Nothing is read: the
        /// window under the pointer belongs to an app that was not the one vetted.
        case ownerHasNoWindow(Int32)
        /// No window at the point that a capture can be attributed to.
        case noWindow
    }

    /// **The capture reads the app Accessibility named**, at any level — its sheet, its panel —
    /// and only where it found nothing does the old rule stand: the frontmost ordinary window that
    /// is not this process's own.
    public func captureWindow(excludingProcess ours: Int32) -> Capture {
        let visible = windows.filter { $0.alpha > 0 && $0.bounds.contains(point) }
        let topmost = visible.first
        let chosen: ListedWindow
        if let owner = accessibilityOwner {
            guard let owned = visible.first(where: { $0.pid == owner }) else { return .ownerHasNoWindow(owner) }
            chosen = owned
        } else {
            guard let ordinary = visible.first(where: { $0.layer == 0 && $0.pid != ours }) else { return .noWindow }
            chosen = ordinary
        }
        return .window(chosen, obscuredBy: topmost == chosen ? nil : topmost)
    }
}

/// **The one rule for whether hover may read an app**, asked at each of the three places that
/// check: the Accessibility target before reading, the captured window before a pixel is taken,
/// and the word after it is read. Three copies of `excludedApps.contains` could drift; one rule
/// cannot.
public enum CaptureAuthorization {
    /// A refusal, or nil where reading is allowed. An owner that cannot be named is not refused
    /// here: the capture path refuses an unattributable region on its own, and Accessibility always
    /// names one.
    public static func refusal(bundleID: String?, policy: HoverPolicy) -> HoverRefusal? {
        guard let bundleID else { return nil }
        return policy.excludes(app: bundleID) ? .excludedApp : nil
    }

    /// The site rule, asked once the page under the pointer has been named — or found unnameable.
    public static func refusal(host: HostReading, policy: HoverPolicy) -> HoverRefusal? {
        policy.refuses(host) ? .excludedSite : nil
    }
}
