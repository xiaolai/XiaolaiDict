import AppKit
import Capture
import SwiftUI
import Testing
@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// **The card anchored on its word, with a tail that points at it** (the owner's decision of 2026-10-09: like the
/// system's own popup) — as arithmetic, each rule beside a control that would fail it.
///
/// Where the word's rectangle is known the card is centred on the word, below it where it fits and above where it does
/// not, its tail at the word's middle and clear of the card's rounded corners, and WI-2's rule holds: the window never
/// covers the word, at first show or after any later fit, and the side chosen governs every resize. With no rectangle
/// the card is placed by the pointer, as before, and has no tail.
@MainActor
struct CardAnchorTests {
    private let screen = UpRect(x: 0, y: 0, width: 1_440, height: 900)
    private let card = NSSize(width: 396, height: 200)
    private let chrome = CardChrome(textSize: .standard)

    private func word(_ x: CGFloat, _ y: CGFloat, width: CGFloat = 80) -> WordBounds {
        WordBounds(rect: UpRect(x: x, y: y, width: width, height: 20), quality: .exact)
    }

    private func placed(_ word: WordBounds?, size: NSSize? = nil, within: UpRect? = nil,
                        pointer: UpPoint = UpPoint(x: 700, y: 450)) -> PanelPlacement.Placed {
        let at = word.map { UpPoint(x: $0.rect.cg.midX, y: $0.rect.cg.midY) } ?? pointer
        return PanelPlacement.placed(for: size ?? card, near: at, protecting: word, within: within ?? screen, chrome: chrome)
    }

    /// The card's own rectangle inside its window — the window less what it keeps around the card for the shadows.
    private func cardRect(_ placed: PanelPlacement.Placed) -> CGRect {
        let insets = chrome.insets(tail: placed.tail)
        return CGRect(x: placed.frame.minX + insets.leading, y: placed.frame.minY + insets.bottom,
                      width: placed.frame.width - insets.leading - insets.trailing,
                      height: placed.frame.height - insets.top - insets.bottom)
    }

    /// Where the tail's tip is on screen, y up.
    private func tip(_ placed: PanelPlacement.Placed) throws -> CGPoint {
        let tail = try #require(placed.tail), tip = try #require(tail.tip)
        let card = cardRect(placed)
        return CGPoint(x: card.minX + tip, y: tail.edge == .top ? card.maxY : card.minY)
    }

    // MARK: - Centring

    @Test(arguments: [(600.0, 500.0), (300.0, 700.0), (900.0, 120.0)])
    func theCardIsCentredOnTheWord(x: Double, y: Double) {
        let protected = word(x, y)
        #expect(abs(cardRect(placed(protected)).midX - protected.rect.cg.midX) < 0.001)
    }

    /// The control: placed by the pointer the card starts right of it, so it is not centred on the word.
    @Test func placedByThePointerTheCardIsNotCentred() {
        let protected = word(600, 500)
        let byPointer = placed(nil, pointer: UpPoint(x: protected.rect.cg.midX, y: protected.rect.cg.midY))
        #expect(abs(cardRect(byPointer).midX - protected.rect.cg.midX) > 1)
    }

    // MARK: - The side

    @Test func belowWhereTheCardFitsAndAboveWhereItDoesNot() throws {
        let middle = placed(word(600, 500))
        #expect(middle.tail?.edge == .top)
        #expect(middle.frame.maxY <= 500)
        let low = placed(word(600, 100))
        #expect(low.tail?.edge == .bottom)
        #expect(low.frame.minY >= 120)
    }

    // MARK: - The tail

    /// **The tip is at the word's middle, across, and just off its nearer edge**, the same distance from below as
    /// from above.
    @Test func theTailPointsAtTheMiddleOfTheWord() throws {
        let high = word(600, 500), low = word(600, 100)
        let below = try tip(placed(high)), above = try tip(placed(low))
        #expect(abs(below.x - high.rect.cg.midX) < 0.001)
        #expect(abs(above.x - low.rect.cg.midX) < 0.001)
        let gapBelow = high.rect.cg.minY - below.y, gapAbove = above.y - low.rect.cg.maxY
        #expect(gapBelow > 0 && gapAbove > 0, "the tip reaches into the word: \(gapBelow), \(gapAbove)")
        #expect(abs(gapBelow - gapAbove) < 0.001, "nearer from one side: \(gapBelow) against \(gapAbove)")
        #expect(gapBelow <= PanelPlacement.wordGap + chrome.before + 0.001)
    }

