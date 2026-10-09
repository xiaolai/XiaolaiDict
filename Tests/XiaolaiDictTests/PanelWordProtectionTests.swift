import AppKit
import Capture
import CaptureModel
import Foundation
import MacCapture
import Testing
@testable import XiaolaiDict
@testable import XiaolaiDictUI

/// **The card never covers the word it explains, where the word's rectangle is known** (plan-card-refinements WI-2).
///
/// Placed below the pointer and clamped to the screen, a card near the bottom edge was pushed up over the word; and a
/// card placed clear grew back over it, because the content fit pins the top edge and grows down (Codex's
/// reproduction: word (600,730,80,20), panel (600,774,396,200) → (600,624,396,350)). So the placement picks a side
/// and a **room** on it, and every later fit — the content growing, the screen clamp — is held to that room.
@MainActor
struct PanelWordProtectionTests {
    private let screen = UpRect(x: 0, y: 0, width: 1_440, height: 900)
    private let card = NSSize(width: 396, height: 200)

    private func word(_ x: CGFloat, _ y: CGFloat, quality: WordBounds.Quality = .exact) -> WordBounds {
        WordBounds(rect: UpRect(x: x, y: y, width: 80, height: 20), quality: quality)
    }

    private func pointer(on word: WordBounds) -> UpPoint {
        UpPoint(x: word.rect.cg.midX, y: word.rect.cg.midY)
    }

    /// **No rectangle, today's rule, bit for bit** — and the room is the whole screen, so later fits are unchanged.
    @Test func withoutARectangleThePlacementIsTodays() {
        for point in [UpPoint(x: 100, y: 700), UpPoint(x: 1_430, y: 10), UpPoint(x: 700, y: 890)] {
            let placed = PanelPlacement.placed(for: card, near: point, protecting: nil, within: screen)
            #expect(placed.frame == PanelPlacement.frame(for: card, near: point, within: screen))
            #expect(placed.room == screen)
            #expect(placed.lowestBottom == nil, "the fit's floor changed with no word to keep")
        }
    }

    /// **Every edge**: a word mid-screen, near each edge, in a corner, and partly off the screen. The card is on the
    /// screen and clear of the word in each.
    @Test(arguments: [
        (600.0, 500.0), (600.0, 100.0), (600.0, 860.0), (10.0, 400.0), (1_400.0, 400.0),
        (1_400.0, 20.0), (5.0, 875.0), (600.0, 895.0), (600.0, -10.0),
    ])
    func theCardIsClearOfTheWordAtFirstShow(x: Double, y: Double) {
        let protected = word(x, y)
        let placed = PanelPlacement.placed(for: card, near: pointer(on: protected), protecting: protected, within: screen)
        #expect(!placed.frame.intersects(protected.rect.cg), "covers the word at (\(x), \(y)): \(placed.frame)")
        #expect(screen.cg.contains(placed.frame), "off the screen at (\(x), \(y)): \(placed.frame)")
    }

