import CoreGraphics

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
    /// Gap between cards once fanned out.
    var spacing: CGFloat = 8
    /// How far each buried card peeks below the one in front of it.
    var peek: CGFloat = 7
    /// How much narrower each buried card is, per side.
    var sideInset: CGFloat = 9
    /// Cards deeper than this hide exactly behind the last visible one, so a fifty-card pile is no
    /// taller than a three-card one.
    var maxVisibleDepth: Int = 2

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