    /// **At a screen edge the card is held on the screen and the tail still points at the word**, while the word is
    /// over the card's straight edge; past that, the tip stops clear of the rounded corner.
    @Test func atAScreenEdgeTheCardStaysOnTheScreenAndTheTailFollowsTheWord() throws {
        let nearLeft = word(40, 500, width: 60)
        let left = placed(nearLeft)
        #expect(screen.cg.contains(left.frame))
        #expect(abs(cardRect(left).midX - nearLeft.rect.cg.midX) > 1, "the control: the card cannot be centred here")
        #expect(abs(try tip(left).x - nearLeft.rect.cg.midX) < 0.001)

        let atTheCorner = word(2, 500, width: 10)
        let corner = placed(atTheCorner)
        let tail = try #require(corner.tail?.tip)
        #expect(tail == chrome.cornerRadius + chrome.tailHalfWidth, "the tip ran into the rounded corner: \(tail)")
        let right = placed(word(1_428, 500, width: 10))
        let farTip = try #require(right.tail?.tip)
        #expect(farTip == cardRect(right).width - chrome.cornerRadius - chrome.tailHalfWidth)
    }

    // MARK: - WI-2's rule: never over the word, on the screen, whatever the size or the edge

    @Test(arguments: [
        (600.0, 500.0), (600.0, 100.0), (600.0, 860.0), (10.0, 400.0), (1_400.0, 400.0),
        (1_400.0, 20.0), (5.0, 875.0), (600.0, 895.0), (600.0, -10.0),
    ])
    func theCardNeverCoversTheWordAndStaysOnTheScreen(x: Double, y: Double) {
        let protected = word(x, y)
        let anchored = placed(protected)
        #expect(!anchored.frame.intersects(protected.rect.cg), "covers the word at (\(x), \(y)): \(anchored.frame)")
        #expect(screen.cg.contains(anchored.frame), "off the screen at (\(x), \(y)): \(anchored.frame)")
    }

    /// **Taller than both sides**: shrunk into the larger one, its tail on the edge facing the word, never covering.
    @Test func aCardTallerThanBothSidesShrinksIntoTheLargerOne() {
        let short = UpRect(x: 0, y: 0, width: 1_440, height: 300)
        let protected = word(600, 120)
        let anchored = placed(protected, size: NSSize(width: 396, height: 600), within: short)
        #expect(!anchored.frame.intersects(protected.rect.cg))
        #expect(anchored.frame.height < 600 && anchored.frame.height > 0)
        #expect(anchored.tail?.edge == .bottom)
    }

