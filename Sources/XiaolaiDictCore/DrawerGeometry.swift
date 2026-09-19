import CoreGraphics
import Foundation

/// A display, as the drawer's math needs it. Values rather than an `NSScreen`, so every case the
/// drawer has to survive — a notch, a second display, one narrower than the drawer — can be written
/// down in a test instead of waiting for the hardware that exhibits it.
///
/// **These are AppKit screen coordinates: origin bottom-left, y up.** `CaptureGeometry` in this same
/// module works in the opposite convention, because the Accessibility and CGEvent space is
/// top-left. The two must not be mixed, and neither converts for the other.
public struct ScreenMetrics: Equatable, Sendable {
    /// The whole display.
    public let frame: CGRect
    /// The display minus the menu bar — including the notch, where there is one — and the Dock.
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

/// Which screen edge the drawer is docked to.
public enum DrawerEdge: String, CaseIterable, Codable, Sendable {
    case top, bottom, left, right

    /// True when the drawer's thickness runs across the display's width.
    var isHorizontal: Bool { self == .left || self == .right }
}

/// What the reader has chosen about the drawer's shape.
public struct DrawerLayout: Equatable, Sendable {
    /// Width when docked left or right, height when docked top or bottom.
    public var thickness: CGFloat
    public var edge: DrawerEdge
    /// How much of the edge to span, or nil for the whole of it. Stored as one optional rather than
    /// a flag beside a fraction, so "full length" cannot disagree with a fraction nobody reads.
    public var spanFraction: CGFloat?
    /// Gap between the drawer and the screen edge. 0 is flush.
    public var inset: CGFloat
    public var cornerRadius: CGFloat

    /// Slack around the drawer for its shadow to land in. The window is grown by this much and then
    /// clipped to the display, which is what stops a right-docked drawer casting its shadow onto
    /// the display next door.
    public static let shadowMargin: CGFloat = 48

    public init(
        thickness: CGFloat = 380,
        edge: DrawerEdge = .right,
        spanFraction: CGFloat? = nil,
        inset: CGFloat = 0,
        cornerRadius: CGFloat = 16
    ) {
        self.thickness = thickness
        self.edge = edge
        self.spanFraction = spanFraction
        self.inset = inset
        self.cornerRadius = cornerRadius
    }
}

/// Where the drawer is, in both coordinate systems the window and its content need.
///
/// The window never moves. It is placed at `windowRect` and the drawer slides *inside* it, between
/// `contentOrigin` and `contentOrigin + hiddenOffset`. Animating the window's frame instead
/// relayouts the whole hierarchy every frame and stutters — which is the spike's central finding
/// and the reason this type exposes a parked offset at all.
public struct DrawerGeometry: Equatable, Sendable {
    /// The panel's frame, in AppKit screen coordinates.
    public let windowRect: CGRect
    /// The drawer itself, in points.
    public let contentSize: CGSize
    /// The drawer's top-left corner within the window, in SwiftUI coordinates — y down.
    public let contentOrigin: CGPoint
    /// Added to `contentOrigin`, this parks the drawer wholly outside the window on its docked
    /// side, so the window's clip hides every pixel of it.
    public let hiddenOffset: CGSize
    public let edge: DrawerEdge
    public let cornerRadius: CGFloat
    /// True when the drawer sits against the screen edge with no gap.
    public let isFlush: Bool

    /// Which pair of corners stays square. A panel flush against an edge keeps the corners touching
    /// that edge square, the way system panels do; lift it off and it rounds all round.
    public enum SquareCorners: Equatable, Sendable {
        case none, leading, trailing, top, bottom
    }

