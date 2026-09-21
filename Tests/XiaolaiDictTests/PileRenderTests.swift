import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// The pile, rasterised and read back.
///
/// Not a GUI test — nothing here opens a window, moves a pointer or touches the machine's settings;
/// `ImageRenderer` draws into a bitmap. It earns its place because the defect it guards was
/// invisible to every other kind of check: the pile's arithmetic was correct and exhaustively
/// tested, `CardPileTests` passed throughout, and the drawer still drew three nested boxes,
/// because the front card was a 6% wash that hid nothing. **The only evidence that a card occludes
/// is a pixel behind it.**
///
/// Everything rasterised here avoids glass *and* scroll views on purpose. `ImageRenderer` draws
/// either one as a single flat tone. Measured one at a time, on the same padded label: plain, 205
/// distinct greys; inside `glassEffect`, 1; inside a `ScrollView`, 1; inside both, 1.
///
/// Both, separately — an earlier version of this note blamed the glass, having compared
/// `HistoryDrawerSurface` (which has both) against a view that had neither. That measured only
/// that *something* blanked it. `HistoryDrawerSurface` and `PinnedNoteView` are therefore both out
/// of reach here, and anything aimed at them would pass or fail on the renderer rather than on the
/// design — so these stop at the pile.
@MainActor
struct PileRenderTests {
    private let width: CGFloat = 356

    private func entry(_ lemma: String, _ sentence: String, id: Int) -> ReadingEntry {
        let range = (sentence as NSString).range(of: lemma)
        return ReadingEntry(
            id: id, lemma: lemma, surface: lemma, sentence: sentence,
            sentenceRange: range.location == NSNotFound ? nil : range,
            place: ReadingPlace(name: "TextEdit"), at: .distantPast, result: .found,
            quality: .accessibility(.accessibilityTextRange, context: .complete))
    }

    private var day: ReadingDay {
        ReadingDay(
            id: "2026-09-19", date: .distantPast, label: .yesterday,
            entries: [
                entry("temper", "Justice tempered with mercy.", id: 1),
                entry("rein", "He kept a tight rein on the budget.", id: 2),
                entry("sanction", "The sanctions were lifted.", id: 3),
                entry("table", "They tabled the motion.", id: 4),
            ])
    }

