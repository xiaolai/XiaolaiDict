import CaptureModel
import CoreGraphics
import Foundation
import Testing
@testable import Capture

/// **Vision does not return one observation per visual line, and the joiner assumes it does.**
///
/// Measured 2026-09-27 from a reader's screenshot of a terminal. Vision split one screen line into
/// two observations at a sentence boundary — the wide gap after "them." — and returned them at
/// almost the same `minY`:
///
///     obs 25  x 0.016…0.462  y 0.4651  "…are still in bins, because"
///     obs 26  x 0.014…0.231  y 0.4772  "they're relabelled and all haven't moved them."
///     obs 27  x 0.235…0.465  y 0.4779  "That includes our twelve spare lamp-shade frames,"
///     obs 28  x 0.014…0.365  y 0.4954  "which are therefore sitting untouched at home right now…"
///
/// 26 and 27 are **the same line of the terminal**, left half and right half. `LineJoiner` sorts by
/// `minY` alone, so they become two lines; `joins` tests a *gap* that is negative for two boxes on
/// one line and passes it; and `sharesColumn` then matched 25 with 27 on their **right edges**
/// (0.462 against 0.465), because a right-hand fragment ends where the line above ends.
///
/// So the reader's own line lost its left half and the line above was spliced in its place. What
/// the ledger stored was `are still in bins. because lve spare lamp-shade framesci` — 56 characters
/// of two different lines, presented as the sentence the word was read in.
struct LineJoinerSplitLineTests {
    /// The boxes are the measured ones. Normalisation differs between a full-screen probe and the
    /// 140-point band the app captures, but every test `joins` applies is a *ratio* — gap against
    /// height, overlap against width — so the geometry transfers.
    private static func line(_ text: String, x: CGFloat, width: CGFloat, top: CGFloat, height: CGFloat)
        -> RecognisedLine {
        RecognisedLine(
            text: text, box: CGRect(x: x, y: top, width: width, height: height),
            runs: [], confidence: 1)
    }

    private static let capture = [
        line("What stored: Crates/spare/… are still in bins, because",
             x: 0.016, width: 0.446, top: 0.4651, height: 0.0155),
        line("they're relabelled and all haven't moved them.",
             x: 0.014, width: 0.217, top: 0.4772, height: 0.0207),
        line("That includes our twelve spare lamp-shade frames,",
             x: 0.235, width: 0.230, top: 0.4779, height: 0.0183),
        line("which are therefore sitting untouched at home right now - worth knowing if",
             x: 0.014, width: 0.351, top: 0.4954, height: 0.0209),
    ]

    /// The full-screen probe these boxes came from, in points.
    static let band = CGSize(width: 2560, height: 1440)

    /// The word the reader pointed at is in the right-hand fragment.
    private static let seed = 2

    @Test func theLeftHalfOfTheReadersOwnLineIsNotDropped() {
        let block = LineJoiner.block(around: Self.seed, in: Self.capture, region: Self.band)
        #expect(block.text.contains("relabelled"),
                "the left half of the same screen line was dropped:\n\(block.text)")
    }

    /// And the splice that replaced it is the visible half of the same defect: text from the line
    /// *above* runs straight into the seed, reading as one sentence that was never on screen.
    @Test func theLineAboveIsNotSplicedOntoTheSeed() {
        let block = LineJoiner.block(around: Self.seed, in: Self.capture, region: Self.band)
        #expect(!block.text.contains("because That includes"),
                "two different lines were joined into a sentence nobody wrote:\n\(block.text)")
    }

    /// The offset the caller adds to a seed-line offset has to survive whatever the block does.
    @Test func theSeedStillLandsWhereTheShiftSaysItDoes() {
        let block = LineJoiner.block(around: Self.seed, in: Self.capture, region: Self.band)
        let text = block.text as NSString
        #expect(block.offsetShift >= 0 && block.offsetShift <= text.length)
        #expect(text.substring(from: block.offsetShift).hasPrefix(Self.capture[Self.seed].text),
                "the shift does not point at the seed line")
    }
}

/// **The reader's actual capture**, not a fixture built to make a point.
///
/// Every line below is what `VNRecognizeTextRequest` returned — the app's own settings, `.accurate`,
/// no language correction — for the 140-point band the app captures, at the pixel density it
/// captures at, from the screenshot a reader sent on 2026-09-27. Their Ghostty window holds **two
/// panes**, so a band the full width of the *window* spans two unrelated columns of text.
///
/// Three things in it are worth knowing before reading the assertions:
///
/// - The line the reader pointed at comes back as **two observations**, split at the sentence
///   boundary after "them." — the left half at x 0.016…0.234 and the right at 0.234…0.467.
/// - A garbage observation sits where "because" is, at **confidence 0.30**: `00C211٢0`. It is on
///   the reader's line and belongs to it; what must not happen is that it be read as confidently as
///   the rest, and `RecognisedLine.confidence` taking the minimum of a row is what prevents that.
/// - Everything from x 0.514 is the **other pane**, and none of it is what the reader is reading.
struct RealCaptureBlockTests {
    private static func line(_ text: String, x: CGFloat, width: CGFloat, top: CGFloat, height: CGFloat)
        -> RecognisedLine {
        RecognisedLine(text: text, box: CGRect(x: x, y: top, width: width, height: height),
                       runs: [], confidence: 1)
    }

