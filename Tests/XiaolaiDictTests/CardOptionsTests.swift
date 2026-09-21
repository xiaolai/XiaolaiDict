import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// What a card shows, and how it marks the word.
struct CardOptionsTests {
    /// The time is a fact the ledger keeps and the reader almost never wants: the day is already
    /// the group the card sits in. Off unless asked for.
    /// Both are facts the card can show and the reader almost never wants: the day is already the
    /// group a card sits in, and the icon says where faster than the name does.
    @Test func theTimeAndThePlaceNameAreOffUntilSomebodyAsksForThem() {
        #expect(CardOptions().showsTime == false)
        #expect(CardOptions().showsPlaceName == false)
        #expect(CardOptions().emphasis == .italic)
    }

    @Test func eachEmphasisIsADifferentSetting() {
        #expect(WordEmphasis.italic.isItalic)
        #expect(WordEmphasis.italic.weight == .regular)
        #expect(WordEmphasis.bold.isItalic == false)
        #expect(WordEmphasis.bold.weight == .semibold)
        #expect(WordEmphasis.boldItalic.isItalic)
        #expect(WordEmphasis.boldItalic.weight == .semibold)
        #expect(Set(WordEmphasis.allCases.map(\.label)).count == WordEmphasis.allCases.count)
    }

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "xiaolaidict-tests-\(UUID().uuidString)")!
    }

    @Test func bothChoicesSurviveTheNextLaunch() {
        let defaults = scratchDefaults()
        let store = TextSizeStore(defaults: defaults)
        #expect(store.loadShowsTime() == false)
        #expect(store.loadEmphasis() == .italic)

        #expect(store.loadShowsPlaceName() == false)

        store.save(showsTime: true)
        store.save(showsPlaceName: true)
        store.save(WordEmphasis.boldItalic)
        let reopened = TextSizeStore(defaults: defaults)
        #expect(reopened.loadShowsTime())
        #expect(reopened.loadShowsPlaceName())
        #expect(reopened.loadEmphasis() == .boldItalic)
    }

    @Test func anUnrecognisedEmphasisFallsBackRatherThanFailing() {
        let defaults = scratchDefaults()
        defaults.set("engraved", forKey: TextSizeStore.emphasisKey)
        #expect(TextSizeStore(defaults: defaults).loadEmphasis() == .italic)
    }

    @MainActor
    @Test func theAppearanceCarriesThemToTheCard() {
        let appearance = Appearance(store: TextSizeStore(defaults: scratchDefaults()))
        appearance.showsTime = true
        appearance.showsPlaceName = true
        appearance.emphasis = .bold
        #expect(appearance.cardOptions
                == CardOptions(showsTime: true, showsPlaceName: true, emphasis: .bold))
    }
}

/// Opening a word in Apple's own Dictionary.
struct SystemDictionaryTests {
    @MainActor
    @Test func atermBecomesADictionaryURL() {
        #expect(SystemDictionary.url(for: "hold")?.absoluteString == "dict://hold")
    }

    /// A looked-up term can be a phrase. Built by interpolation, those are exactly the words that
    /// would silently fail to open.
    @MainActor
    @Test func aTermWithASpaceIsEncodedRatherThanBroken() {
        let url = SystemDictionary.url(for: "force majeure")
        #expect(url?.absoluteString == "dict://force%20majeure")
        #expect(url != nil)
    }

    @MainActor
    @Test func thereIsNoURLForNothing() {
        #expect(SystemDictionary.url(for: "") == nil)
        #expect(SystemDictionary.url(for: "   \n ") == nil)
    }
}

/// The icon of the app a word was read in.
@MainActor
struct AppIconTests {
    /// Terminal ships with macOS, so this is a real lookup rather than a mock of one.
    @Test func anInstalledAppHasAnIcon() {
        AppIcons.forget()
        #expect(AppIcons.icon(for: "com.apple.Terminal") != nil)
    }

