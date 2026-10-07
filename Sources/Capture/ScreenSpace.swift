import CoreGraphics
import Foundation

/// A point in the screen space AppKit uses: **origin bottom-left, y up**.
///
/// This module works in two screen spaces that differ only in the direction of y, and until this
/// type existed both were a bare `CGPoint`. `NSEvent.mouseLocation` and `NSScreen`'s frames are y
/// up; the Accessibility and CGEvent space `CaptureGeometry` serves is y down. Nothing in the
/// compiler separated them, so the same value was accepted by either side and the mistake showed up
/// as a drawer on the wrong display, or a panel at the wrong end of the screen — a plausible-looking
/// position rather than an error.
///
/// **The conversion is a named operation taking an explicit reference height**, never an implicit
/// global flip. Which height is right depends on the display arrangement, so the type will not pick
/// one: `flipped(aboutPrimaryHeight:)` makes the caller say. Hover is the one caller that needs it
/// — the pointer arrives y up from `NSEvent.mouseLocation` and the reader works y down — and until
/// it existed there was no caller at all.
public struct UpPoint: Equatable, Sendable {
    public let cg: CGPoint

    public static let zero = UpPoint(.zero)

    public init(_ cg: CGPoint) { self.cg = cg }
    public init(x: CGFloat, y: CGFloat) { self.cg = CGPoint(x: x, y: y) }

    /// The same point in the y-down space, flipped about the height of the display whose origin is
    /// the global origin — the one CGEvent measures from.
    ///
    /// Values off that display are not clamped. A display stacked above the primary yields a
    /// negative y, and that is the correct answer rather than an error: CGEvent's origin is the
    /// primary's top-left, and there is screen above it.
    public func flipped(aboutPrimaryHeight primaryHeight: CGFloat) -> DownPoint {
        DownPoint(x: cg.x, y: primaryHeight - cg.y)
    }
}

/// A point in the space Accessibility and CGEvent use: **origin top-left of the primary display,
/// y down**. The other half of the pair `UpPoint` describes.
public struct DownPoint: Equatable, Sendable {
    public let cg: CGPoint

    public static let zero = DownPoint(.zero)

    public init(_ cg: CGPoint) { self.cg = cg }
    public init(x: CGFloat, y: CGFloat) { self.cg = CGPoint(x: x, y: y) }

    /// Back to AppKit's space. The flip is its own inverse about the same height, so a round trip
    /// is exact.
    public func flipped(aboutPrimaryHeight primaryHeight: CGFloat) -> UpPoint {
        UpPoint(x: cg.x, y: primaryHeight - cg.y)
    }
}

/// A rectangle in AppKit's screen space: origin bottom-left, y up. See `UpPoint`.
public struct UpRect: Equatable, Sendable {
    public let cg: CGRect

    public init(_ cg: CGRect) { self.cg = cg }
    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.cg = CGRect(x: x, y: y, width: width, height: height)
    }

    /// Safe to expose unwrapped: a size has no origin, so it reads the same in either convention.
    /// A point or an origin does not, which is why neither is offered here.
    public var size: CGSize { cg.size }

    public func contains(_ point: UpPoint) -> Bool { cg.contains(point.cg) }
}