    static let capture: [RecognisedLine] = [
        line("here - it lives in storage-cupboard and comes back with it.", x: 0.0145, width: 0.2776, top: 0.0000, height: 0.1316),
        line("What stored: Crates/spare/{lamps1.txt, tally.txt, shade_ledgers.txt} are still in bins,", x: 0.0145, width: 0.4099, top: 0.3421, height: 0.1849),
        // Confidence 0.30 — this is the observation standing where "because" was misread.
        RecognisedLine(
            text: "00C211٢0",
            box: CGRect(x: 0.4230, y: 0.3947, width: 0.0378, height: 0.0526),
            runs: [], confidence: 0.30),
        line("they're relabelled and all haven't moved them.", x: 0.0160, width: 0.2180, top: 0.5263, height: 0.1584),
        line("That includes our twelve spare lamp-shade frames,", x: 0.2340, width: 0.2326, top: 0.5263, height: 0.1584),
        line("which are therefore sitting untouched at home right now - worth knowing if", x: 0.0145, width: 0.3503, top: 0.6842, height: 0.1852),
        line("qpl-zrty/hudwor_bbcoalqwxv_mnvxtyq pt wvrpoxiv jun tqp lamq xouqen", x: 0.0145, width: 0.3183, top: 0.8947, height: 0.0789),
        line("dictionary", x: 0.5144, width: 0.0496, top: -0.0006, height: 0.1497),
        line("/// that carries lampshade ids - 71,827 shade pairs from 49 distributors - the mapping between a", x: 0.5160, width: 0.4506, top: 0.1575, height: 0.2029),
        line("/ lampshade kev and a storage kev is **exact in both directions. 100.00%**. Forward exactness savs", x: 0.5145, width: 0.4695, top: 0.3684, height: 0.1053),
        line("the", x: 0.5145, width: 0.0160, top: 0.5263, height: 0.1316),
        line("/// key is a function of the shade; reverse exactness says the ordinal does its job, since two shades", x: 0.5160, width: 0.4738, top: 0.6842, height: 0.1852),
    ]

    /// The band the app captured, in points: the window's width by `bandHeight`.
    static let band = CGSize(width: 2560, height: 140)

    /// The observation holding the word the reader pointed at.
    static let seed = 4

    @Test func theReadersOwnLineArrivesWhole() {
        let block = LineJoiner.block(around: Self.seed, in: Self.capture, region: Self.band)
        #expect(block.text.contains("they're relabelled and all haven't moved them. That includes our twelve spare lamp-shade frames,"),
                "the two halves of one line did not come back as one:\n\(block.text)")
    }

    @Test func theOtherPaneIsNotInTheReadersSentence() {
        let block = LineJoiner.block(around: Self.seed, in: Self.capture, region: Self.band)
        for foreign in ["lampshade ids", "exact in both directions", "reverse exactness"] {
            #expect(!block.text.contains(foreign),
                    "text from the other pane reached the reader's sentence: \(foreign)\n\(block.text)")
        }
    }

    /// And the paragraph the reader is in comes back, not one line of it.
    /// **A sentence is only as trustworthy as its least trustworthy fragment.** The reader pointed
    /// at a line Vision read at 1.00; the block joined to it carries one read at 0.30. Reporting
    /// the pointed-at line's number would render that sentence as certain, which is the one thing
    /// `CaptureQuality.isDoubtful` exists to prevent.
    @Test func theBlockIsOnlyAsConfidentAsItsWorstLine() {
        let block = LineJoiner.block(around: Self.seed, in: Self.capture, region: Self.band)
        #expect(block.text.contains("00C211"), "the low-confidence fragment is not even in the block")
        #expect(block.confidence == 0.30, "the block reported \(block.confidence)")
        #expect(block.confidence < CaptureQuality.doubtful, "this capture must read as doubtful")
    }

    @Test func theParagraphAroundTheWordIsRecovered() {
        let block = LineJoiner.block(around: Self.seed, in: Self.capture, region: Self.band)
        #expect(block.text.contains("are still in bins"), "\(block.text)")
        #expect(block.text.contains("sitting untouched at home"), "\(block.text)")
        #expect(block.text.utf16.count > 200, "only \(block.text.utf16.count) characters:\n\(block.text)")
        // Printed because this is the artifact: what the reader's sentence became.
        print("\n  real capture, block around the word:\n  \(block.text)\n")
    }
}

/// The three row-grouping defects an audit found in the fix above, each as the geometry that
/// produces it. All three were reachable; none was covered.
struct RowGroupingTests {
    private static let band = CGSize(width: 1000, height: 1000)

