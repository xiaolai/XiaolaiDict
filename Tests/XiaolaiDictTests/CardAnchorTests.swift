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
        #expect(chrome.holds(onTheTail, inWindow: anchored.frame, tail: tail, compact: false))
        #expect(!chrome.holds(besideIt, inWindow: anchored.frame, tail: tail, compact: false))
        #expect(chrome.holds(CGPoint(x: card.midX, y: card.midY - chrome.tailLength), inWindow: anchored.frame, tail: tail, compact: false))
        #expect(chrome.holds(besideIt, inWindow: anchored.frame, tail: nil, compact: false), "with no tail the window answers whole")
        #expect(!chrome.holds(onTheTail, inWindow: anchored.frame, tail: tail.released, compact: false),
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

/// **The selection shortcut anchors its card on the selected word** where the app said where the word is (measured
/// exact in TextEdit and Safari, plan-card-refinements §6): flipped about the primary display, as a hover's box is, and
/// placed by the word — on the display it is on — rather than by the mouse, which may be anywhere.
@MainActor
struct SelectionShortcutAnchorTests {
    private let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    private let left = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)

    @Test func theSelectedWordsBoxIsFlippedAboutThePrimaryDisplay() {
        let read = ReadBounds(rect: DownRect(x: 427, y: 128, width: 46, height: 13), quality: .exact)
        #expect(XiaolaiDictApp.screenWord(read, screens: [primary, left])
                == WordBounds(rect: UpRect(x: 427, y: 759, width: 46, height: 13), quality: .exact))
    }

    /// A box on no display — a selection scrolled out of view — places nothing: the card goes by the pointer.
    @Test func aBoxOnNoDisplayLeavesThePointerRule() {
        let away = ReadBounds(rect: DownRect(x: 5_000, y: 128, width: 46, height: 13), quality: .exact)
        #expect(XiaolaiDictApp.screenWord(away, screens: [primary]) == nil)
        #expect(XiaolaiDictApp.screenWord(nil, screens: [primary]) == nil)
        let read = ReadBounds(rect: DownRect(x: 427, y: 128, width: 46, height: 13), quality: .exact)
        #expect(XiaolaiDictApp.screenWord(read, screens: []) == nil, "no display to flip about")
    }

    /// Read from the source, as the panel's other app wiring is: the shortcut cannot be pressed in a test process.
    @Test func theShortcutHandsItsWordToThePanel() throws {
        let app = try String(contentsOf: AppModules.repository.appending(path: "Sources/XiaolaiDict/XiaolaiDictApp.swift"),
                             encoding: .utf8)
        #expect(app.contains("case .selected(let selection, let bounds):"), "the shortcut drops the selection's box")
        #expect(app.contains("ticket: ticket, protecting: word)"), "the shortcut's lookup is not placed against its word")
    }
}