    @Test func nothingToLookUpIsNoIcon() {
        AppIcons.forget()
        #expect(AppIcons.icon(for: nil) == nil)
        #expect(AppIcons.icon(for: "") == nil)
        #expect(AppIcons.icon(for: "com.example.nothing-is-installed-here") == nil)
    }

    /// A miss is cached too. An app the reader has deleted would otherwise be searched for on
    /// every scroll, which is the expensive case rather than the cheap one.
    @Test func aMissIsRememberedAsAMiss() {
        AppIcons.forget()
        let id = "com.example.nothing-is-installed-here"
        #expect(AppIcons.icon(for: id) == nil)
        // Nothing to assert about speed here that would not be timing a test runner; what is
        // checkable is that the answer is stable, which is what the cache is for.
        #expect(AppIcons.icon(for: id) == nil)
    }

    /// Rasterised once at draw size, not handed over at 1024 pt for every card to shrink.
    @Test func theIconIsKeptAtTheSizeItIsDrawn() throws {
        AppIcons.forget()
        let icon = try #require(AppIcons.icon(for: "com.apple.Terminal"))
        #expect(icon.size.width <= 32)
        #expect(icon.size.height <= 32)
    }

    /// **The regression guard for a trap that reads as an app bug.**
    ///
    /// An app icon carries HDR representations, and one of them anywhere in a SwiftUI hierarchy
    /// switches the whole rendered output to `kCGColorSpaceITUR_2100_PQ`. Measured before the
    /// flattening: a 0.96 white backdrop came back at 146 instead of 245 — every pixel test with
    /// an icon in frame would have read as though the app had dimmed, and `ImageRenderer`'s
    /// `colorMode` does not change it.
    @Test func anIconDoesNotDragTheWholeRenderIntoHDR() throws {
        AppIcons.forget()
        let icon = try #require(AppIcons.icon(for: "com.apple.Terminal"))
        let renderer = ImageRenderer(content:
            HStack { Text("read in"); Image(nsImage: icon).resizable().frame(width: 12, height: 12) }
                .frame(width: 120, height: 40)
                .background(Color(white: 0.96))
                .environment(\.colorScheme, ColorScheme.light))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)

        let space = image.colorSpace?.name as String?
        #expect(space != (CGColorSpace.itur_2100_PQ as String), "the render went HDR: \(space ?? "nil")")

        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // The backdrop reads as the backdrop, which is the thing that was actually wrong.
        #expect(Int(pixels[(2 * image.width + 2) * 4]) > 230)
    }
}

/// That carrying a gloss is not the same as showing one.
///
/// C2 survives this change only if the card stays silent until the reader asks. The gloss now
/// travels all the way to the view, which is exactly the condition under which a rule like this
/// quietly stops holding — so it is checked in pixels rather than trusted.
@MainActor
struct HiddenGlossTests {
    private func card(gloss: String?) -> some View {
        let sentence = "Justice tempered with mercy."
        return ReadingCardView(entry: ReadingEntry(
            id: 1, lemma: "temper", surface: "temper", sentence: sentence,
            sentenceRange: (sentence as NSString).range(of: "temper"),
            place: ReadingPlace(name: "Safari", title: "A page"), at: .distantPast,
            result: .found,
            quality: .accessibility(.accessibilityTextRange, context: .complete),
            partOfSpeech: "verb",
            sense: SenseNote(
                dictionary: "NOAD", ordinal: 4, outOf: 12, gloss: gloss, chosenBy: .reader)))
    }

    private func height(gloss: String?) throws -> Int {
        try cardRows(card(gloss: gloss))
    }

    /// A gloss long enough to add several lines, against one short enough to add one. If either
    /// were being drawn, the two cards could not be the same height.
    @Test func aCardIsTheSameHeightWhateverMeaningItIsCarrying() throws {
        let short = try height(gloss: "a force")
        let long = try height(gloss: String(repeating: "a neutralizing force. ", count: 12))
        #expect(short == long, "the gloss is being drawn unasked: \(short) vs \(long) rows")
    }

    /// And a card carrying nothing to reveal is the same height again — so the space is not being
    /// reserved for it either, which would be the answer leaking as a layout hint.
    @Test func acardWithNothingToRevealIsNotShorter() throws {
        #expect(try height(gloss: nil) == (try height(gloss: "a force")))
    }
}