    private static func line(_ text: String, _ x: CGFloat, _ y: CGFloat,
                             _ w: CGFloat = 20, _ h: CGFloat = 10) -> RecognisedLine {
        RecognisedLine(text: text, box: CGRect(x: x, y: y, width: w, height: h), runs: [])
    }

    /// **A fragment that bridges two others must join them, not pick one.** Grouping appended a
    /// candidate to the *first* matching group, so with A and C too far apart to match directly,
    /// B — which sits between them and matches both — joined A and left C stranded. The reader's
    /// line then ended early.
    @Test func aBridgingFragmentJoinsBothSides() {
        let lines = [Self.line("A", 10, 10), Self.line("C", 60, 10.1), Self.line("B", 35, 10.2)]
        let rows = LineJoiner.rows(in: lines, region: Self.band)
        #expect(rows.count == 1, "\(rows.count) rows: \(rows.map(\.line.text))")
        #expect(rows.first?.line.text == "A B C", "out of reading order: \(rows.first?.line.text ?? "")")
    }

    /// **And a chain must not drift off its own line.** Matching any member let A, B and C enter
    /// one row although A and C share no band at all — and sorting that row by x then emitted them
    /// in an order their vertical positions contradict.
    @Test func aChainDoesNotDriftOntoAnotherLine() {
        let lines = [Self.line("A", 40, 10, 60), Self.line("B", 20, 14, 15), Self.line("C", 0, 18, 15)]
        let rows = LineJoiner.rows(in: lines, region: Self.band)
        let together = rows.first { $0.members.contains(0) && $0.members.contains(2) }
        #expect(together == nil, "two lines that share no band were made one row")
    }

    /// **Kana are written without spaces and were not treated as such**, so a line wrapping mid-word
    /// gained a space that is not in the text.
    @Test func kanaAreJoinedWithoutASpace() {
        let lines = [Self.line("カタ", 10, 10), Self.line("カナ", 31, 10)]
        #expect(LineJoiner.rows(in: lines, region: Self.band).first?.line.text == "カタカナ")
    }

    /// **And fullwidth Latin is Latin.** It sits inside the fullwidth block, so it was counted as
    /// a script written without spaces and two words were run together.
    @Test func fullwidthLatinKeepsItsSpace() {
        let lines = [Self.line("ＨＥＬＬＯ", 10, 10), Self.line("ＷＯＲＬＤ", 31, 10)]
        #expect(LineJoiner.rows(in: lines, region: Self.band).first?.line.text == "ＨＥＬＬＯ ＷＯＲＬＤ")
    }

    /// **A short fragment inside a long one must not block the row.** The first attempt walked
    /// outwards from the current edge; stepping into B — which sits *within* A — left C, adjacent
    /// to A, unreachable. It split a row the code before it had held together.
    @Test func aFragmentInsideAnotherDoesNotStrandWhatIsBeyond() {
        let lines = [Self.line("A", 10, 10, 100), Self.line("B", 20, 10.1, 10), Self.line("C", 100, 10.2, 20)]
        let rows = LineJoiner.rows(in: lines, region: Self.band)
        #expect(rows.count == 1, "\(rows.count) rows: \(rows.map(\.line.text))")
    }

    /// **A tall seed must not hold together two fragments that share no band with each other.**
    /// Anchoring the vertical test to the seed alone let a fragment high on its left and one low
    /// on its right into the same row.
    @Test func aTallSeedDoesNotUniteTwoDisjointFragments() {
        let lines = [Self.line("seed", 35, 10, 20, 20), Self.line("left", 10, 11, 20, 8),
                     Self.line("right", 60, 21, 20, 8)]
        let rows = LineJoiner.rows(in: lines, region: Self.band)
        let together = rows.first { $0.members.contains(1) && $0.members.contains(2) }
        #expect(together == nil, "two fragments with no shared band were made one row")
    }

    /// **A quality signal must describe the text it is attached to.** The block spans two
    /// sentences; only one is returned. Scoring the returned one by the block's minimum marks a
    /// perfectly read sentence doubtful because its neighbour was not.
    @Test func confidenceIsScopedToTheSpanItDescribes() {
        let lines = [
            RecognisedLine(text: "A badly read sentence.", box: CGRect(x: 0, y: 0, width: 50, height: 10),
                           runs: [], confidence: 0.30),
            RecognisedLine(text: "A perfectly read one.", box: CGRect(x: 0, y: 12, width: 50, height: 10),
                           runs: [], confidence: 1.0),
        ]
        let block = LineJoiner.block(around: 1, in: lines, region: Self.band)
        let second = try! #require(block.offsets[1])
        let span = NSRange(location: second, length: lines[1].text.utf16.count)
        #expect(block.confidence == 0.30, "the block as a whole is still as weak as its worst line")
        #expect(block.confidence(over: span, in: lines) == 1.0,
                "the good sentence was marked doubtful by its neighbour")
    }
}
