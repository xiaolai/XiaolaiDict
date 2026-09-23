import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import XiaolaiDictCore
@testable import XiaolaiDictUI
import XiaolaiDictTestSupport

/// The reader's text size, the scale it produces, and — the part that is easy to get wrong — that
/// the views actually read it.
struct TextSizeTests {
    @Test func theSizesRunSmallestToLargestWithNoTies() {
        let ems = TextSize.allCases.map(\.em)
        #expect(ems == ems.sorted(), "the cases are not in order: \(ems)")
        #expect(Set(ems).count == ems.count, "two sizes are the same size: \(ems)")
    }

    /// A band, not exact values: the point is that no step is a size nobody can read, and that the
    /// range is wide enough to be worth offering. The platform's own small size is 11.
    @Test func everySizeIsOneSomebodyCouldRead() {
        for size in TextSize.allCases {
            #expect(size.em >= 11, "\(size) is below the platform's smallest UI size")
            #expect(size.em <= 18, "\(size) is larger than a window can lay out")
            #expect(!size.label.isEmpty, "\(size) has no name to show the reader")
        }
    }

    /// The default matters more than the extremes: it is what almost every reader will ever see.
    @Test func theDefaultIsTheOneTheDrawerWasDesignedAt() {
        #expect(TextSize.standard.em == 12)
        #expect(Scale.standard.em == TextSize.standard.em)
    }

    // MARK: - The scale

    /// The whole reason for one root: the *proportions* have to survive a resize. If padding grew
    /// on a different curve from type, every size but the designed one would be a different design.
    @Test func everySizeIsTheSameDesignAtADifferentSize() {
        for size in TextSize.allCases {
            let scale = Scale(size)
            #expect(abs(scale.space.padAcross / scale.em - 1.50) < 0.0001)
            #expect(abs(scale.space.stack / scale.em - 0.75) < 0.0001)
            #expect(abs(scale.text.strong / scale.em - 1.15) < 0.0001)
            #expect(abs(scale.radius.card / scale.em - 0.90) < 0.0001)
        }
    }

    @Test func alargerSizeIsLargerEverywhere() {
        let small = Scale(.compact)
        let large = Scale(.large)
        #expect(large.text.body > small.text.body)
        #expect(large.space.pad.leading > small.space.pad.leading)
        #expect(large.shadow.cardRadius > small.shadow.cardRadius)
        #expect(large.space.peek > small.space.peek)
    }

    /// Vertical padding is deliberately less than horizontal — line-height already supplies air
    /// top-to-bottom and nothing supplies it side-to-side. It has to stay that way at every size.
    @Test func paddingStaysTighterDownThanAcrossAtEverySize() {
        for size in TextSize.allCases {
            let space = Scale(size).space
            #expect(space.padDown < space.padAcross, "\(size) padded square")
            #expect(space.pad.top == space.padDown)
            #expect(space.pad.leading == space.padAcross)
        }
    }

    // MARK: - Remembering it

    @Test func aReaderWhoHasNeverChosenGetsTheDefault() {
        #expect(TextSizeStore(defaults: TemporaryDefaults.suite()).load() == .standard)
    }

    @Test func aChosenSizeSurvivesTheNextLaunch() {
        let defaults = TemporaryDefaults.suite()
        TextSizeStore(defaults: defaults).save(.large)
        #expect(TextSizeStore(defaults: defaults).load() == .large)
    }

    /// A preference file written by a later version must not leave the reader with no text at all.
    @Test func anUnrecognisedSizeFallsBackRatherThanFailing() {
        let defaults = TemporaryDefaults.suite()
        defaults.set("enormous", forKey: TextSizeStore.defaultsKey)
        #expect(TextSizeStore(defaults: defaults).load() == .standard)
    }

    @MainActor
    @Test func changingTheSizeWritesItDownWithoutBeingAsked() {
        let defaults = TemporaryDefaults.suite()
        let appearance = Appearance(store: TextSizeStore(defaults: defaults))
        appearance.textSize = .comfortable
        #expect(TextSizeStore(defaults: defaults).load() == .comfortable)
        #expect(appearance.scale.em == TextSize.comfortable.em)
    }
}