    /// Derived from the edge and the gap, never stored beside them — a stored copy could disagree
    /// with the geometry it describes.
    public var squareCorners: SquareCorners {
        guard isFlush else { return .none }
        switch edge {
        case .right: return .trailing
        case .left: return .leading
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    public static func make(_ layout: DrawerLayout, on screen: ScreenMetrics) -> DrawerGeometry {
        let visible = screen.visibleFrame

        // An inset may not eat the drawer, and a negative one is a caller's slip rather than a
        // request to overhang the screen.
        let halfShortest = max(0, min(visible.width, visible.height) / 2)
        let inset = min(max(layout.inset, 0), halfShortest)

        // The dimension the drawer's thickness occupies, and the one it spans. Naming them is the
        // point: the spike clamped thickness against `min(width, height)` whichever edge was
        // docked, so a left-docked drawer on a wide short display was limited by a height it does
        // not use.
        let across = layout.edge.isHorizontal ? visible.width : visible.height
        let along = layout.edge.isHorizontal ? visible.height : visible.width

        // Clamped with no minimum. A floor would be a UI nicety that, on a display narrower than
        // the floor, produces a drawer wider than the screen it is docked to.
        let thickness = min(max(layout.thickness, 0), max(0, across - inset * 2))

        let available = max(0, along - inset * 2)
        let span = layout.spanFraction.map { available * min(max($0, 0), 1) } ?? available

        let content: CGRect
        switch layout.edge {
        case .left, .right:
            let x = layout.edge == .right ? visible.maxX - inset - thickness : visible.minX + inset
            content = CGRect(
                x: x, y: visible.minY + (visible.height - span) / 2, width: thickness, height: span)
        case .top, .bottom:
            let y = layout.edge == .top ? visible.maxY - inset - thickness : visible.minY + inset
            content = CGRect(
                x: visible.minX + (visible.width - span) / 2, y: y, width: span, height: thickness)
        }

        // Grown for the shadow, then clipped to the display. `intersection` answers null for rects
        // that do not meet, which cannot happen for a content rect derived from this display's own
        // visible frame — but a caller can hand over metrics where it does, and a null frame would
        // reach AppKit as a window nobody can see rather than as an error.
        let grown = content.insetBy(dx: -DrawerLayout.shadowMargin, dy: -DrawerLayout.shadowMargin)
        let clipped = grown.intersection(screen.frame)
        let window = clipped.isNull ? content : clipped

        let originX = content.minX - window.minX
        let originY = window.maxY - content.maxY   // AppKit's y-up to SwiftUI's y-down

        // Far enough that the drawer is entirely past the window's bound on its docked side.
        let hidden: CGSize
        switch layout.edge {
        case .right: hidden = CGSize(width: window.width - originX, height: 0)
        case .left: hidden = CGSize(width: -(originX + content.width), height: 0)
        case .top: hidden = CGSize(width: 0, height: -(originY + content.height))
        case .bottom: hidden = CGSize(width: 0, height: window.height - originY)
        }

        return DrawerGeometry(
            windowRect: window,
            contentSize: content.size,
            contentOrigin: CGPoint(x: originX, y: originY),
            hiddenOffset: hidden,
            edge: layout.edge,
            cornerRadius: layout.cornerRadius,
            isFlush: inset < 1)
    }
}

/// Which display the drawer opens on.
public enum DrawerPlacement {
    /// The display the pointer is on — where the reader's attention is, and where the menu-bar
    /// click that opened the drawer happened.
    ///
    /// Resolved once, when the drawer opens, and held until it closes: re-resolving on every
    /// relayout would make the drawer hop displays because the pointer moved.
    public static func screen(under pointer: CGPoint, among screens: [ScreenMetrics]) -> ScreenMetrics? {
        screens.first { $0.frame.contains(pointer) } ?? screens.first
    }

    /// Whether the display the drawer is on is still attached. Compared by frame rather than by
    /// identity, because unplugging and replugging yields a different object for the same display.
    public static func isStillAttached(_ screen: ScreenMetrics, among screens: [ScreenMetrics]) -> Bool {
        screens.contains { $0.frame == screen.frame }
    }
}
