import SwiftUI

/// The arithmetic of a Notification Center style pile: cards stacked with the newest in front,
/// fanning out into a list as `progress` runs 0 to 1.
///
/// Separate from the `Layout` that applies it because `Subviews` cannot be fabricated in a test.
/// Maths left inside `placeSubviews` can only be checked by looking at the screen; here it can be
/// checked by reading numbers.
///
/// **Card 0 is the deepest, the last card is on top.** Draw order in a `Layout` follows subview
/// order, so reversing the data is what puts the newest card at the front of the pile.
struct CardPile: Equatable {
    /// Gap between cards once fanned out — the same gap as between any two siblings.
    var spacing: CGFloat
    /// How far each buried card peeks below the one in front of it.
    var peek: CGFloat
    /// How much narrower each buried card is, per side.
    var sideInset: CGFloat
    /// Cards deeper than this hide exactly behind the last visible one, so a fifty-card pile is no
    /// taller than a three-card one.
    var maxVisibleDepth: Int

    init(
        spacing: CGFloat, peek: CGFloat, sideInset: CGFloat,
        maxVisibleDepth: Int = Token.Limit.pileDepth
    ) {
        self.spacing = spacing
        self.peek = peek
        self.sideInset = sideInset
        self.maxVisibleDepth = maxVisibleDepth
    }

    /// Built from the reader's own scale, so the offsets that say "these are stacked" stay in
    /// proportion to the cards being stacked. Taken as an argument rather than read from the
    /// environment because this is arithmetic, not a view — which is what makes it testable.
    init(_ scale: Scale) {
        self.init(
            spacing: scale.space.stack, peek: scale.space.peek, sideInset: scale.space.sideInset)
    }

    struct Placement: Equatable {
        var origin: CGPoint
        var size: CGSize
    }

    /// The stack's total height at `progress`.
    func height(of heights: [CGFloat], progress: Double) -> CGFloat {
        guard let front = heights.last else { return 0 }
        let count = heights.count
        let piled = front + CGFloat(min(count - 1, maxVisibleDepth)) * peek
        let fanned = heights.reduce(0, +) + spacing * CGFloat(count - 1)
        // A spring undershoots below 0 as well as overshooting past 1, and a negative height
        // proposed to SwiftUI is not a smaller card, it is a broken layout.
        return max(0, Self.lerp(piled, fanned, progress))
    }

    /// Where card `index` goes, in the stack's own coordinates — or nil when there is no such card,
    /// which is a mistake in the caller rather than something to place at the origin.
    func placement(of index: Int, in heights: [CGFloat], width: CGFloat, progress: Double) -> Placement? {
        guard heights.indices.contains(index), let front = heights.last else { return nil }
        let depth = CGFloat(min(heights.count - 1 - index, maxVisibleDepth))

        let piledOrigin = CGPoint(x: depth * sideInset, y: depth * peek)
        // Buried cards borrow the front card's height so their peeking edges line up evenly,
        // instead of each poking out by however tall its own content happens to be.
        let piledSize = CGSize(width: width - depth * sideInset * 2, height: front)

        let fannedOrigin = CGPoint(x: 0, y: fannedTop(of: index, in: heights))
        let fannedSize = CGSize(width: width, height: heights[index])

        // Position interpolates on the raw progress and size on a clamped one. The overshoot is the
        // life in the animation, but a card that grew past the drawer's width would be clipped and
        // read as a glitch rather than as a spring.
        let clamped = min(max(progress, 0), 1)
        return Placement(
            origin: CGPoint(
                x: Self.lerp(piledOrigin.x, fannedOrigin.x, clamped),
                y: Self.lerp(piledOrigin.y, fannedOrigin.y, progress)),
            size: CGSize(
                width: Self.lerp(piledSize.width, fannedSize.width, clamped),
                height: Self.lerp(piledSize.height, fannedSize.height, clamped)))
    }

    /// Walks the pile from the top card down, which is the order the fanned list reads in.
    private func fannedTop(of index: Int, in heights: [CGFloat]) -> CGFloat {
        var cursor: CGFloat = 0
        for row in 0..<heights.count {
            let candidate = heights.count - 1 - row
            if candidate == index { return cursor }
            cursor += heights[candidate] + spacing
        }
        return cursor
    }

    private static func lerp(_ from: CGFloat, _ to: CGFloat, _ t: Double) -> CGFloat {
        from + (to - from) * CGFloat(t)
    }
}

/// How one card in a pile is drawn.
///
/// **A buried card is a plate and nothing else** — no words, no accent edge, nothing for VoiceOver
/// to read out. It is the shoulder the front card rests on, and the front card hides all of it but
/// the sliver that peeks. Before this existed, a buried card drew its own coloured edge at full
/// strength straight through the card in front: a closed pile of three showed orange, blue *and*
/// purple at once on a card labelled with one word, with two of the arcs crossing that card's text.
enum CardLayer: Equatable, Sendable {
    case front
    case buried

    var showsContent: Bool { self == .front }
    var showsAccent: Bool { self == .front }
}

extension CardPile {
    /// How each of a day's cards is drawn, newest first — and, by its length, which of them are
    /// built at all.
    ///
    /// Closed, only `maxVisibleDepth + 1` are returned: rendering fifty views to display three
    /// would cost fifty measurements in `placeSubviews` for nothing visible. The count and the
    /// layering come from here together so the view cannot render a different number of cards
    /// than the layout is placing.
    func layers(count: Int, expanded: Bool) -> [CardLayer] {
        guard count > 0 else { return [] }
        guard !expanded else { return Array(repeating: .front, count: count) }
        return (0..<min(count, maxVisibleDepth + 1)).map { $0 == 0 ? .front : .buried }
    }
}