/// That the views read the scale, rather than having it read past them.
///
/// This is the test the whole change needs. Every other one here checks a number; a view that
/// still referenced a constant would pass all of them and draw at one size forever. The only proof
/// is a card rendered at two sizes coming out different.
@MainActor
struct ScaledRenderTests {
    private var card: some View {
        let sentence = "The ship's hold was full."
        return ReadingCardView(entry: ReadingEntry(
            id: 1, lemma: "hold", surface: "hold", sentence: sentence,
            sentenceRange: (sentence as NSString).range(of: "hold"),
            place: ReadingPlace(name: "Safari", title: "A page"), at: .distantPast,
            result: .found,
            quality: .accessibility(.accessibilityTextRange, context: .complete)))
    }

    /// Rows containing any of the card's own white, and pixels dark enough to be a glyph.
    private func measure(at size: TextSize) throws -> (height: Int, ink: Int) {
        let renderer = ImageRenderer(
            content: card
                .environment(\.scale, Scale(size))
                .frame(width: 320, height: 240, alignment: .top)
                .background(Color(white: 0.90))
                .environment(\.colorScheme, ColorScheme.light))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)

        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        var rows = 0
        var ink = 0
        for y in 0..<image.height {
            var onCard = false
            for x in 0..<image.width {
                let tone = Int(pixels[(y * image.width + x) * 4])
                if tone > 250 { onCard = true }
                if tone < 100 { ink += 1 }
            }
            if onCard { rows += 1 }
        }
        return (rows, ink)
    }

    @Test func aLargerTextSizeMakesATallerCardWithBiggerWordsOnIt() throws {
        let compact = try measure(at: .compact)
        let large = try measure(at: .large)

        // Taller, because padding and type both grew.
        #expect(large.height > compact.height,
                "the card did not grow: \(compact.height) → \(large.height) rows")
        // And the growth is the *text*, not only the padding — a view that scaled its box and kept
        // a fixed font would pass the height check on its own.
        #expect(large.ink > compact.ink,
                "the words did not grow: \(compact.ink) → \(large.ink) dark pixels")
    }

    /// Every size has to be a size the card survives, not just the two ends.
    @Test func noSizeCollapsesOrOverflowsTheCard() throws {
        var heights: [Int] = []
        for size in TextSize.allCases {
            let measured = try measure(at: size)
            #expect(measured.height > 0, "\(size) drew no card at all")
            #expect(measured.ink > 0, "\(size) drew a card with no words on it")
            heights.append(measured.height)
        }
        // Strictly increasing, not merely sorted. An all-equal array is sorted, so `== sorted()`
        // passed cleanly against a card that ignored the scale entirely — measured, not supposed.
        let growing = zip(heights, heights.dropFirst()).allSatisfy { $0 < $1 }
        #expect(growing, "the sizes do not each grow on the last: \(heights)")
    }
}

/// The lookup card's width, which has to grow with the text or stop being the right measure.
struct CardWidthTests {
    /// A fixed 400 pt is the right line length at one text size and too narrow at every larger
    /// one: the same width holds about sixty characters at `standard` and about forty-five at
    /// `large`. In ems the measure is the same at all four.
    @Test func theMeasureIsTheSameAtEverySize() {
        for size in TextSize.allCases {
            let space = Scale(size).space
            #expect(abs(space.cardWidth / Scale(size).em - 33) < 0.0001)
        }
    }

    @Test func aLargerTextSizeIsAWiderCard() {
        #expect(Scale(.large).space.cardWidth > Scale(.compact).space.cardWidth)
        #expect(Scale(.large).space.cardMinWidth > Scale(.compact).space.cardMinWidth)
    }

    /// The bounds have to stay in order, or a card can be asked to be wider than its own maximum.
    @Test func theBoundsStayInOrderAtEverySize() {
        for size in TextSize.allCases {
            let space = Scale(size).space
            #expect(space.cardMinWidth < space.cardWidth)
            #expect(space.cardWidth < space.cardMaxWidth)
        }
    }

    /// Wide enough for the sentence to be a cue rather than a column of single words, narrow
    /// enough that the eye finds the start of the next line.
    @Test func everySizeIsAReadableLineLength() {
        for size in TextSize.allCases {
            let space = Scale(size).space
            // Roughly characters, at about half an em each, less the card's own padding.
            let characters = (space.cardWidth - space.padAcross * 2) / (Scale(size).em * 0.5)
            #expect(characters >= 50, "\(size) sets too narrow a line: \(Int(characters)) chars")
            #expect(characters <= 75, "\(size) sets too wide a line: \(Int(characters)) chars")
        }
    }
}
