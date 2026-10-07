import Capture
import Foundation
import Testing
@testable import XiaolaiDict

/// **The quality signals must describe the sentence that is returned, and the CJK case is where
/// the arithmetic for that broke.**
///
/// The first attempt located the sentence by subtracting the word's offset-within-the-sentence
/// from the pointer's offset-within-the-block, assuming the pointer's offset is the word's start.
/// Joining `学` to `习。` produces `学习。`, which the tokeniser reads as one word beginning in the
/// *first* fragment — so the computed start fell inside the word, excluded the fragment the word
/// began in, and reported the good fragment's confidence for a sentence that is half badly read.
struct RecognitionScopeTests {
    private static let region = CGSize(width: 1000, height: 1000)

    /// A cursor at the left edge of the run the pick names.
    ///
    /// These tests are about the *scope* of the quality signals, not about which token of a run
    /// the reader meant — so they point at the run's first character, which is the reading the
    /// recogniser used to give wherever in a run the pointer was. `ScreenTextRecogniserRunTests`
    /// is where the choice itself is asserted.
    private static func atRun(_ pick: RecognisedPick, in lines: [RecognisedLine]) -> CGPoint {
        let box = lines[pick.line].runs[pick.run].box
        return CGPoint(x: box.minX, y: box.midY)
    }

    private static func fragment(
        _ text: String, x: CGFloat, width: CGFloat, confidence: Double
    ) -> RecognisedLine {
        let box = CGRect(x: x, y: 0, width: width, height: 10)
        return RecognisedLine(
            text: text, box: box,
            runs: [RecognisedRun(text: text, utf16Offset: 0, box: box)],
            confidence: confidence)
    }

    /// Both fragments make up the returned sentence, so its confidence is the worse of the two.
    @Test func aSentenceSpanningABadFragmentIsNotReportedAsGood() throws {
        let lines = [
            Self.fragment("学", x: 0, width: 10, confidence: 0.30),
            Self.fragment("习。", x: 10.5, width: 20, confidence: 1.0),
        ]
        let pick = RecognisedPick(line: 1, run: 0)
        let read = try #require(ScreenTextRecogniser.reading(
            lines, pick: pick, at: Self.atRun(pick, in: lines), region: Self.region,
            appName: nil, bundleID: nil))
        #expect(read.word.sentence.text == "学习。", "the row did not join: \(read.word.sentence.text)")
        #expect(read.confidence == 0.30, "reported \(read.confidence) for a sentence half read at 0.30")
    }

    /// And a neighbouring sentence's poor reading must not drag a good one down — the opposite
    /// error, and the reason the scope is the sentence rather than the block.
    @Test func aNeighbouringBadSentenceDoesNotMakeThisOneDoubtful() throws {
        let bad = RecognisedLine(
            text: "Rubbish here.", box: CGRect(x: 0, y: 0, width: 50, height: 10),
            runs: [RecognisedRun(text: "Rubbish", utf16Offset: 0,
                                   box: CGRect(x: 0, y: 0, width: 20, height: 10))],
            confidence: 0.30)
        let good = RecognisedLine(
            text: "The ship's hold was full.", box: CGRect(x: 0, y: 12, width: 50, height: 10),
            runs: [RecognisedRun(text: "hold", utf16Offset: 11,
                                   box: CGRect(x: 20, y: 12, width: 10, height: 10))],
            confidence: 1.0)
        let pick = RecognisedPick(line: 1, run: 0)
        let read = try #require(ScreenTextRecogniser.reading(
            [bad, good], pick: pick, at: Self.atRun(pick, in: [bad, good]), region: Self.region,
            appName: nil, bundleID: nil))
        #expect(read.word.sentence.text.contains("ship"), "\(read.word.sentence.text)")
        #expect(read.confidence == 1.0, "a good sentence was marked \(read.confidence) by its neighbour")
    }

    /// **One clipping answer.** What `Recognition` reports and what the sentence itself carries are
    /// the same fact; they used to be computed from different scopes and could disagree.
    @Test func theSentenceAndTheRecognitionAgreeAboutClipping() throws {
        let lines = [
            Self.fragment("学", x: 0, width: 10, confidence: 1.0),
            Self.fragment("习。", x: 10.5, width: 20, confidence: 1.0),
        ]
        let pick = RecognisedPick(line: 1, run: 0)
        let read = try #require(ScreenTextRecogniser.reading(
            lines, pick: pick, at: Self.atRun(pick, in: lines), region: Self.region,
            appName: nil, bundleID: nil))
        #expect(read.mayBeCut == read.word.sentence.mayBeCut,
                "Recognition says \(read.mayBeCut), the sentence says \(read.word.sentence.mayBeCut)")
    }
}

