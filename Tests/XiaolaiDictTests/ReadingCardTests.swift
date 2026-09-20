import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// The colour a word carries on its card.
///
/// It is decoration with a job — telling one card from the next at a glance — so the two things
/// worth checking are that a word keeps the same colour forever, and that two colours are far
/// enough apart to be told apart at all.
struct ReadingAccentTests {
    private func entry(_ lemma: String, result: LookupResult = .found) -> ReadingEntry {
        ReadingEntry(
            id: 1, lemma: lemma, surface: lemma, sentence: "A sentence.", sentenceRange: nil,
            place: ReadingPlace(name: "TextEdit"), at: .distantPast, result: result, quality: nil)
    }

    /// Pinned to literal indices on purpose. The hash has to be the *same hash* in every process —
    /// `Hasher` is seeded per launch, and a word that changes colour on every start reads as a bug.
    /// Computed independently from the FNV-1a 64 specification, not from the Swift that implements
    /// it, so this fails if the implementation drifts from the algorithm it claims to be.
    @Test func aWordKeepsTheSameColourInEveryProcess() {
        #expect(ReadingPalette.index(for: "table") == 0)
        #expect(ReadingPalette.index(for: "qqqq") == 1)
        #expect(ReadingPalette.index(for: "ephemeral") == 3)
        #expect(ReadingPalette.index(for: "hold") == 4)
        #expect(ReadingPalette.index(for: "temper") == 5)
    }

    @Test func spellingItWithCapitalsIsTheSameWord() {
        #expect(ReadingPalette.index(for: "Hold") == ReadingPalette.index(for: "hold"))
        #expect(ReadingPalette.index(for: "HOLD") == ReadingPalette.index(for: "hold"))
    }

    @Test func everyIndexLandsInThePalette() {
        for word in ["a", "", "hold", "屹立", "ß", String(repeating: "x", count: 500)] {
            let index = ReadingPalette.index(for: word)
            #expect(ReadingPalette.accents.indices.contains(index), "\(word) fell outside the palette")
        }
    }

    /// The reason the palette is a short curated list rather than `hue = hash % 360`: a free hue
    /// puts two words in the same drawer three degrees apart and calls them distinguishable.
    @Test func noTwoAccentsSitOnTopOfEachOther() {
        let accents = ReadingPalette.accents
        for (i, one) in accents.enumerated() {
            for other in accents[(i + 1)...] {
                let apart = abs(one.hue - other.hue)
                let circular = min(apart, 1 - apart)
                #expect(circular >= 0.09, "hues \(one.hue) and \(other.hue) are \(circular) apart")
            }
        }
    }

    /// A colour that only works in one appearance is half a colour. Light needs enough depth to
    /// show on a near-white card; dark needs enough luminance to show on a dark one.
    @Test func everyAccentIsLegibleInBothAppearances() {
        for accent in ReadingPalette.accents {
            #expect(accent.light.brightness <= 0.85, "too pale for a light card: \(accent.hue)")
            #expect(accent.light.saturation >= 0.55, "too washed out for a light card: \(accent.hue)")
            #expect(accent.dark.brightness >= 0.80, "too dim for a dark card: \(accent.hue)")
            #expect(accent.dark.saturation <= 0.75, "too muddy for a dark card: \(accent.hue)")
        }
    }

    /// A hash that piled every word onto two colours would pass the spacing test and still fail the
    /// reader. Seventy-odd ordinary words have to reach all of them.
    @Test func ordinaryWordsReachEveryColourInThePalette() {
        let words = """
            the be to of and a in that have it for not on with he as you do at this but his by from
            they we say her she or an will my one all would there their what so up out if about who
            get which go me hold ephemeral temper rein sanction table qqqq frost mercy budget motion
            ship page justice beauty morning cathedral velocity sanguine oblique tether fathom
            """.split(separator: " ").map(String.init)
        let used = Set(words.map { ReadingPalette.index(for: $0) })
        #expect(used.count == ReadingPalette.accents.count, "only \(used.count) colours were reached")
    }

    /// The colour is for telling words apart, not for decorating a failure.
    @Test func aMissIsNeverGivenAWordsColour() {
        #expect(ReadingPalette.accent(for: entry("qqqq", result: .notFound)) == nil)
        #expect(ReadingPalette.accent(for: entry("hold")) != nil)
    }
}

/// How a card is drawn, and — the part the screenshot caught — how the ones buried under it are.
struct ReadingCardSurfaceTests {
    /// **The load-bearing property of a card is that you cannot see through it.**
    ///
    /// The plate this replaced was `Color.primary.opacity(0.06)`, which measured 241 against a 250
    /// background: a 3.5% step, invisible as a surface and, worse, transparent. In a three-card
    /// pile the plates composited 241 → 229 → 217 inward, so the stack drew as nested boxes with
    /// two buried accent edges running through the front card's own text.
    @Test func aCardIsOpaqueInEveryAppearanceAndState() {
        for scheme in [ColorScheme.light, .dark] {
            for hovering in [false, true] {
                let plate = NSColor(CardSurface.fill(for: scheme, hovering: hovering))
                #expect(plate.alphaComponent == 1, "\(scheme) hovering=\(hovering) is see-through")
            }
        }
    }

