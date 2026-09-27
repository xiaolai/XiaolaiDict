import CoreGraphics
import Foundation
import Testing
@testable import XiaolaiDictCore

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
            words: [], confidence: 1)
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

    /// The word the reader pointed at is in the right-hand fragment.
    private static let seed = 2

    @Test func theLeftHalfOfTheReadersOwnLineIsNotDropped() {
        let block = LineJoiner.block(around: Self.seed, in: Self.capture)
        #expect(block.text.contains("relabelled"),
                "the left half of the same screen line was dropped:\n\(block.text)")
    }

    /// And the splice that replaced it is the visible half of the same defect: text from the line
    /// *above* runs straight into the seed, reading as one sentence that was never on screen.
    @Test func theLineAboveIsNotSplicedOntoTheSeed() {
        let block = LineJoiner.block(around: Self.seed, in: Self.capture)
        #expect(!block.text.contains("because That includes"),
                "two different lines were joined into a sentence nobody wrote:\n\(block.text)")
    }

    /// The offset the caller adds to a seed-line offset has to survive whatever the block does.
    @Test func theSeedStillLandsWhereTheShiftSaysItDoes() {
        let block = LineJoiner.block(around: Self.seed, in: Self.capture)
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
                       words: [], confidence: 1)
    }

    static let capture: [RecognisedLine] = [
        line("here - it lives in storage-cupboard and comes back with it.", x: 0.0145, width: 0.2776, top: 0.0000, height: 0.1316),
        line("What stored: Crates/spare/{lamps1.txt, tally.txt, shade_ledgers.txt} are still in bins,", x: 0.0145, width: 0.4099, top: 0.3421, height: 0.1849),
        line("00C211٢0", x: 0.4230, width: 0.0378, top: 0.3947, height: 0.0526),
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
    @Test func theParagraphAroundTheWordIsRecovered() {
        let block = LineJoiner.block(around: Self.seed, in: Self.capture, region: Self.band)
        #expect(block.text.contains("are still in bins"), "\(block.text)")
        #expect(block.text.contains("sitting untouched at home"), "\(block.text)")
        #expect(block.text.utf16.count > 200, "only \(block.text.utf16.count) characters:\n\(block.text)")
        // Printed because this is the artifact: what the reader's sentence became.
        print("\n  real capture, block around the word:\n  \(block.text)\n")
    }
}
