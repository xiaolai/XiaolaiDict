import Capture
import CoreGraphics
import DictionaryModel
import Foundation
import Testing
@testable import MacCapture

/// **The context quality says whether the strip reached the sentence's ends — and it used to say `complete` when the
/// strip had simply run out.** The owner's ledger, 2026-10-11: a terminal command soft-wrapped over about eight rows
/// was stored from its bullet to `pkill`, mid-command, as `complete` at confidence 1.0, and 4 of 94 optical rows were
/// ever `mayBeCut`. A 140 pt band centred on the first row of a five-row paragraph about 100 pt tall read three rows.
///
/// Synthetic text at the measured geometry: rows 14 pt tall on a 20 pt pitch, a window 2672 pt wide.
struct StripReadingTests {
    private static let sentence = "The keeper of the northern light counted every ship that passed the rocks after "
        + "dusk and wrote each name into a ledger whose pages had gone soft with salt and lamp smoke "
        + "until the winter storms closed the harbour and nothing sailed again before spring."
    private static let other = "A different pane holds a different story about a market town whose clock ran fast."

    /// The rows of `text`, wrapped at `columns` characters, from `top` at `x`.
    private static func rows(_ text: String, x: CGFloat, top: CGFloat, columns: Int) -> [(String, CGFloat, CGFloat)] {
        var rows: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if !current.isEmpty, current.count + 1 + word.count > columns { rows.append(current); current = "" }
            current += current.isEmpty ? String(word) : " " + word
        }
        if !current.isEmpty { rows.append(current) }
        return rows.enumerated().map { ($0.element, x, top + CGFloat($0.offset) * 20) }
    }

    /// What a strip `top ..< top + height` of a 2672 pt window reads: the rows wholly inside it, normalised.
    private static func strip(_ rows: [(String, CGFloat, CGFloat)], top: CGFloat, height: CGFloat)
        -> (lines: [RecognisedLine], region: CGSize) {
        let region = CGSize(width: 2672, height: height)
        let lines = rows.filter { $0.2 >= top && $0.2 + 14 <= top + height }.map { text, x, y -> RecognisedLine in
            var runs: [RecognisedRun] = []
            var offset = 0
            for piece in text.split(separator: " ", omittingEmptySubsequences: false) {
                if !piece.isEmpty {
                    runs.append(RecognisedRun(
                        text: String(piece), utf16Offset: offset,
                        box: CGRect(x: (x + CGFloat(offset) * 8) / region.width, y: (y - top) / height,
                                    width: CGFloat(piece.count) * 8 / region.width, height: 14 / height)))
                }
                offset += piece.utf16.count + 1
            }
            return RecognisedLine(
                text: text, box: CGRect(x: x / region.width, y: (y - top) / height,
                                        width: CGFloat(text.count) * 8 / region.width, height: 14 / height),
                runs: runs)
        }
        return (lines, region)
    }

    private static func read(
        _ rows: [(String, CGFloat, CGFloat)], top: CGFloat, height: CGFloat, word: String
    ) throws -> Recognition {
        let (lines, region) = strip(rows, top: top, height: height)
        let line = try #require(lines.firstIndex { $0.runs.contains { $0.text.hasPrefix(word) } })
        let run = try #require(lines[line].runs.firstIndex { $0.text.hasPrefix(word) })
        let box = lines[line].runs[run].box
        return try #require(ScreenTextRecogniser.reading(
            lines, pick: RecognisedPick(line: line, run: run), at: CGPoint(x: box.midX, y: box.midY),
            region: region, appName: nil, bundleID: nil))
    }

    /// **The positive control, red before this change**: the 140 pt band cuts the paragraph and must not say
    /// `complete`, and it asks for the side that was cut.
    @Test func aOneFortyPointBandThatCutsTheParagraphSaysSo() throws {
        let rows = Self.rows(Self.sentence, x: 40, top: 400, columns: 60)
        let read = try Self.read(rows, top: 400 - 70, height: 140, word: "keeper")
        #expect(read.word.sentence.text != Self.sentence)
        #expect(read.mayBeCut, "a cut paragraph was reported complete: \(read.word.sentence.text)")
        #expect(read.word.sentence.mayBeCut == read.mayBeCut)
        #expect(read.wantsMore == [.below], "wants \(read.wantsMore)")
        #expect(read.word.sentence.cut == [.end], "cut \(read.word.sentence.cut)")
    }

    @Test func aThreeHundredPointStripReadsItWholeAndComplete() throws {
        let rows = Self.rows(Self.sentence, x: 40, top: 400, columns: 60)
        let read = try Self.read(rows, top: 400 - 150, height: 300, word: "keeper")
        #expect(read.word.sentence.text == Self.sentence, "\(read.word.sentence.text)")
        #expect(!read.mayBeCut)
        #expect(read.wantsMore.isEmpty)
    }

    /// The top edge alone: the strip begins inside the paragraph, so only the top may be cut and only it grows.
    @Test func theTopEdgeAloneAsksForTheTop() throws {
        let rows = Self.rows(Self.sentence, x: 40, top: 400, columns: 60)
        let read = try Self.read(rows, top: 438, height: 300, word: "soft")
        #expect(read.mayBeCut)
        #expect(read.wantsMore == [.above], "wants \(read.wantsMore)")
        #expect(read.word.sentence.cut == [.start], "cut \(read.word.sentence.cut)")
    }

    /// **An interior sentence is not cut by an open side it does not reach**, and asks for nothing.
    @Test func aSentenceThatEndsInsideTheStripAsksForNothing() throws {
        let text = Self.sentence + " The lamp was trimmed at dawn. Then the keeper slept."
        let rows = Self.rows(text, x: 40, top: 400, columns: 60)
        // The strip cuts the top of the paragraph; the pointer is in its last sentence, which starts inside it.
        let read = try Self.read(rows, top: 438, height: 300, word: "slept")
        #expect(read.word.sentence.text == "Then the keeper slept.", "\(read.word.sentence.text)")
        #expect(!read.mayBeCut)
        #expect(read.wantsMore.isEmpty)
    }

    /// The other pane never reaches the reader's sentence — which is also everything that may leave the Mac.
    @Test func theOtherPaneIsNotInTheSentence() throws {
        let rows = Self.rows(Self.sentence, x: 40, top: 400, columns: 60)
            + Self.rows(Self.other, x: 1500, top: 400, columns: 40)
        let read = try Self.read(rows, top: 300, height: 300, word: "keeper")
        #expect(read.word.sentence.text == Self.sentence, "\(read.word.sentence.text)")
        #expect(!read.word.sentence.text.contains("market"))
    }

    /// The strip's heights stay inside the deadline's reach and the tiling rule: full width, tiled as before.
    @Test @MainActor func theStripIsTallerThanTheOldBandAndBounded() {
        #expect(ContextStrip.initialHeight >= 2 * 140)
        #expect(ContextStrip.maximumHeight <= 600)
        #expect(ContextStrip.growthBudget < HoverReader.captureDeadline)
    }
}