/// **A drag lets go of the word, through the controller** (plan-card-refinements D3, 2026-10-10): what a reader's drag
/// sets in motion, driven where a test process can drive it — the window moved with the button down, then grown as the
/// entry arriving and a disclosure opening grow it. A window drag itself cannot be driven here (AppKit reads the window
/// server's events for it); the real one is the E2E Mac's, `--placement-report … --drag`.
@MainActor
struct CardDragTests {
    @Test func aDraggedCardKeepsTheReadersPlaceAndPointsAtNothingThroughItsLaterGrowth() throws {
        let panel = LookupPanelController(hotkeys: HotkeyCenter(backend: FakeBackend()), windows: .alwaysOpen)
        let ticket = panel.newRequest()
        let word = WordBounds(rect: UpRect(x: 500, y: 600, width: 80, height: 20), quality: .exact)
        #expect(panel.show(.message(title: "waiting", detail: "the entry has not arrived"), near: UpPoint(x: 540, y: 610),
                           protecting: word, for: ticket))
        let tail = try #require(panel.model.tail)
        #expect(panel.anchor != nil && tail.tip != nil, "the fixture must be a card anchored on its word")
        let window = NSWindow(contentRect: panel.placement, styleMask: .borderless, backing: .buffered, defer: true)
        window.setFrame(panel.placement, display: false)
        panel.windowMoved(window, buttonDown: false)
        #expect(panel.anchor != nil, "the controller's own placing released the card")

        // The reader's drag: up and to the right, the button down. Read back, since a window rounds its origin to whole
        // points.
        window.setFrame(panel.placement.offsetBy(dx: 60, dy: 40), display: false)
        let dragged = window.frame
        panel.windowMoved(window, buttonDown: true)
        #expect(panel.anchor == nil && panel.model.growth == nil, "the drag left the card held to its word")
        #expect(panel.model.tail == tail.released, "the tail still points, or its strip went: \(String(describing: panel.model.tail))")
        #expect(window.frame == dragged, "the release moved the card")

        // The entry arrives, then a disclosure opens: the fit grows the window from its top, which stays where the reader
        // left it, and nothing pulls the card back to its word or points it there again.
        for wanted in [320.0, 400.0] {
            SettingsWindowFit.move(window, by: wanted - window.frame.height, width: nil,
                                   lowestBottom: panel.model.growth?.lowestBottom,
                                   highestTop: panel.model.growth?.highestTop, animated: false, recentres: false)
            panel.keepWhollyOnScreen(window)
            #expect(abs(window.frame.height - wanted) < 1, "not grown to \(wanted): \(window.frame)")
            #expect(abs(window.frame.minX - dragged.minX) < 1 && abs(window.frame.maxY - dragged.maxY) < 1,
                    "grown to \(wanted), the card left the reader's place: \(window.frame) against \(dragged)")
            #expect(panel.anchor == nil && panel.model.tail == tail.released)
        }
    }

    /// **A followed suggestion replaces the card where the reader has it** (audit of 2026-10-10). Pressing "Did you mean
    /// …?" after dragging the miss card aside showed the word's card against the misspelling again — placed afresh,
    /// tail and all — so the card jumped back from where the reader had put it. A replacement in place keeps the frame
    /// and stays let go of its word.
    @Test func aSuggestionFollowedAfterADragReplacesTheCardWhereTheReaderLeftIt() throws {
        let panel = LookupPanelController(hotkeys: HotkeyCenter(backend: FakeBackend()), windows: .alwaysOpen)
        let word = WordBounds(rect: UpRect(x: 500, y: 600, width: 80, height: 20), quality: .exact)
        #expect(panel.show(.message(title: "recieve", detail: "No entry"), near: UpPoint(x: 540, y: 610), protecting: word,
                           for: panel.newRequest()))
        let window = NSWindow(contentRect: panel.placement, styleMask: .borderless, backing: .buffered, defer: true)
        window.setFrame(panel.placement, display: false)
        panel.windowMoved(window, buttonDown: false)
        window.setFrame(panel.placement.offsetBy(dx: 60, dy: 40), display: false)
        let dragged = window.frame
        panel.windowMoved(window, buttonDown: true)
        let released = try #require(panel.model.tail)
        #expect(panel.anchor == nil && released.tip == nil, "the fixture must be a card the reader dragged off its word")

        #expect(panel.show(.message(title: "receive", detail: "the word's card"), near: panel.lastPointer,
                           protecting: panel.lastWord, for: panel.newRequest(replacingInPlace: true)))
        #expect(panel.placement == dragged, "the card moved back from where the reader left it: \(panel.placement)")
        #expect(panel.anchor == nil, "the replacement took hold of the word again")
        #expect(panel.model.tail == released, "the tail points again, or its strip went")
        #expect(panel.model.growth == nil)
    }

    /// The control: a new lookup of the same word — not a replacement — is placed on its word afresh.
    @Test func aNewLookupOfTheSameWordIsPlacedOnItAfresh() throws {
        let panel = LookupPanelController(hotkeys: HotkeyCenter(backend: FakeBackend()), windows: .alwaysOpen)
        let word = WordBounds(rect: UpRect(x: 500, y: 600, width: 80, height: 20), quality: .exact)
        #expect(panel.show(.message(title: "fine", detail: "…"), near: UpPoint(x: 540, y: 610), protecting: word,
                           for: panel.newRequest()))
        let placed = panel.placement
        let window = NSWindow(contentRect: placed, styleMask: .borderless, backing: .buffered, defer: true)
        window.setFrame(placed, display: false)
        panel.windowMoved(window, buttonDown: false)
        window.setFrame(placed.offsetBy(dx: 60, dy: 40), display: false)
        panel.windowMoved(window, buttonDown: true)
        #expect(panel.show(.message(title: "fine", detail: "again"), near: panel.lastPointer, protecting: panel.lastWord,
                           for: panel.newRequest()))
        #expect(panel.placement == placed && panel.anchor != nil && panel.model.tail?.tip != nil)
    }

    /// The control: a move the controller made itself — no button down — keeps the card on its word.
    @Test func aMoveOfTheControllersOwnKeepsTheAnchor() throws {
        let panel = LookupPanelController(hotkeys: HotkeyCenter(backend: FakeBackend()), windows: .alwaysOpen)
        let word = WordBounds(rect: UpRect(x: 500, y: 600, width: 80, height: 20), quality: .exact)
        #expect(panel.show(.message(title: "waiting", detail: "…"), near: UpPoint(x: 540, y: 610), protecting: word,
                           for: panel.newRequest()))
        let window = NSWindow(contentRect: panel.placement, styleMask: .borderless, backing: .buffered, defer: true)
        window.setFrame(panel.placement, display: false)
        panel.windowMoved(window, buttonDown: false)
        window.setFrame(panel.placement.offsetBy(dx: 60, dy: 40), display: false)
        panel.windowMoved(window, buttonDown: false)
        #expect(panel.anchor != nil && panel.model.tail?.tip != nil)
    }
}