/// How many pixel rows a card occupies, measured rather than asked for.
///
/// Shared, because two different rules are checked by comparing one card's height against
/// another's: that a gloss is not drawn unasked, and that the provenance does not take a row of
/// its own. A card is drawn on a grey field and its own near-white fill is what gets counted.
@MainActor
func cardRows(_ card: some View) throws -> Int {
    let renderer = ImageRenderer(content:
        card
            .frame(width: 360, height: 320, alignment: .top)
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
    for y in 0..<image.height {
        for x in 0..<image.width where Int(pixels[(y * image.width + x) * 4]) > 250 {
            rows += 1
            break
        }
    }
    return rows
}

/// That saying where a word was read costs the card no height.
///
/// The provenance — the source app's icon, and the place and time when the reader asks for them —
/// used to be a row of its own at the bottom of the card. With the name and the time both off,
/// which is the default, that row held one 11 pt icon under a full-width card and the bottom of
/// every card was empty. It now rides the last line of the reader's own sentence.
///
/// **Checked by height, because that is the thing that regresses.** Moving it back into its own
/// row would not break a single assertion about what the card contains; it would just quietly make
/// every card taller again.
@MainActor
struct ProvenanceRowTests {
    private func card(bundleID: String?, options: CardOptions = CardOptions()) -> some View {
        let sentence = "Justice tempered with mercy."
        return ReadingCardView(entry: ReadingEntry(
            id: 1, lemma: "temper", surface: "temper", sentence: sentence,
            sentenceRange: (sentence as NSString).range(of: "temper"),
            place: ReadingPlace(bundleID: bundleID, name: "Safari"), at: .distantPast,
            result: .found,
            quality: .accessibility(.accessibilityTextRange, context: .complete),
            partOfSpeech: "verb",
            sense: SenseNote(
                dictionary: "NOAD", ordinal: 4, outOf: 12, gloss: nil, chosenBy: .reader)))
        .environment(\.cardOptions, options)
    }

    /// An icon and no icon come to the same height: the icon is sitting on a line that already
    /// existed rather than adding one.
    @Test func showingWhereAWordWasReadAddsNoRow() throws {
        let withIcon = try cardRows(card(bundleID: "com.apple.Safari"))
        let without = try cardRows(card(bundleID: nil))
        #expect(withIcon == without,
                "provenance is taking a row of its own again: \(withIcon) vs \(without) rows")
    }

    /// And so do the place and the time the reader can switch on — they join the same line.
    @Test func theNameAndTimeJoinThatLineToo() throws {
        let bare = try cardRows(card(bundleID: "com.apple.Safari"))
        let verbose = try cardRows(card(
            bundleID: "com.apple.Safari",
            options: CardOptions(showsTime: true, showsPlaceName: true)))
        #expect(bare == verbose, "the name and time added a row: \(bare) vs \(verbose) rows")
    }
}

/// The reader's word for a part of speech, against the dictionaries' word for it.
struct PartOfSpeechLabelTests {
    /// The four the ledger stores are translated for the reader; the stored vocabulary is not.
    @Test func theStoredVocabularyIsTranslatedForDisplayOnly() {
        #expect(PartOfSpeechLabel.reader("noun") != nil)
        #expect(PartOfSpeechLabel.reader("verb") != nil)
        #expect(PartOfSpeechLabel.reader("adjective") != nil)
        #expect(PartOfSpeechLabel.reader("adverb") != nil)
    }

    /// Nothing stored is nothing shown — the card says nothing where nothing is known.
    @Test func nothingStoredIsNothingShown() {
        #expect(PartOfSpeechLabel.reader(nil) == nil)
    }

    /// A word a dictionary blocks by something this view has never heard of is still shown. It
    /// came from a dictionary, and a reader can read it.
    @Test func anUnknownVocabularyIsShownRatherThanDropped() {
        #expect(PartOfSpeechLabel.reader("preposition") == "preposition")
    }
}