    /// **The side governs every later resize: the card grows away from its word** — down from a word above it, up from
    /// a word below it — through the window fit's own arithmetic, the re-anchoring after each, and the edge nearest
    /// the word never moves.
    @Test(arguments: [(600.0, 730.0), (600.0, 100.0), (600.0, 500.0), (1_400.0, 20.0)])
    func everyLaterFitGrowsAwayFromTheWord(x: Double, y: Double) throws {
        let protected = word(x, y)
        let first = placed(protected)
        let anchor = try #require(first.anchor)
        let window = NSWindow(contentRect: first.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.setFrame(first.frame, display: false)
        let nearEdge = { (frame: NSRect) in first.tail?.edge == .top ? frame.maxY : frame.minY }
        for wanted in [260.0, 350.0, 520.0, 900.0, 2_000.0] {
            let growth = try #require(first.growth)
            SettingsWindowFit.move(window, by: wanted - window.frame.height, width: nil,
                                   lowestBottom: growth.lowestBottom, highestTop: growth.highestTop,
                                   animated: false, recentres: false)
            window.setFrame(anchor.placed(window.frame).frame, display: false)
            #expect(!window.frame.intersects(protected.rect.cg), "grown to \(wanted) over the word: \(window.frame)")
            #expect(screen.cg.contains(window.frame), "grown off the screen: \(window.frame)")
            #expect(abs(nearEdge(window.frame) - nearEdge(first.frame)) < 0.001, "the edge by the word moved")
        }
    }

    /// The control: a card above its word, grown the way every card grew before — its top held — cannot grow at all.
    @Test func aCardAboveItsWordGrownFromItsTopStaysTheOpeningHeight() throws {
        let first = placed(word(600, 100))
        let window = NSWindow(contentRect: first.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.setFrame(first.frame, display: false)
        SettingsWindowFit.move(window, by: 300, width: nil, lowestBottom: first.frame.minY,
                               animated: false, recentres: false)
        #expect(window.frame.height == first.frame.height)
    }

    /// A window the content made wider is centred on the word again, and its tail moves with it.
    @Test func aWiderWindowIsCentredAgain() throws {
        let protected = word(600, 500)
        let first = placed(protected)
        let anchor = try #require(first.anchor)
        let wider = anchor.placed(NSRect(origin: first.frame.origin,
                                         size: NSSize(width: first.frame.width + 120, height: first.frame.height)))
        #expect(abs(cardRect(wider).midX - protected.rect.cg.midX) < 0.001)
        #expect(abs(try tip(wider).x - protected.rect.cg.midX) < 0.001)
    }

    /// **Re-anchoring is a fixed point**: the controller re-applies it on every resize, and the resize it causes asks
    /// again, so a second application must change nothing or the window would chase itself.
    @Test(arguments: [(600.0, 500.0), (600.0, 100.0), (5.0, 875.0), (1_400.0, 20.0)])
    func reAnchoringIsAFixedPoint(x: Double, y: Double) throws {
        let first = placed(word(x, y))
        let anchor = try #require(first.anchor)
        #expect(anchor.placed(first.frame) == first)
    }

    // MARK: - No rectangle, no tail

    @Test func withoutAWordThePlacementIsThePointersAndThereIsNoTail() {
        for point in [UpPoint(x: 100, y: 700), UpPoint(x: 1_430, y: 10), UpPoint(x: 700, y: 890)] {
            let byPointer = PanelPlacement.placed(for: card, near: point, protecting: nil, within: screen, chrome: chrome)
            #expect(byPointer.frame == PanelPlacement.frame(for: card, near: point, within: screen))
            #expect(byPointer.tail == nil && byPointer.growth == nil && byPointer.anchor == nil)
            #expect(chrome.insets(tail: nil) == EdgeInsets(
                top: chrome.before, leading: chrome.before, bottom: chrome.after, trailing: chrome.after))
        }
    }

    // MARK: - The outline the window answers to

    /// **The tail is the card's, and the corner beside it is not**: a click on the tail is inside, a click in the
    /// transparent strip beside it is outside — and with no tail the whole window answers, as before.
    @Test func theOutlineHoldsTheTailAndNotTheStripBesideIt() throws {
        let anchored = placed(word(600, 500))
        let tail = try #require(anchored.tail)
        let point = try tip(anchored)
        let onTheTail = CGPoint(x: point.x, y: point.y - chrome.tailLength * 0.25)
        let card = cardRect(anchored)
        let besideIt = CGPoint(x: card.minX + chrome.cornerRadius, y: point.y - chrome.tailLength * 0.25)
        #expect(chrome.holds(onTheTail, inWindow: anchored.frame, tail: tail))
        #expect(!chrome.holds(besideIt, inWindow: anchored.frame, tail: tail))
        #expect(chrome.holds(CGPoint(x: card.midX, y: card.midY - chrome.tailLength), inWindow: anchored.frame, tail: tail))
        #expect(chrome.holds(besideIt, inWindow: anchored.frame, tail: nil), "with no tail the window answers whole")
        #expect(!chrome.holds(onTheTail, inWindow: anchored.frame, tail: tail.released),
                "a released tail still answered for the place it used to point")
    }

    // MARK: - A drag lets go of the word

    @Test func aMoveIsTheReadersOnlyWithTheButtonDownTheSizeKeptAndNotOurs() {
        let before = NSRect(x: 100, y: 100, width: 396, height: 300)
        let moved = NSRect(x: 160, y: 80, width: 396, height: 300)
        #expect(PanelPlacement.isReadersDrag(from: before, to: moved, ours: before, buttonDown: true))
        #expect(!PanelPlacement.isReadersDrag(from: before, to: moved, ours: before, buttonDown: false))
        #expect(!PanelPlacement.isReadersDrag(from: before, to: moved, ours: moved, buttonDown: true))
        #expect(!PanelPlacement.isReadersDrag(
            from: before, to: NSRect(x: 160, y: 80, width: 396, height: 340), ours: before, buttonDown: true))
    }
}

