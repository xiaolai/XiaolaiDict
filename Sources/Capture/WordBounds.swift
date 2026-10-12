import CoreGraphics

/// A rectangle in the space Accessibility and CGEvent use: origin top-left of the primary display, y down. The other
/// half of the pair `UpRect` describes, flipped by the same named operation `DownPoint` has.
public struct DownRect: Equatable, Sendable {
    public let cg: CGRect

    public init(_ cg: CGRect) { self.cg = cg }
    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.cg = CGRect(x: x, y: y, width: width, height: height)
    }

    /// AppKit's rectangle for the same pixels: the top edge going down is the top edge going up, so the origin is the
    /// flipped **bottom** edge. Not clamped — a display above or left of the primary is real screen.
    public func flipped(aboutPrimaryHeight primaryHeight: CGFloat) -> UpRect {
        UpRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
    }
}

extension UpRect {
    /// Back to the y-down space, about the same height. Its own inverse.
    public func flipped(aboutPrimaryHeight primaryHeight: CGFloat) -> DownRect {
        DownRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
    }
}

/// **Where the looked-up word is on screen, and how well that is known** — what the lookup panel keeps clear
/// (plan-card-refinements WI-2). Carried beside a `Selection`, never in it: a selection is recorded and reopened, and a
/// rectangle is true only for the moment it was read.
public struct WordBounds: Equatable, Sendable {
    public enum Quality: String, Equatable, Sendable {
        /// The token's own box, asked of the app for the token's own range.
        case exact
        /// A box the app gave for a run that holds the token — WebKit's word around a CJK token. Larger than the word,
        /// which is safe to protect.
        case containing
    }

    public let rect: UpRect
    public let quality: Quality

    public init(rect: UpRect, quality: Quality) {
        self.rect = rect
        self.quality = quality
    }
}

/// `WordBounds` as a hover reads it, still y down — flipped once, beside the pointer, where the primary display's
/// height is known.
public struct ReadBounds: Equatable, Sendable {
    public let rect: DownRect
    public let quality: WordBounds.Quality

    public init(rect: DownRect, quality: WordBounds.Quality) {
        self.rect = rect
        self.quality = quality
    }

    /// **A box worth trusting, or none.** An app can answer an empty box for any range, a box elsewhere (another
    /// occurrence, a layout that moved) or garbage; any of them would protect the wrong place, and no box falls back to
    /// the pointer rule. So the box must be finite, have area, and lie under the pointer within the tolerance every
    /// capture path shares.
    public static func checked(_ box: CGRect, quality: WordBounds.Quality, near point: CGPoint) -> ReadBounds? {
        guard let bounds = checked(box, quality: quality), HitTolerance.distance(from: point, to: box) != nil else {
            return nil
        }
        return bounds
    }

    /// **A box worth trusting where no pointer says where it should be** — the selection shortcut's, pressed wherever
    /// the mouse happens to be (the owner's decision of 2026-10-09): finite, with area, and nothing more can be asked.
    public static func checked(_ box: CGRect, quality: WordBounds.Quality) -> ReadBounds? {
        guard !box.isNull, !box.isInfinite,
              box.minX.isFinite, box.minY.isFinite, box.width.isFinite, box.height.isFinite,
              box.width > 0, box.height > 0
        else { return nil }
        return ReadBounds(rect: DownRect(box), quality: quality)
    }

    public func flipped(aboutPrimaryHeight primaryHeight: CGFloat) -> WordBounds {
        WordBounds(rect: rect.flipped(aboutPrimaryHeight: primaryHeight), quality: quality)
    }
}