/// The two defects the round-2 verification found in the round-1 fixes, each as its counterexample.
extension RecognitionScopeTests {
    /// **A repeated sentence must be located by the occurrence the pointer is *in*.** Accepting an
    /// occurrence whose end equals the pointer's offset let the sentence *before* the pointer win:
    /// in `学习。学习。`, pointing at the second sentence's first character matched the first
    /// occurrence and reported its confidence.
    @Test func aRepeatedSentenceIsLocatedByThePointer() throws {
        let good = Self.fragment("学习。", x: 0, width: 30, confidence: 1.0)
        let bad = RecognisedLine(
            text: "学习。", box: CGRect(x: 30.5, y: 0, width: 30, height: 10),
            runs: [RecognisedRun(text: "学习", utf16Offset: 0,
                                   box: CGRect(x: 30.5, y: 0, width: 20, height: 10))],
            confidence: 0.30)
        let pick = RecognisedPick(line: 1, run: 0)
        let read = try #require(ScreenTextRecogniser.reading(
            [good, bad], pick: pick, at: Self.atRun(pick, in: [good, bad]), region: Self.region,
            appName: nil, bundleID: nil))
        #expect(read.confidence == 0.30,
                "the sentence before the pointer was scored instead: \(read.confidence)")
    }

    /// **An interior sentence of a clipped observation is not itself cut.** The geometric test says
    /// the observation touches the capture's edge; the sentence plainly does not run to the text's
    /// boundary. Reporting the geometric answer told the reader a whole interior sentence might be
    /// missing words.
    @Test func anInteriorSentenceOfAClippedLineIsNotMarkedCut() throws {
        let text = "First sentence. Middle sentence. Last sentence."
        let middle = (text as NSString).range(of: "Middle")
        // A box flush with the capture's edge, so the geometric clipping test fires.
        let box = CGRect(x: 0, y: 0, width: 1, height: 10)
        let line = RecognisedLine(
            text: text, box: box,
            runs: [RecognisedRun(text: "Middle", utf16Offset: middle.location, box: box)],
            confidence: 1.0)
        let pick = RecognisedPick(line: 0, run: 0)
        let read = try #require(ScreenTextRecogniser.reading(
            [line], pick: pick, at: Self.atRun(pick, in: [line]), region: Self.region,
            appName: nil, bundleID: nil))
        #expect(read.word.sentence.text.contains("Middle"), "\(read.word.sentence.text)")
        #expect(read.mayBeCut == read.word.sentence.mayBeCut, "the two answers disagree")
        #expect(!read.mayBeCut, "an interior sentence was reported as possibly cut")
    }
}

extension RecognitionScopeTests {
    /// **A sentence cut in its *middle* is still cut.** Making the two flags agree by taking the
    /// textual answer lost this: the sentence runs across two observations and the first is cut at
    /// its right edge, so words are missing between them — while the sentence touches neither end
    /// of the block, which is the only thing the textual answer looks at.
    @Test func aSentenceCutAtTheJunctionBetweenTwoLinesIsMarked() throws {
        func line(_ text: String, y: CGFloat, word: String) -> RecognisedLine {
            // Flush with the capture's right edge, which is what makes it clipped.
            let box = CGRect(x: 0.1, y: y, width: 0.9, height: 0.02)
            let at = (text as NSString).range(of: word)
            return RecognisedLine(
                text: text, box: box,
                runs: [RecognisedRun(text: word, utf16Offset: at.location, box: box)],
                confidence: 1.0)
        }
        let lines = [
            line("First sentence. The reader saw", y: 0.200, word: "reader"),
            line("a sentence missing words. Last sentence.", y: 0.225, word: "sentence"),
        ]
        let pick = RecognisedPick(line: 0, run: 0)
        let read = try #require(ScreenTextRecogniser.reading(
            lines, pick: pick, at: Self.atRun(pick, in: lines), region: Self.region,
            appName: nil, bundleID: nil))
        #expect(read.word.sentence.text.contains("reader saw"), "\(read.word.sentence.text)")
        #expect(read.mayBeCut, "a sentence spliced across a cut edge was reported whole")
    }
}

extension RecognitionScopeTests {
    private static func edged(_ text: String, word: String, x: CGFloat, width: CGFloat, y: CGFloat)
        -> RecognisedLine {
        let box = CGRect(x: x, y: y, width: width, height: 0.02)
        let at = (text as NSString).range(of: word)
        return RecognisedLine(
            text: text, box: box,
            runs: [RecognisedRun(text: word, utf16Offset: at.location, box: box)],
            confidence: 1.0)
    }

    /// **Two fragments side by side, safely inside the capture, are not cut between each other** —
    /// even though the first begins at the left margin. Asking whether any contributing
    /// observation touched *any* edge warned here, which teaches the reader to ignore the warning
    /// that matters.
    @Test func fragmentsBesideEachOtherAreNotCutBetweenThem() throws {
        let lines = [
            Self.edged("First sentence. The reader", word: "reader", x: 0.0, width: 0.400, y: 0.2),
            Self.edged("saw a complete sentence. Last sentence.", word: "saw", x: 0.405, width: 0.400, y: 0.2),
        ]
        let pick = RecognisedPick(line: 0, run: 0)
        let read = try #require(ScreenTextRecogniser.reading(
            lines, pick: pick, at: Self.atRun(pick, in: lines), region: Self.region,
            appName: nil, bundleID: nil))
        #expect(read.word.sentence.text.contains("reader"), "\(read.word.sentence.text)")
        #expect(!read.mayBeCut, "a sentence cut nowhere was reported as possibly cut")
    }

    /// **And the two answers are one value**, whatever it is — they were computed separately and
    /// could disagree, which is what the reader sees when `HoverReader` reads the outer one.
    @Test func theSentenceCarriesTheSameAnswerAsTheRecognition() throws {
        for pick in [RecognisedPick(line: 0, run: 0), RecognisedPick(line: 1, run: 0)] {
            let lines = [
                Self.edged("First sentence. The reader saw", word: "reader", x: 0.1, width: 0.9, y: 0.200),
                Self.edged("a sentence missing words. Last sentence.", word: "sentence", x: 0.1, width: 0.9, y: 0.225),
            ]
            let read = try #require(ScreenTextRecogniser.reading(
                lines, pick: pick, at: Self.atRun(pick, in: lines), region: Self.region, appName: nil, bundleID: nil))
            #expect(read.mayBeCut == read.word.sentence.mayBeCut,
                    "pick \(pick): Recognition says \(read.mayBeCut), the sentence says \(read.word.sentence.mayBeCut)")
        }
    }
}
