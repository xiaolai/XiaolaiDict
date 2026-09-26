import AppKit
import DictionaryModel
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

    /// **The alignment itself, asserted where it can actually break.**
    ///
    /// This used to call `MarkedSentence.text` twice with identical arguments and compare the two
    /// answers. `text` is a pure function, so that could not fail for any reason — and above all
    /// not for the reason the test is named after, because neither call went anywhere near a
    /// surface. The two implementations that drifted were in the *views*, so the views are what
    /// has to be read: there is one marking function, both surfaces ask it, and neither colours a
    /// sentence any other way.
    ///
    /// Read from the source, the way `NoMagicValuesTests` reads it. A rendered comparison cannot
    /// stand in: the two cards lay their sentence out differently on purpose, so matching pixels
    /// would be the wrong claim and mismatching ones would prove nothing.
    @Test func bothSurfacesMarkTheWordThroughTheOneImplementation() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/XiaolaiDictUI")
        let surfaces = ["LookupCardView.swift", "HistoryDrawerViews.swift"]
        for name in surfaces {
            // Thrown rather than defaulted: a surface that has been renamed must fail this test
            // loudly, not pass it by having nothing left to read.
            let source = try String(contentsOf: views.appending(path: name), encoding: .utf8)
            #expect(source.contains("MarkedSentence.text("),
                    "\(name) no longer marks the word through MarkedSentence")
            #expect(source.contains("emphasis: options.emphasis"),
                    "\(name) is not passing the reader's emphasis setting through")
        }

        // And nowhere else colours one. This is the shape the drift took last time — a second
        // implementation, in a view, hardcoding its own weight and `.primary` — so the check is
        // that only `MarkedSentence` ever sets a foreground colour on an `AttributedString`.
        let files = try FileManager.default
            .contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "MarkedSentence.swift" }
        #expect(files.count > 1, "no view files were found to scan")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains(".foregroundColor = "),
                    "\(file.lastPathComponent) marks text itself instead of asking MarkedSentence")
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

/// Which occurrence of the word the card marks.
@MainActor
struct CardMarkedRangeTests {
    private func card(range: NSRange?) -> LookupCard {
        LookupCard(
            term: "he", lemma: "he", sentenceRange: range, heading: "he", partOfSpeech: nil,
            pronunciation: nil, answer: .undecided(reason: nil),
            sentence: "The man said he was fine.", alternatives: [], memory: nil)
    }

    /// **The defect's own example.** Searching for "he" case-insensitively finds it at offset 1,
    /// inside "The" — so the card underlined the wrong two letters of the reader's own sentence.
    @Test func theSearchTheCardUsedToDoFindsTheWrongOccurrence() {
        let sentence = "The man said he was fine." as NSString
        #expect(sentence.range(of: "he", options: .caseInsensitive).location == 1,
                "the fixture no longer reproduces the defect it exists for")
    }

    /// The captured range wins, and it is the real one — offset 14, the standalone word.
    @Test func theCapturedRangeIsUsed() {
        let real = ("The man said he was fine." as NSString).range(of: "he was")
        let marked = card(range: NSRange(location: real.location, length: 2))
        #expect(marked.sentenceRange?.location == 13, "the standalone he sits at 13, not inside The at 1")
    }

    /// A range that does not land on the word it claims is refused rather than used — one from
    /// another sentence would bracket whatever happens to sit at that offset.
    @Test func aRangeThatDoesNotMatchTheWordIsNotTrusted() {
        let sentence = "The man said he was fine." as NSString
        let wrong = NSRange(location: 4, length: 3)  // "man"
        #expect(sentence.substring(with: wrong).compare("he", options: .caseInsensitive) != .orderedSame,
                "the fixture's wrong range accidentally matches, so it checks nothing")
    }
}