/// **The tail is drawn as part of the card's outline**, so it is filled, edged and clipped with the card — and a card
/// with no tail is drawn exactly as it was.
@MainActor
struct CardShapeTests {
    /// y down, as SwiftUI lays a shape out: the strip a top tail occupies is 0…9.
    private let rect = CGRect(x: 0, y: 0, width: 300, height: 120)

    private func shape(_ tail: CardTail?) -> CardShape {
        CardShape(cornerRadius: 12, tail: tail, tailLength: 9, tailHalfWidth: 9)
    }

    @Test func withNoTailTheOutlineIsTheRoundedRectangleExactly() {
        let corner = RoundedRectangle(cornerRadius: 12, style: .continuous)
        #expect(shape(nil).path(in: rect) == corner.path(in: rect))
        #expect(shape(nil).inset(by: 0.5).path(in: rect) == corner.inset(by: 0.5).path(in: rect))
    }

    @Test func theTailIsInTheOutlineAndTheStripBesideItIsNot() {
        let top = shape(CardTail(edge: .top, tip: 150)).path(in: rect)
        #expect(top.contains(CGPoint(x: 150, y: 3)), "the tail is not part of the card")
        #expect(!top.contains(CGPoint(x: 40, y: 3)), "the strip beside the tail is drawn on")
        #expect(top.contains(CGPoint(x: 40, y: 60)))
        let bottom = shape(CardTail(edge: .bottom, tip: 150)).path(in: rect)
        #expect(bottom.contains(CGPoint(x: 150, y: 117)))
        #expect(!bottom.contains(CGPoint(x: 40, y: 117)))
        #expect(bottom.contains(CGPoint(x: 40, y: 3)), "the body is not at the top of a card whose tail is below it")
        #expect(top.contains(CGPoint(x: 40, y: 111)), "the body is not at the bottom of a card whose tail is above")
    }

    /// Released — the reader dragged the card off its word — the strip stays and nothing points.
    @Test func aReleasedTailDrawsNothingAndKeepsItsStrip() {
        let released = shape(CardTail(edge: .top, tip: nil)).path(in: rect)
        #expect(!released.contains(CGPoint(x: 150, y: 3)))
        #expect(released.contains(CGPoint(x: 150, y: 60)))
        #expect(!released.contains(CGPoint(x: 150, y: 8.5)), "the body grew into the strip, so the card would move")
    }

    /// **The tip is kept clear of the rounded corners**, wherever the word is.
    @Test func theTipIsKeptClearOfTheCorners() {
        let atTheEdge = shape(CardTail(edge: .top, tip: 0)).path(in: rect)
        #expect(atTheEdge.contains(CGPoint(x: 21, y: 2)), "the tip is not at the corner's end")
        #expect(!atTheEdge.contains(CGPoint(x: 3, y: 2)))
        let pastTheOther = shape(CardTail(edge: .top, tip: 400)).path(in: rect)
        #expect(pastTheOther.contains(CGPoint(x: 279, y: 2)))
        #expect(!pastTheOther.contains(CGPoint(x: 297, y: 2)))
    }
}

/// **A window above its word grows up**: its bottom edge — the tail's — stays, and it stops at the room's top.
@MainActor
struct UpwardGrowthTests {
    @Test func growingUpKeepsTheBottomAndStopsAtTheTop() {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.setFrame(NSRect(x: 100, y: 200, width: 396, height: 240), display: false)
        SettingsWindowFit.move(window, by: 100, width: nil, lowestBottom: nil, highestTop: 800,
                               animated: false, recentres: false)
        #expect(window.frame == NSRect(x: 100, y: 200, width: 396, height: 340))
        SettingsWindowFit.move(window, by: 1_000, width: nil, lowestBottom: nil, highestTop: 800,
                               animated: false, recentres: false)
        #expect(window.frame == NSRect(x: 100, y: 200, width: 396, height: 600))
        SettingsWindowFit.move(window, by: -300, width: nil, lowestBottom: nil, highestTop: 800,
                               animated: false, recentres: false)
        #expect(window.frame == NSRect(x: 100, y: 200, width: 396, height: 300), "a shrink moved the tail's edge")
    }
}
