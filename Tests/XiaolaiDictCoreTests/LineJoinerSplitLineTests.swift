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
