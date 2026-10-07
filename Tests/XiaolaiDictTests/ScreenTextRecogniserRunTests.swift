import Capture
import Foundation
import Testing
@testable import XiaolaiDict

/// **Which token of a run the reader meant — the thing Vision cannot say and the pointer can.**
///
/// Measured 2026-09-30: `VNRecognizedText.boundingBox(for:)` resolves only to whitespace-delimited
/// runs. Asked for the six tokeniser words cut from `/Users/alice/github/xiaolai/myprojects/`
/// `xiaolaidict` it returned `x 0.0111 … 0.7667` for every one of them, and one box likewise for
/// the four words of `state-of-the-art`. Stored per word those tie on every comparison, and
/// `RecognisedTextPicker` keeps the first — so pointing anywhere in the path looked up `Users`.
///
/// It bit only where nothing exposes its text, which is where OCR is the whole path: a terminal,
/// a canvas, an image. Reported from Ghostty.
struct ScreenTextRecogniserRunTests {
    private static let region = CGSize(width: 1000, height: 1000)
    private static let path = "/Users/alice/github/xiaolai/myprojects/xiaolaidict"

    /// One run, boxed whole — exactly what Vision hands back for text with no spaces in it.
    private static func line(_ text: String, x: CGFloat, width: CGFloat) -> RecognisedLine {
        let box = CGRect(x: x, y: 0.4, width: width, height: 0.05)
        return RecognisedLine(
            text: text, box: box,
            runs: [RecognisedRun(text: text, utf16Offset: 0, box: box)],
            confidence: 1)
    }

    /// The inverse of `CaptureGeometry.characterIndex`: where the pointer has to be to land on a
    /// given character of a run spread evenly across its box.
    private static func cursor(onCharacter index: Int, of line: RecognisedLine) -> CGPoint {
        let run = line.runs[0]
        let step = run.box.width / CGFloat(run.text.utf16.count)
        return CGPoint(x: run.box.minX + (CGFloat(index) + 0.5) * step, y: run.box.midY)
    }

    private static func read(_ line: RecognisedLine, onCharacter index: Int) -> Recognition? {
        ScreenTextRecogniser.reading(
            [line], pick: RecognisedPick(line: 0, run: 0),
            at: Self.cursor(onCharacter: index, of: line), region: Self.region,
            appName: nil, bundleID: nil)
    }

    /// **The defect, as its counterexample.** `xiaolai` runs from 20 to 26 in that path; every one
    /// of those characters used to answer `Users`, because the run's start was what was segmented.
    @Test func aSegmentOfAPathAnswersItselfNotThePathsFirstSegment() throws {
        let line = Self.line(Self.path, x: 0.1, width: 0.5)
        for character in 20..<27 {
            let read = try #require(Self.read(line, onCharacter: character))
            #expect(read.word.word == "xiaolai",
                    "character \(character) of the path read as \(read.word.word)")
        }
    }

    /// And the first segment is still reached from its own characters — the fix must not simply
    /// move the error along by one.
    @Test func theFirstSegmentIsStillReachedFromItsOwnCharacters() throws {
        let line = Self.line(Self.path, x: 0.1, width: 0.5)
        let read = try #require(Self.read(line, onCharacter: 3))
        #expect(read.word.word == "Users")
        let last = try #require(Self.read(line, onCharacter: 45))
        #expect(last.word.word == "xiaolaidict")
    }

    /// **Not only paths.** A hyphenated compound is one run too, so its later halves were
    /// unreachable — and unlike a path, this is ordinary prose a reader looks words up in.
    @Test func aHyphenatedCompoundAnswersTheHalfUnderThePointer() throws {
        let line = Self.line("state-of-the-art", x: 0.2, width: 0.3)
        #expect(try #require(Self.read(line, onCharacter: 1)).word.word == "state")
        #expect(try #require(Self.read(line, onCharacter: 14)).word.word == "art")
        #expect(try #require(Self.read(line, onCharacter: 10)).word.word == "the")
    }

    /// The pointer on a separator reads the word to its left rather than nothing: the `/` is one
    /// character wide, and a hover that answers nothing there reads as a broken hover.
    @Test func aSeparatorReadsTheWordBesideIt() throws {
        let line = Self.line(Self.path, x: 0.1, width: 0.5)
        #expect(try #require(Self.read(line, onCharacter: 19)).word.word == "github")
    }

    /// A run with several words in it still reports the whole line as its sentence — the choice of
    /// token must not narrow what the reader is shown the word in.
    @Test func theSentenceIsStillTheWholeLine() throws {
        let line = Self.line(Self.path, x: 0.1, width: 0.5)
        let read = try #require(Self.read(line, onCharacter: 23))
        #expect(read.word.sentence.text == Self.path, "got \(read.word.sentence.text)")
    }

    /// **Runs are what Vision boxes**: maximal spans of non-whitespace, not the tokeniser's words.
    /// Splitting them finer is what produced boxes that could not be told apart.
    @Test func runsAreTheWhitespaceDelimitedSpans() {
        func runs(_ text: String) -> [String] {
            ScreenTextRecogniser.runs(in: text).map { String(text[$0]) }
        }
        #expect(runs("a well-known mass-produced item")
                == ["a", "well-known", "mass-produced", "item"])
        #expect(runs(Self.path) == [Self.path])
        #expect(runs("  leading and\ttrailing \n") == ["leading", "and", "trailing"])
        #expect(runs("   ").isEmpty)
        #expect(runs("").isEmpty)
    }

    /// **Why the unit has to be the run.** Kept per tokeniser word, the boxes Vision returns are
    /// identical, so every comparison in `pick` ties and the first index wins — whatever the reader
    /// pointed at. This is the shape the recogniser used to build, asserted so that rebuilding it
    /// cannot pass.
    @Test func boxesThatCannotBeToldApartAlwaysPickTheFirst() throws {
        let box = CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.05)
        let asWords = RecognisedLine(
            text: Self.path, box: box,
            runs: ["Users", "alice", "github", "xiaolai"].map {
                RecognisedRun(
                    text: $0, utf16Offset: (Self.path as NSString).range(of: $0).location, box: box)
            },
            confidence: 1)
        let picked = try #require(RecognisedTextPicker.pick(
            at: CGPoint(x: 0.45, y: box.midY), in: [asWords], region: Self.region))
        #expect(picked == RecognisedPick(line: 0, run: 0),
                "the tie broke somewhere other than the first index, so the fixture is stale")
    }

    /// Offsets are into the line, so a run after the first is segmented at its own position.
    @Test func aLaterRunIsSegmentedWhereItActuallySits() throws {
        let text = "the state-of-the-art rig"
        let box = CGRect(x: 0.2, y: 0.4, width: 0.16, height: 0.05)
        let line = RecognisedLine(
            text: text, box: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.05),
            runs: [RecognisedRun(
                text: "state-of-the-art",
                utf16Offset: (text as NSString).range(of: "state-of-the-art").location,
                box: box)],
            confidence: 1)
        let step = box.width / 16
        let read = try #require(ScreenTextRecogniser.reading(
            [line], pick: RecognisedPick(line: 0, run: 0),
            at: CGPoint(x: box.minX + 14.5 * step, y: box.midY), region: Self.region,
            appName: nil, bundleID: nil))
        #expect(read.word.word == "art", "got \(read.word.word)")
        #expect(read.word.sentence.text == text)
    }
}
