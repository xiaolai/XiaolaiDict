import CoreGraphics
import Testing

@testable import XiaolaiDict

/// The pile's arithmetic, checked without rendering anything. Separating it from the `Layout` is
/// what makes that possible: `Subviews` cannot be fabricated in a test, so any maths left inside
/// `placeSubviews` can only be checked by looking at the screen.
struct CardPileTests {
    private let pile = CardPile(spacing: 8, peek: 7, sideInset: 9, maxVisibleDepth: 2)
    /// Index 0 is the deepest card; the last index is the one on top.
    private let heights: [CGFloat] = [40, 60, 50, 30]
    private let width: CGFloat = 300

    /// Unwrapped: every index these tests ask for is in range, so nil is a mistake in the test.
    private func place(_ index: Int, progress: Double, in stack: [CGFloat]? = nil) -> CardPile.Placement {
        pile.placement(of: index, in: stack ?? heights, width: width, progress: progress)!
    }

    // MARK: - Height

    /// Expected values are annotated `CGFloat` on purpose, here and below. Inside `#expect`,
    /// arithmetic on integer literals type-checks on its own and defaults to `Int`, so
    /// `someCGFloat == 30 + 2 * 7` compares 38.0 against 38 as different types and is *always*
    /// false. A bare literal infers correctly; an expression does not.
    @Test func aPiledStackIsTheFrontCardPlusWhatPeeksBehindIt() {
        // Front card 30, three cards behind it but only two may show.
        let expected: CGFloat = 30 + 2 * 7
        #expect(pile.height(of: heights, progress: 0) == expected)
    }

    @Test func aFannedStackIsEveryCardPlusTheGapsBetweenThem() {
        let expected: CGFloat = 40 + 60 + 50 + 30 + 3 * 8
        #expect(pile.height(of: heights, progress: 1) == expected)
    }

    @Test func aStackOfOneIsTheSameHeightPiledOrFanned() {
        #expect(pile.height(of: [50], progress: 0) == 50)
        #expect(pile.height(of: [50], progress: 1) == 50)
    }

    @Test func nothingToStackIsNoHeight() {
        #expect(pile.height(of: [], progress: 0) == 0)
        #expect(pile.height(of: [], progress: 1) == 0)
    }

    @Test func halfwayIsHalfwayBetweenTheTwo() {
        let piled = pile.height(of: heights, progress: 0)
        let fanned = pile.height(of: heights, progress: 1)
        #expect(pile.height(of: heights, progress: 0.5) == (piled + fanned) / 2)
    }

    /// A spring overshoots past 1. The stack may not collapse to a negative height on the way.
    @Test func anOvershootingSpringNeverProducesANegativeHeight() {
        #expect(pile.height(of: heights, progress: 1.3) >= 0)
        #expect(pile.height(of: heights, progress: -0.3) >= 0)
    }

    // MARK: - Placement, piled

    @Test func theTopCardOfAPileSitsAtTheFrontFullWidth() {
        let top = place(heights.count - 1, progress: 0)
        #expect(top.origin == CGPoint(x: 0, y: 0))
        #expect(top.size == CGSize(width: width, height: 30))
    }

    /// Buried cards are narrower and pushed down, which is what makes the pile read as a pile.
    @Test func eachBuriedCardIsInsetAndPeeksBelowTheOneInFront() {
        let second = place(heights.count - 2, progress: 0)
        #expect(second.origin == CGPoint(x: 9, y: 7))
        #expect(second.size.width == width - 18)
    }

    /// Buried cards take the front card's height so their peeking edges line up evenly, rather
    /// than each poking out by however tall its own content happens to be.
    @Test func buriedCardsBorrowTheFrontCardsHeight() {
        for index in 0..<(heights.count - 1) {
            let placed = place(index, progress: 0)
            #expect(placed.size.height == 30, "card \(index) should peek at the front card's height")
        }
    }

    /// Past the visible depth, cards hide exactly behind the last one that shows. Otherwise a
    /// fifty-card pile would march off the bottom of the drawer.
    @Test func cardsDeeperThanTheVisibleDepthHideBehindTheLastVisibleOne() {
        let deep: [CGFloat] = Array(repeating: 40, count: 12)
        let atLimit = place(deep.count - 1 - 2, progress: 0, in: deep)
        let deepest = place(0, progress: 0, in: deep)
        #expect(deepest.origin == atLimit.origin)
        #expect(deepest.size == atLimit.size)
    }

    // MARK: - Placement, fanned

    @Test func aFannedStackRunsTopCardFirstWithGapsBetween() {
        let count = heights.count
        // Visual order: the top card (last index) is the first row.
        let first = place(count - 1, progress: 1)
        let second = place(count - 2, progress: 1)
        let third = place(count - 3, progress: 1)

        let secondTop: CGFloat = 30 + 8
        let thirdTop: CGFloat = 30 + 8 + 50 + 8
        #expect(first.origin.y == 0)
        #expect(second.origin.y == secondTop)
        #expect(third.origin.y == thirdTop)
    }

    @Test func aFannedCardIsFullWidthAndItsOwnHeight() {
        let placed = place(1, progress: 1)
        #expect(placed.origin.x == 0)
        #expect(placed.size == CGSize(width: width, height: 60))
    }

    // MARK: - Overshoot

    /// The spring's overshoot is the life in the animation, so position may pass its target — but a
    /// card that grew past full width would be clipped by the drawer and read as a glitch.
    @Test func overshootMovesCardsWithoutGrowingThem() {
        let overshot = place(1, progress: 1.25)
        let settled = place(1, progress: 1)
        #expect(overshot.size == settled.size, "size should clamp at the fanned size")
        #expect(overshot.origin.y > settled.origin.y, "position should be free to overshoot")
    }

    @Test func anIndexOutsideTheStackIsNotAPlacement() {
        #expect(pile.placement(of: 9, in: heights, width: width, progress: 0) == nil)
        #expect(pile.placement(of: -1, in: heights, width: width, progress: 0) == nil)
        #expect(pile.placement(of: 0, in: [], width: width, progress: 0) == nil)
    }
}

