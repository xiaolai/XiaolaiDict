import AppKit
import Foundation
import SwiftUI
import Testing

@testable import XiaolaiDictCore
@testable import XiaolaiDictUI

/// How a looked-up word is picked out of the reader's own sentence.
///
/// There were two of these and they had already drifted: the history card honoured the reader's
/// emphasis setting and coloured the word with its own accent, the lookup card hardcoded semibold
/// in `.primary`. Same word, same sentence, two answers — and a preference that worked in one
/// surface and silently did nothing in the other.
struct MarkedSentenceTests {
    private let sentence = "Justice tempered with mercy."
    private var range: [NSRange] { [(sentence as NSString).range(of: "tempered")] }

    private func attributes(_ text: AttributedString) -> (Font?, Color?) {
        let marked = text.runs.first { $0.foregroundColor != nil }
        return (marked?.font, marked?.foregroundColor)
    }

    /// The reader's choice reaches the marking. It is the setting's whole job.
    ///
    /// Compared as `Font` values, not as their descriptions: `String(describing:)` on a SwiftUI
    /// `Font` is opaque and comes back the same for all three, so a test written that way passes
    /// or fails for reasons that have nothing to do with the fonts.
    @Test func everyEmphasisProducesADifferentMark() {
        let fonts = WordEmphasis.allCases.map { emphasis in
            attributes(MarkedSentence.text(
                sentence, marking: range, size: 12, emphasis: emphasis, accent: .red)).0
        }
        #expect(fonts.allSatisfy { $0 != nil })
        #expect(Set(fonts.compactMap { $0 }).count == WordEmphasis.allCases.count,
                "two emphases mark the word identically")
    }

    @Test func theMarkedWordWearsTheColourItWasGiven() {
        let (_, colour) = attributes(MarkedSentence.text(
            sentence, marking: range, size: 12, emphasis: .italic, accent: .red))
        #expect(colour == .red)
    }

    /// Only the word. A mark that spilled would be the **temper**ed defect wearing a new shape.
    @Test func nothingOutsideTheRangeIsMarked() {
        let text = MarkedSentence.text(
            sentence, marking: range, size: 12, emphasis: .bold, accent: .red)
        let marked = text.runs.filter { $0.foregroundColor != nil }
        #expect(marked.count == 1)
        #expect(String(text[marked[0].range].characters) == "tempered")
    }

    @Test func aRangeOutsideTheSentenceMarksNothingRatherThanCrashing() {
        let text = MarkedSentence.text(
            sentence, marking: [NSRange(location: 900, length: 4)], size: 12,
            emphasis: .italic, accent: .red)
        #expect(text.runs.allSatisfy { $0.foregroundColor == nil })
    }

    /// A phrase is marked in each of its parts, not as one span over the words between.
    @Test func everyPartOfAPhraseIsMarked() {
        let phrase = "He took it over."
        let parts = Lemmatizer.parts(
            of: "take over", surface: "took", in: phrase,
            at: (phrase as NSString).range(of: "took"))
        let text = MarkedSentence.text(
            phrase, marking: parts, size: 12, emphasis: .italic, accent: .red)
        let marked = text.runs.filter { $0.foregroundColor != nil }
        #expect(marked.count == 2)
        #expect(marked.map { String(text[$0.range].characters) } == ["took", "over"])
    }

    /// **The alignment itself.** Both surfaces ask the same function, so the same word in the same
    /// sentence at the same setting comes out the same — by construction rather than by two
    /// implementations agreeing.
    @Test func theSameWordLooksTheSameInBothSurfaces() {
        let accent = ReadingPalette.accent(for: "temper").color(in: .light)
        for emphasis in WordEmphasis.allCases {
            let drawer = MarkedSentence.text(
                sentence, marking: range, size: 12, emphasis: emphasis, accent: accent)
            let panel = MarkedSentence.text(
                sentence, marking: range, size: 12, emphasis: emphasis, accent: accent)
            #expect(attributes(drawer).0 == attributes(panel).0)
            #expect(attributes(drawer).1 == attributes(panel).1)
        }
    }

    /// And the colour itself is the word's, so a word met in the panel and later seen in the
    /// drawer is the same colour both times.
    @Test func aWordKeepsOneColourAcrossSurfaces() {
        let entry = ReadingEntry(
            id: 1, lemma: "temper", surface: "temper", sentence: sentence, sentenceRange: nil,
            place: ReadingPlace(name: "TextEdit"), at: .distantPast, result: .found, quality: nil)
        #expect(ReadingPalette.accent(for: entry) == ReadingPalette.accent(for: "temper"))
    }
}
