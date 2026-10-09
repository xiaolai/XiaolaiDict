import SwiftUI

/// **The tail a card anchored on its word carries, pointing at the word** (the owner's decision of 2026-10-09: the
/// card appears at the middle of the looked-up word, like the system's own popup, with a pointed tail toward it).
///
/// Only a card whose word's rectangle is known has one — the panel's placement decides, and with no rectangle the card
/// is placed by the pointer and drawn with none, as before.
public struct CardTail: Equatable, Sendable {
    /// Which edge of the card the tail leaves from: the top for a card below its word, the bottom for one above it.
    public enum Edge: Equatable, Sendable {
        case top
        case bottom
    }

    public let edge: Edge
    /// Where the tip is across the card, from the card's own leading edge — its window's, less the shadow's room. Nil
    /// once the reader has dragged the card away from its word: the strip the tail occupied stays, so the card does not
    /// jump, and nothing points at a word the card has left.
    public let tip: CGFloat?

    public init(edge: Edge, tip: CGFloat?) {
        self.edge = edge
        self.tip = tip
    }

    /// The same tail, no longer pointing at anything.
    public var released: CardTail { CardTail(edge: edge, tip: nil) }
}

/// **The lookup card's outline inside its window, at the reader's text size** — what the panel's placement has to
/// know to put the card and its tail where `PanelSurface` draws them: the room the shadows are given on each side, the
/// corner, and the tail's size. From `Scale`, which the surface draws from, so the two cannot disagree.
public struct CardChrome: Equatable, Sendable {
    /// The shadows' room left of the card, and above it: almost nothing, since light comes from the top left.
    public let before: CGFloat
    /// The shadows' room right of the card, and below it, where they fall.
    public let after: CGFloat
    /// The rounder of the two cards' corners — the compact preview's — so a tail kept clear of it is clear of either.
    public let cornerRadius: CGFloat
    /// How far the tail reaches out of the card, toward the word.
    public let tailLength: CGFloat
    /// Half the tail's width where it leaves the card.
    public let tailHalfWidth: CGFloat

    public init(textSize: TextSize) { self.init(Scale(textSize)) }

    init(_ scale: Scale) {
        before = scale.shadow.glowBefore
        after = scale.shadow.glowAfter
        cornerRadius = max(scale.radius.panel, scale.radius.lookup)
        tailLength = scale.space.tailLength
        tailHalfWidth = scale.space.tailHalfWidth
    }

    /// What the window keeps around the card, edge by edge. The shadows' room — except **below a card whose tail points
    /// down**, where the window ends just past the tip so the tip can come as near the word as it does from above: the
    /// tail's own strip carries most of the shadow there, and the faint rest of it is cut.
    public func insets(tail: CardTail?) -> EdgeInsets {
        EdgeInsets(top: before, leading: before, bottom: tail?.edge == .bottom ? before : after, trailing: after)
    }

    /// **Where the tip may sit across a card this wide** — clear of its rounded corners, so the tail always leaves from
    /// the straight part of the edge. `x` is where the word's middle is, from the card's leading edge.
    public func tip(at x: CGFloat, cardWidth: CGFloat) -> CGFloat {
        let lowest = cornerRadius + tailHalfWidth
        return min(max(x, lowest), max(lowest, cardWidth - lowest))
    }

    /// **Whether a click at `point` — screen points, y up — is on the card** in a window whose frame is `frame`: on the
    /// card's own outline, body and tail, where it carries a tail, so a click in the transparent strip beside the tail
    /// is a click away; on the whole window where it carries none, as every card was before.
    public func holds(_ point: CGPoint, inWindow frame: CGRect, tail: CardTail?) -> Bool {
        guard let tail else { return frame.contains(point) }
        let insets = insets(tail: tail)
        let card = CGRect(x: insets.leading, y: insets.top,
                          width: max(0, frame.width - insets.leading - insets.trailing),
                          height: max(0, frame.height - insets.top - insets.bottom))
        // The shape is laid out y down, from the window's top-left.
        let local = CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y)
        return CardShape(cornerRadius: cornerRadius, tail: tail, tailLength: tailLength, tailHalfWidth: tailHalfWidth)
            .path(in: card).contains(local)
    }
}

extension EnvironmentValues {
    /// **The tail the lookup card carries**, set by the panel from its placement — nil for a card placed by the pointer,
    /// and for every surface that is not the lookup panel.
    @Entry public var panelTail: CardTail?
}

/// **The card with its tail, as one outline**: filled, edged and clipped as one shape, so the tail is the card's paper
/// rather than a mark drawn beside it, and the window's transparent corners beside it stay transparent.
///
/// With no tail it is the card's rounded rectangle exactly — the same `RoundedRectangle`, the same path — so a card
/// placed by the pointer is drawn as it was.
struct CardShape: InsettableShape {
    let cornerRadius: CGFloat
    let tail: CardTail?
    let tailLength: CGFloat
    let tailHalfWidth: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let corner = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).inset(by: insetAmount)
        guard let tail else { return corner.path(in: rect) }
        // The card's body is the rectangle less the tail's strip; the strip is drawn into only by the tail.
        var body = rect
        body.size.height = max(0, rect.height - tailLength)
        if tail.edge == .top { body.origin.y = rect.minY + tailLength }
        let card = corner.path(in: body)
        guard let tip = tail.tip else { return card }
        return card.union(pointer(at: tip, edge: tail.edge, body: body))
    }

    /// The tail, inset as the body is, overlapping the body by its own length so the union has no seam.
    private func pointer(at tip: CGFloat, edge: CardTail.Edge, body: CGRect) -> Path {
        let x = body.minX + min(max(tip, cornerRadius + tailHalfWidth), max(cornerRadius + tailHalfWidth,
                                                                              body.width - cornerRadius - tailHalfWidth))
        // An inset moves each side in by `insetAmount`; along the axis the tip moves by that over the sine of the
        // half-angle, and the base with the body's edge.
        let slant = (tailHalfWidth * tailHalfWidth + tailLength * tailLength).squareRoot()
        let sine = slant > 0 ? tailHalfWidth / slant : 1
        let length = max(0, tailLength - insetAmount / sine + insetAmount)
        let half = tailLength > 0 ? length * tailHalfWidth / tailLength : 0
        let base = edge == .top ? body.minY + insetAmount : body.maxY - insetAmount
        let point = edge == .top ? base - length : base + length
        let inside = edge == .top ? base + tailLength : base - tailLength
        var path = Path()
        path.move(to: CGPoint(x: x - half, y: base))
        path.addLine(to: CGPoint(x: x, y: point))
        path.addLine(to: CGPoint(x: x + half, y: base))
        path.addLine(to: CGPoint(x: x + half, y: inside))
        path.addLine(to: CGPoint(x: x - half, y: inside))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> CardShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}