    /// Below where the card fits below — the side today's rule already uses — and above only where it does not.
    @Test func theCardGoesBelowWhereItFitsAndAboveWhereItDoesNot() {
        let middle = word(600, 500)
        #expect(PanelPlacement.placed(for: card, near: pointer(on: middle), protecting: middle, within: screen)
            .frame.maxY <= middle.rect.cg.minY)
        let low = word(600, 100)
        #expect(PanelPlacement.placed(for: card, near: pointer(on: low), protecting: low, within: screen)
            .frame.minY >= low.rect.cg.maxY)
    }

    /// **Taller than both sides: it shrinks into the larger one and scrolls, never covers.**
    @Test func aCardTallerThanBothSidesShrinksIntoTheLargerOne() {
        let short = UpRect(x: 0, y: 0, width: 1_440, height: 300)
        let protected = word(600, 120)
        let placed = PanelPlacement.placed(
            for: NSSize(width: 396, height: 600), near: pointer(on: protected), protecting: protected, within: short)
        #expect(!placed.frame.intersects(protected.rect.cg))
        #expect(placed.frame.height < 600 && placed.frame.height > 0)
        // Above has 300 − 8 − 140 − 4 = 148; below has 120 − 4 − 8 = 108.
        #expect(placed.frame.minY >= protected.rect.cg.maxY)
    }

    /// **The protection survives growth**, through the window fit's own arithmetic: each later fit — entry arrival,
    /// sense expansion, a translation, the footer — moves the bottom edge down, bounded by the room's floor, and the
    /// screen clamp then holds the frame to the room. Codex's reproduction is the second case.
    @Test(arguments: [(600.0, 730.0), (600.0, 100.0), (600.0, 500.0), (1_400.0, 20.0)])
    func theProtectionSurvivesEveryLaterFit(x: Double, y: Double) {
        let protected = word(x, y)
        let placed = PanelPlacement.placed(for: card, near: pointer(on: protected), protecting: protected, within: screen)
        let window = NSWindow(contentRect: placed.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.setFrame(placed.frame, display: false)
        for wanted in [260.0, 350.0, 520.0, 900.0, 2_000.0] {
            SettingsWindowFit.move(
                window, by: wanted - window.frame.height, width: nil,
                lowestBottom: placed.lowestBottom ?? screen.cg.minY,
                animated: false, recentres: false)
            window.setFrame(PanelPlacement.fitted(window.frame, within: placed.room), display: false)
            #expect(!window.frame.intersects(protected.rect.cg),
                    "grown to \(wanted) over the word at (\(x), \(y)): \(window.frame)")
            #expect(screen.cg.contains(window.frame), "grown off the screen: \(window.frame)")
        }
    }

    /// **The positive control**: the same growth held only to the screen — today's arithmetic — does cover the word,
    /// so the test above can fail.
    @Test func withoutTheRoomTheSameGrowthCoversTheWord() {
        let protected = word(600, 730)
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.setFrame(NSRect(x: 600, y: 774, width: 396, height: 200), display: false)
        SettingsWindowFit.move(window, by: 150, width: nil, lowestBottom: screen.cg.minY, animated: false, recentres: false)
        window.setFrame(PanelPlacement.fitted(window.frame, within: screen), display: false)
        #expect(window.frame.intersects(protected.rect.cg), "Codex's reproduction no longer reproduces: \(window.frame)")
    }

    /// The room is the side the card was put on, with the word's gap and the screen's margin both kept.
    @Test func theRoomExcludesTheWordAndKeepsTheGap() {
        let protected = word(600, 500)
        let placed = PanelPlacement.placed(for: card, near: pointer(on: protected), protecting: protected, within: screen)
        let fitted = PanelPlacement.fitted(
            NSRect(x: 600, y: 0, width: 396, height: 2_000), within: placed.room)
        #expect(fitted.maxY <= protected.rect.cg.minY - PanelPlacement.wordGap)
        #expect(fitted.minY >= screen.cg.minY + PanelPlacement.margin)
    }

    /// **Hover hands the app its word, and a followed suggestion is placed against the same word** — read from the
    /// source, as the panel's other app wiring is (`SpellingSuggestionLineTests`): the app cannot be driven to a hover
    /// here. The hover itself is the `hover` E2E stage's.
    @Test func theAppCarriesTheWordFromTheHoverAndToTheFollowUp() throws {
        let app = try String(contentsOf: AppModules.repository.appending(path: "Sources/XiaolaiDict/XiaolaiDictApp.swift"),
                             encoding: .utf8)
        #expect(app.contains("ticket: ticket, protecting: word,"), "a hover's word is not handed to the lookup")
        #expect(app.contains("placement: .notInSentence, protecting: panel.lastWord)"),
                "a followed suggestion is not placed against the miss's word")
    }
}

/// **`--read-point` says where the word is**, so the `hover` stage can check the box against its own measurement and
/// hand it to `--placement-report` (plan-card-refinements WI-2).
struct PointReportBoundsTests {
    private let selection = Selection(
        text: "cat", sentence: "The cat sat.", rangeInSentence: NSRange(location: 4, length: 3),
        quality: .accessibility(.accessibilityTextRange, context: .complete),
        place: ReadingPlace(bundleID: "com.apple.TextEdit", name: "TextEdit"))

    @Test func theReportCarriesTheBoxYDownWithItsQuality() throws {
        let read = ReadBounds(rect: DownRect(x: 140, y: 200, width: 30, height: 20), quality: .containing)
        let line = try LookupCommand.jsonLine(PointReport(selection, bounds: read, milliseconds: 3))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let bounds = try #require(json["bounds"] as? [String: Any])
        #expect(bounds["x"] as? Double == 140 && bounds["y"] as? Double == 200)
        #expect(bounds["width"] as? Double == 30 && bounds["height"] as? Double == 20)
        #expect(bounds["quality"] as? String == "containing")
    }

    @Test func noBoxIsReportedAsNone() throws {
        let line = try LookupCommand.jsonLine(PointReport(selection, bounds: nil, milliseconds: 3))
        #expect(!line.contains("\"bounds\""))
    }
}
