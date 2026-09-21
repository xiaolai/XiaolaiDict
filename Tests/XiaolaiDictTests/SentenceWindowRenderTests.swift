import AppKit
import CoreGraphics
import SwiftUI
import Testing

@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// **The card shows the word**, checked on the card rather than on the arithmetic.
///
/// `SentenceExcerptTests` proves the window is computed correctly; it would pass just as well if
/// the card never asked for one. That gap is how the pause switch stayed dead for months under a
/// green suite, so this renders the card itself, with the sentence that was broken on a real row:
/// "ticket" at character 114 of 248, where a two-line card used to end at about 100.
///
/// The marked word is the only strongly coloured thing inside a card. Measured on this card: the
/// word's pixels reach a colour spread of 130, the grey text and icons stay near 0, and the border
/// — which shares the word's hue — is a pastel at the very edge, outside the region looked at. So
/// the card is found by its opaque white fill, and anything strongly coloured well inside it is
/// the word. A first version found the card by its coloured edge instead: the pastel border never
/// registered, the box came out empty, and building a range from it trapped the test runner.
@MainActor
struct SentenceWindowRenderTests {
    private let longSentence = "Two new ones: a cached build reusing a bundle signed without a "
        + "timestamp (#7), and a rebuild discarding a stapled ticket (#8). workflow: look for an "
        + "existing profile and at your other projects first, and read reference.md before writing "
        + "a pipeline."

    private func coloredPixelsInside(_ view: some View) throws -> Int {
        let renderer = ImageRenderer(content:
            view.frame(width: 360, height: 320, alignment: .top)
                .background(Color(white: 0.90))
                .environment(\.colorScheme, ColorScheme.light))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let (w, h) = (image.width, image.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let context = try #require(CGContext(
            data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func channels(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        // The card is its opaque white fill; the backdrop is a 0.90 grey.
        var (minX, minY, maxX, maxY) = (w, h, -1, -1)
        for y in 0..<h { for x in 0..<w {
            let (r, g, b) = channels(x, y)
            if min(r, g, b) >= 250 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        } }
        // Well inside it, past the hairline and the rounded corners. Guarded rather than trusted:
        // a card that did not draw is a failure to report, not a range to trap on.
        let inset = 16
        guard maxX - minX > 2 * inset, maxY - minY > 2 * inset else {
            Issue.record("no card was drawn to look inside (white area \(minX),\(minY)–\(maxX),\(maxY))")
            return 0
        }
        var inside = 0
        for y in (minY + inset)..<(maxY - inset) { for x in (minX + inset)..<(maxX - inset) {
            let (r, g, b) = channels(x, y)
            if max(r, g, b) - min(r, g, b) >= 100 { inside += 1 }
        } }
        return inside
    }

    @Test func aLongSentenceStillShowsItsWord() throws {
        let range = (longSentence as NSString).range(of: "ticket")
        #expect(range.location == 114, "the fixture no longer matches the measured row")
        let card = ReadingCardView(entry: ReadingEntry(
            id: 36, lemma: "ticket", surface: "ticket", sentence: longSentence, sentenceRange: range,
            place: ReadingPlace(name: "Ghostty"), at: .distantPast, result: .found,
            quality: .accessibility(.accessibilityTextRange, context: .complete),
            partOfSpeech: "noun", sense: nil))
        let word = try coloredPixelsInside(card)
        #expect(word > 0, "the card drew the reader's sentence without the word they looked up")
    }

    // MARK: - Which window the card chooses

    /// Rendered alone, at the width a card gives its sentence, and **under `fixedSize`, as the card
    /// sets it** — which proposes no height at all. Without that the harness proposed a height of
    /// its own, and the view chose correctly with or without the bound that exists for the card's
    /// case: a mutation removing it passed every test here. Plain text, so the comparison is of
    /// which window was chosen and nothing else.
    private func pixels(_ windows: [SentenceExcerpt], width: CGFloat = 300) throws -> [UInt8] {
        try render(windows, width: width).pixels
    }

    /// **Which window was drawn, by nearness rather than byte equality.** Two renders of the same
    /// window are not always byte-identical: measured, alongside the other tests here the same
    /// window came back 756 bytes different in 156,000 — 0.5% — in some runs and identical in
    /// others, while different windows differ by about 37,000 — 24%. Exact equality failed two runs
    /// in four on a correct choice. So the drawn image is matched to the window it is nearest, and
    /// only counts as that window when it is within a hundredth of the image of it.
    private func nearest(_ shown: [UInt8], among candidates: [[UInt8]]) -> Int? {
        let distances = candidates.map { candidate in
            candidate.count == shown.count ? zip(candidate, shown).filter { $0 != $1 }.count : Int.max
        }
        guard let best = distances.enumerated().min(by: { $0.element < $1.element }),
              best.element < shown.count / 100 else { return nil }
        return best.offset
    }

    private func render(_ windows: [SentenceExcerpt], width: CGFloat = 300) throws -> (pixels: [UInt8], height: CGFloat) {
        let renderer = ImageRenderer(content:
            SentenceWindowText(windows: windows, fullSentence: windows.first?.text ?? "") { AttributedString($0.text) }
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width, alignment: .topLeading)
                .background(Color.white)
                .environment(\.colorScheme, ColorScheme.light))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &px, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (px, CGFloat(image.height) / renderer.scale)
    }

    /// **A sentence that fits is shown whole.** Pixel-identical to the whole sentence on its own:
    /// the card chose it over every tighter window, so nothing — "did not" included — was cut.
    @Test func aSentenceThatFitsIsShownWhole() throws {
        let sentence = "He did not really mean to take the ticket."
        let windows = SentenceExcerpt.windows(sentence: sentence, marks: [(sentence as NSString).range(of: "ticket")])
        #expect(windows.count > 1, "the fixture must have tighter windows for the card to have refused")
        let singles = try windows.map { try pixels([$0]) }
        #expect(try nearest(pixels(windows), among: singles) == 0, "a sentence that fits two lines was cut")
    }

    /// **And one that does not fit is shown as one of the tighter windows, within the card's
    /// lines.** Both halves are asserted because each alone was passed by a broken view: with the
    /// height bound removed, the whole sentence ran to five lines — 85 points — and still differed
    /// from the whole sentence held to two, so "not the whole sentence" passed a card that had
    /// abandoned its line limit altogether.
    @Test func aSentenceThatDoesNotFitIsWindowed() throws {
        let windows = SentenceExcerpt.windows(
            sentence: longSentence, marks: [(longSentence as NSString).range(of: "ticket")])
        let shown = try render(windows)
        let singles = try windows.map { try pixels([$0]) }
        let chosen = nearest(shown.pixels, among: singles)
        #expect(chosen.map { $0 > 0 } == true, "the card showed \(chosen.map { "window \($0)" } ?? "no window") rather than a tighter one")
        let lines = Scale.standard.text.height(ofLines: Token.Limit.wrapLines)
        #expect(shown.height <= lines, "the sentence took \(shown.height) points, past the card's \(lines)")
    }
}