    /// The drawer's glass stands in as a flat tone, so "the card separates from the drawer" is
    /// asked of a realistic contrast rather than of black. It follows the appearance: a dark card
    /// measured against a white backdrop would only ever prove that white is lighter than grey.
    private static func backdrop(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.12) : Color(white: 0.98)
    }

    private func render(_ view: some View, height: CGFloat, scheme: ColorScheme) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width, height: height, alignment: .top)
                .background(Self.backdrop(scheme))
                .environment(\.colorScheme, scheme))
        renderer.scale = 2
        return try #require(renderer.cgImage, "the pile did not rasterise")
    }

    /// Grey values along one row, 0...255, in the image's own pixels.
    private func scanline(_ image: CGImage, y: Int) throws -> [Int] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (0..<image.width).map { Int(pixels[(y * image.width + $0) * 4]) }
    }

    /// The measurement that found the bug, run against the fix.
    ///
    /// Across the body of a closed three-card pile the old drawer laddered 241 → 229 → 217 as each
    /// buried plate composited through the front one. An opaque card has no ladder: whatever the
    /// front card's tone is, it is the same tone all the way across, because nothing behind it
    /// reaches the eye.
    @Test func aClosedPileShowsOneCardAndNotThreeStackedTones() throws {
        let image = try render(
            DayPileView(day: day, expanded: .constant(false)).padding(12),
            height: 150, scheme: .light)
        // A quarter down the pile: inside the front card, above its text, below its top edge.
        let row = try scanline(image, y: Int(Double(image.height) * 0.28))

        // Everything from the accent edge to the far side of the card, skipping the rounded corner
        // region and the border at each end.
        let interior = Array(row[60..<(image.width - 60)])
        let tones = Set(interior)
        #expect(tones.count == 1, "the card body is not one tone: \(tones.sorted())")
        // And that one tone is the opaque card, not the backdrop showing through.
        let card = try #require(tones.first)
        #expect(card >= 250, "the card is darker than an opaque white plate: \(card)")
    }

    /// The other half of the same defect: the buried cards' coloured edges used to draw at full
    /// strength through the front card, so a closed pile of three showed three different words'
    /// colours at once. Now that the *whole* border carries the colour, a pile could walk back into
    /// it on four sides instead of one — so the check is no longer "where is the colour" but
    /// **"how many different colours are there"**. A closed pile wears exactly one.
    ///
    /// Every row, not one. A first version scanned across the middle of the pile and passed even
    /// with `showsAccent` forced true for buried cards — the opaque front card hides them there, so
    /// it was measuring occlusion, which `aClosedPileShowsOneCardAndNotThreeStackedTones` already
    /// covers. The buried edges only ever show in the slivers peeking below, which is why this has
    /// to look at the whole pile.
    @Test func aClosedPileWearsExactlyOneWordsColour() throws {
        let image = try render(
            DayPileView(day: day, expanded: .constant(false)).padding(12),
            height: 150, scheme: .light)
        // Below the day header. It carries a tinted "Show All", measured in rows 31–47 of a
        // 300-row render against the pile's own 72–254 — a second colour, and not a card's.
        let hues = try huesPresent(in: image, below: Int(Double(image.height) * 0.25))
        // Asked separately, because "none" and "three" are different problems and the count alone
        // reads as the second. An accent faded past the point of being seen is the first.
        #expect(!hues.isEmpty, "no colour at all — the accent may be too faint to register")
        #expect(hues.count == 1, "more than one word's colour is on show: bins \(hues.sorted())")
    }

    /// Which hues appear anywhere in the image, in twenty-four bins.
    ///
    /// By hue rather than by RGB because antialiasing blends a coloured edge towards the card
    /// behind it: those pixels are paler versions of the same colour, and bucketing on RGB would
    /// count each blend as a colour of its own.
    private func huesPresent(
        in image: CGImage, below firstRow: Int, bins: Int = 24, floor: Int = 20
    ) throws -> Set<Int> {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        var counts: [Int: Int] = [:]
        for index in stride(from: firstRow * image.width * 4, to: pixels.count, by: 4) {
            let red = Double(pixels[index]), green = Double(pixels[index + 1])
            let blue = Double(pixels[index + 2])
            let high = max(red, green, blue), low = min(red, green, blue)
            // A grey pixel has no hue to speak of: the card, the drawer, the text and the shadow.
            guard high - low > 25 else { continue }
            let span = high - low
            var hue: Double
            if high == red { hue = (green - blue) / span }
            else if high == green { hue = 2 + (blue - red) / span }
            else { hue = 4 + (red - green) / span }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            counts[Int(hue * Double(bins)) % bins, default: 0] += 1
        }
        // A handful of pixels is a blend across a boundary, not a colour the reader sees.
        return Set(counts.filter { $0.value >= floor }.keys)
    }

    /// A card is **raised** against the drawer, never a recessed patch of it.
    ///
    /// This is the design decision, in the one form that can be checked: the card's fill is lighter
    /// than what it sits on, in both appearances. The wash it replaced was darker than the drawer
    /// (237 against 250), which is what made it read as a stain rather than as a surface.
    @Test func aCardIsLighterThanTheDrawerItSitsOn() throws {
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let image = try render(card.padding(12), height: 90, scheme: scheme)
            let drawer = try scanline(image, y: 2)[2]
            #expect(interior(of: image) > drawer, "\(scheme): the card is darker than the drawer")
        }
    }

    /// Being lighter is not enough on its own. In a light appearance a white card on near-white
    /// glass is a five-step difference — the edge is carried entirely by the border and the lift,
    /// which makes those two load-bearing in a way they were not before, and therefore worth a
    /// guard. Measured at 26; it collapses to 5 if both are dropped as redundant.
    ///
    /// It does **not** catch the transparent wash this replaced — that one had a perfectly visible
    /// border too. `aClosedPileShowsOneCardAndNotThreeStackedTones` is what catches that.
    @Test func theEdgeOfACardIsVisibleWithoutRelyingOnItsFill() throws {
        let image = try render(card.padding(12), height: 90, scheme: .light)
        // Down a column clear of the word, the sentence and the time, so every step it crosses
        // belongs to the card's edge rather than to its text.
        let column = try columnScan(image, x: Int(Double(image.width) * 0.62))
        let step = zip(column, column.dropFirst()).map { abs($0 - $1) }.max() ?? 0
        #expect(step >= 20, "the card's edge has faded into the drawer: \(step)")
    }

    private var card: ReadingCardView {
        ReadingCardView(entry: entry("hold", "The ship's hold was full.", id: 1))
    }

    private func columnScan(_ image: CGImage, x: Int) throws -> [Int] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (0..<image.height).map { Int(pixels[($0 * image.width + x) * 4]) }
    }

    /// The card's own fill: the commonest tone across its body, which text, the border and the
    /// accent are all far too few pixels to shift.
    private func interior(of image: CGImage) -> Int {
        var counts: [Int: Int] = [:]
        for y in stride(from: image.height / 4, to: image.height * 3 / 4, by: 2) {
            for tone in (try? scanline(image, y: y))?.dropFirst(40).dropLast(40) ?? [] {
                counts[tone, default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key ?? 0
    }

    /// Grey values down one column, 0...255, in the image's own pixels.
    private func column(_ image: CGImage, x: Int) throws -> [Int] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (0..<image.height).map { Int(pixels[($0 * image.width + x) * 4]) }
    }

    /// **Every plate peeks by the same amount — which the arithmetic could not guarantee on its
    /// own.**
    ///
    /// `CardPile` places each buried plate at the *front* card's height precisely so the slivers
    /// below line up evenly, and `CardPileTests` has always confirmed that it does. But a proposed
    /// height is only a proposal: `ReadingCardView` carried no height constraint, so each plate
    /// drew at its own content's height and peeked by however tall its own word happened to make
    /// it. Measured in the closed pile with a front card one line taller than the two behind it:
    /// the first plate peeked 2.5 pt and the second 7.5 pt, three times the difference, while
    /// every unit test passed.
    ///
    /// The front card is deliberately given a sentence that wraps and the buried ones sentences
    /// that do not. With three equal-height cards the defect cannot appear at all, which is why it
    /// survived the pile's other render tests.
    ///
    /// Read in a column inside the card's own padding, where no text can fall: each card's bottom
    /// border is a drop in brightness, and the gaps between those drops are the peeks.
    @Test func everyPlatePeeksByTheSameAmount() throws {
        let wrapping = entry(
            "temper", "Justice tempered with mercy, and tempered again by a much longer "
                + "sentence that is certain to wrap onto a second line.", id: 1)
        let stacked = ReadingDay(
            id: "2026-09-19", date: .distantPast, label: .yesterday,
            entries: [wrapping, entry("rein", "A tight rein.", id: 2),
                      entry("table", "They tabled it.", id: 3)])
        let image = try render(
            DayPileView(day: stacked, expanded: .constant(false)).padding(12),
            height: 260, scheme: .light)

        // Down the middle, not near an edge: a column close to the deepest plate's side lands on
        // its rounded corner, where a bottom edge is a curve rather than a row and the gaps read
        // 15 px then 13 px on a pile that is actually even.
        let tones = try column(image, x: image.width / 2)
        let drops = (1..<tones.count).filter { tones[$0 - 1] - tones[$0] >= 12 }
        // The front card's bottom edge, then each plate's.
        #expect(drops.count >= 3, "found \(drops.count) card edges, expected at least 3")
        let bottoms = Array(drops.suffix(3))
        let first = bottoms[1] - bottoms[0]
        let second = bottoms[2] - bottoms[1]
        #expect(abs(first - second) <= 1,
                "the plates peek unevenly: \(first) px then \(second) px")
    }
}