    /// Hovering has to be visible without turning the card into a different surface.
    @Test func hoveringChangesTheCardWithoutChangingWhatItIs() {
        for scheme in [ColorScheme.light, .dark] {
            let resting = NSColor(CardSurface.fill(for: scheme, hovering: false))
                .usingColorSpace(.sRGB)!
            let hovered = NSColor(CardSurface.fill(for: scheme, hovering: true))
                .usingColorSpace(.sRGB)!
            let shift = abs(resting.brightnessComponent - hovered.brightnessComponent)
            #expect(shift >= 0.03, "\(scheme): hover is invisible")
            #expect(shift <= 0.12, "\(scheme): hover looks like a different control")
        }
    }

    /// A card has to separate from the drawer, which in a light appearance is roughly as light as
    /// the card is — so the separation cannot come from the fill alone.
    @Test func aCardCarriesItsOwnEdgeAndLift() {
        #expect(Token.Opacity.border > 0.08)
        #expect(Token.Opacity.cardShadow > 0)
        #expect(Scale.standard.shadow.cardRadius > 0)
    }

    /// The whole edge is the word's colour now, not one side of it — so the rule that kept three
    /// accents out of a closed pile has to hold on the border instead.
    ///
    /// Asserted on the rendered hue, not on `Color` equality: `accent.opacity(1)` is a different
    /// `Color` value from `accent` while being the same colour on screen, so `==` answered "no" to
    /// a border that was in fact the word's own. What matters is what reaches the eye.
    @Test func onlyAFrontCardsBorderCarriesTheWordsColour() throws {
        let read = ReadingEntry(
            id: 1, lemma: "hold", surface: "hold", sentence: "The ship's hold was full.",
            sentenceRange: nil, place: ReadingPlace(name: "TextEdit"), at: .distantPast,
            result: .found, quality: nil)
        let word = try #require(ReadingPalette.accent(for: read))

        let front = try #require(
            NSColor(CardSurface.border(for: read, layer: .front, in: .light))
                .usingColorSpace(.sRGB))
        #expect(abs(front.hueComponent - word.hue) < 0.02, "the front edge is not the word's hue")

        let buried = try #require(
            NSColor(CardSurface.border(for: read, layer: .buried, in: .light))
                .usingColorSpace(.sRGB))
        #expect(buried.saturationComponent < 0.05, "a buried card is wearing a colour")
    }
}

/// Which cards in a pile draw as cards, and which are only the shoulder the front one rests on.
struct CardLayerTests {
    private let pile = CardPile(spacing: 8, peek: 7, sideInset: 9, maxVisibleDepth: 2)

    /// The regression guard for the screenshot: a closed pile showed orange, blue *and* purple at
    /// once on a card labelled `temper`, because every buried card drew its own accent edge at full
    /// strength through the translucent front card. Exactly one card in a closed pile is a card.
    @Test func onlyTheFrontCardOfAClosedPileIsDrawnAsACard() {
        let layers = pile.layers(count: 3, expanded: false)
        #expect(layers == [.front, .buried, .buried])
        #expect(layers.filter { $0 == .front }.count == 1)
    }

    @Test func aFannedPileIsAllCards() {
        #expect(pile.layers(count: 4, expanded: true) == [.front, .front, .front, .front])
    }

    @Test func aPileOfOneIsJustACard() {
        #expect(pile.layers(count: 1, expanded: false) == [.front])
        #expect(pile.layers(count: 1, expanded: true) == [.front])
    }

    /// A pile is bounded work: a day with fifty words still builds three views, because the layout
    /// measures every subview it is given and forty-seven of them would be measured to be hidden.
    @Test func aDeepPileStillOnlyBuildsWhatShows() {
        #expect(pile.layers(count: 50, expanded: false).count == pile.maxVisibleDepth + 1)
        #expect(pile.layers(count: 50, expanded: true).count == 50)
    }

    @Test func nothingToPileIsNoLayers() {
        #expect(pile.layers(count: 0, expanded: false).isEmpty)
        #expect(pile.layers(count: -3, expanded: false).isEmpty)
    }

    /// A buried card is a plate: no words, no accent, and nothing for VoiceOver to read out — it is
    /// the same lookup as one of the cards the reader will see when the pile opens.
    @Test func aBuriedCardShowsNothingItCouldBeMisreadAs() {
        #expect(CardLayer.buried.showsContent == false)
        #expect(CardLayer.buried.showsAccent == false)
        #expect(CardLayer.front.showsContent)
        #expect(CardLayer.front.showsAccent)
    }
}