/// **A frame that never settled, or a window that went, is a failed measurement — never a settled frame** (audit of
/// 2026-10-10). `steadyFrame` returned the last frame it had seen when its budget ran out, and kept watching past a window
/// that was no longer listed, and the placement report put its first frame in for a missing one: a card still moving, or
/// gone, read as a card that had settled where it was last seen.
@MainActor
struct SteadyFrameTests {
    private static let frame = CGRect(x: 100, y: 200, width: 400, height: 300)

    /// Frames read in turn, one a read, the last kept — nil where the window was not listed.
    private final class Frames {
        private var answers: [CGRect?]
        init(_ answers: [CGRect?]) { self.answers = answers }
        func next() -> CGRect? { answers.count > 1 ? answers.removeFirst() : answers.first ?? nil }
    }

    private func watch(_ read: @escaping () -> CGRect?, budget: Duration = .seconds(60)) async -> PlacementReport.Watched {
        await PlacementReport.watch(read, steady: .milliseconds(20), budget: budget, every: .milliseconds(1))
    }

    @Test func aFrameThatHoldsStillIsSteady() async {
        #expect(await watch({ Self.frame }) == .steady(Self.frame))
    }

    /// Moving at every read: it can never hold still, however long it is watched, so the budget is short.
    @Test func aFrameThatNeverHoldsStillIsUnsettledNotSteady() async {
        var height: CGFloat = 300
        let watched = await watch({ height += 1; return CGRect(x: 100, y: 200, width: 400, height: height) },
                                  budget: .milliseconds(200))
        guard case .unsettled(let last) = watched else { Issue.record("a moving frame read as \(watched)"); return }
        #expect(last.height > 300)
    }

    /// Gone at the read after it was first seen — before any second sighting could make it steady, however slowly the
    /// reads come.
    @Test func aWindowThatGoesIsGoneNotSteady() async {
        let frames = Frames([Self.frame, nil])
        #expect(await watch(frames.next) == .vanished)
    }

    @Test func aWindowNeverListedIsGone() async {
        #expect(await watch({ nil }) == .vanished)
    }
}

/// **A click is judged against the outline the card drew** (audit of 2026-10-10). The click-away test used the compact
/// card's rounder corner for every card, while the default card draws the panel's tighter one — so a click on the default
/// card's own paper, in the sliver between the two corners, closed it as a click away. The rounder corner is kept for the
/// tail's clearance alone.
@MainActor
struct CardOutlineHitTests {
    @Test func aClickOnTheDefaultCardsCornerIsOnTheCardAndOneBesideTheCompactCardsIsNot() throws {
        for size in TextSize.allCases {
            let chrome = CardChrome(textSize: size)
            let tail = CardTail(edge: .bottom, tip: 120)
            let frame = CGRect(x: 400, y: 300, width: 420, height: 320)
            let insets = chrome.insets(tail: tail)
            // Along the diagonal in from the card's top-left corner, the first point the default card's outline holds.
            func point(_ inward: CGFloat) -> CGPoint {
                CGPoint(x: frame.minX + insets.leading + inward, y: frame.maxY - insets.top - inward)
            }
            let inward = try #require(stride(from: CGFloat(0), through: chrome.cornerRadius, by: 0.25).first {
                chrome.holds(point($0), inWindow: frame, tail: tail, compact: false)
            }, "\(size): the default card's corner holds nothing")
            #expect(!chrome.holds(point(inward), inWindow: frame, tail: tail, compact: true),
                    "\(size): a point on the default card's paper is outside the compact card's rounder corner too")
            // And deep inside, both hold it: the difference is the corner, nothing else.
            #expect(chrome.holds(point(chrome.cornerRadius), inWindow: frame, tail: tail, compact: true))
        }
    }

    /// **The wire: the surface says which outline it drew**, to the `DrawnCard` the panel judges clicks by — the compact
    /// preview, and the default card, each drawn in a window ordered in off every display.
    @Test func theSurfaceSaysWhichOutlineItDrew() {
        for compact in [true, false, true] {
            let drawn = DrawnCard()
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.orderOut(nil) }
            let host = NSHostingView(rootView: PanelSurface(accent: nil, compact: compact) { Text(verbatim: "fair") } bar: {
                EmptyView()
            }.environment(\.scale, Scale.standard).environment(\.drawnCard, drawn))
            window.contentView = host
            window.orderFrontRegardless()
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date())
            }
            #expect(drawn.compact == compact, "a \(compact ? "compact" : "default") card said it drew the other")
        }
    }
}
