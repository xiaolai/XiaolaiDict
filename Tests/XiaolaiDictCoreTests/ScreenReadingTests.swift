import CoreGraphics
import DictionaryModel
import Foundation
import XiaolaiDictCore
import Testing

/// The word-edge rule, which is **one rule for every capture path**. With a tolerance per path the
/// same pointer position hit or missed depending on which path answered.
struct HitToleranceTests {
    private let box = CGRect(x: 100, y: 50, width: 40, height: 12)

    @Test func insideIsZeroDistance() {
        #expect(HitTolerance.distance(from: CGPoint(x: 120, y: 56), to: box) == 0)
    }

    /// Safari points 1 pt past a word's end: Accessibility missed it and OCR hit it, until both
    /// used this.
    @Test func justPastTheEdgeStillHits() {
        #expect(HitTolerance.distance(from: CGPoint(x: 141, y: 56), to: box) != nil)
        #expect(HitTolerance.distance(from: CGPoint(x: 99, y: 56), to: box) != nil)
    }

    @Test func beyondToleranceMisses() {
        // The box spans x 100...140, y 50...62, and tolerance is 3 horizontal / 2 vertical.
        #expect(HitTolerance.distance(from: CGPoint(x: 144, y: 56), to: box) == nil)
        #expect(HitTolerance.distance(from: CGPoint(x: 120, y: 65), to: box) == nil)
        // …and the last point that still counts, on each axis.
        #expect(HitTolerance.distance(from: CGPoint(x: 143, y: 56), to: box) != nil)
        #expect(HitTolerance.distance(from: CGPoint(x: 120, y: 64), to: box) != nil)
    }

    /// Vertical tolerance is tighter than horizontal, because lines are closer than words.
    @Test func verticalIsTighterThanHorizontal() {
        #expect(HitTolerance.vertical < HitTolerance.horizontal)
    }
}

struct CaptureGeometryTests {
    private let display = CGRect(x: 0, y: 0, width: 1_440, height: 900)

    /// Shifted to stay on screen, never shrunk — a smaller capture is not faster anyway
    /// (recognition has a fixed per-call cost), and a shrunk one cuts the sentence.
    @Test func aRegionIsShiftedOntoTheDisplayNotShrunk() {
        let corner = CaptureGeometry.rect(
            around: CGPoint(x: 5, y: 5), size: CGSize(width: 420, height: 100), within: display)
        #expect(corner.size == CGSize(width: 420, height: 100))
        #expect(display.contains(corner))
    }

    @Test func aRegionLargerThanTheDisplayIsClamped() {
        let huge = CaptureGeometry.rect(
            around: CGPoint(x: 700, y: 400), size: CGSize(width: 4_000, height: 4_000), within: display)
        #expect(huge == display)
    }

    /// Vision reports bottom-left origin; everything else here is top-left.
    @Test func visionBoxesAreFlipped() {
        let flipped = CaptureGeometry.flippedFromVision(CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1))
        #expect(abs(flipped.minY - 0.1) < 0.0001)
        #expect(flipped.minX == 0.1)
    }

    /// Word breaks differ between sources: WebKit calls 看书 one word and the tokeniser splits it,
    /// so the pointer's position *within* the word decides which character was meant.
    @Test func theCharacterUnderThePointerIsFound() {
        #expect(CaptureGeometry.characterIndex(at: 10, across: 0...100, count: 2) == 0)
        #expect(CaptureGeometry.characterIndex(at: 90, across: 0...100, count: 2) == 1)
        // Clamped, never out of range.
        #expect(CaptureGeometry.characterIndex(at: -50, across: 0...100, count: 2) == 0)
        #expect(CaptureGeometry.characterIndex(at: 500, across: 0...100, count: 2) == 1)
        #expect(CaptureGeometry.characterIndex(at: 10, across: 0...100, count: 0) == 0)
    }
}

/// Picking a word out of recognised lines.
struct RecognisedTextPickerTests {
    private static func line(_ text: String, y: CGFloat, words: [(String, CGFloat, CGFloat)]) -> RecognisedLine {
        RecognisedLine(
            text: text, box: CGRect(x: 0.05, y: y, width: 0.9, height: 0.05),
            words: words.map { word, x, width in
                RecognisedWord(
                    text: word, utf16Offset: (text as NSString).range(of: word).location,
                    box: CGRect(x: x, y: y + 0.01, width: width, height: 0.03))
            },
            confidence: 1)
    }

    private let lines = [
        Self.line("the ship's hold", y: 0.1, words: [("the", 0.05, 0.1), ("ship's", 0.2, 0.15), ("hold", 0.4, 0.1)]),
        Self.line("was full", y: 0.3, words: [("was", 0.05, 0.1), ("full", 0.2, 0.1)]),
    ]

    @Test func theWordUnderThePointerIsPicked() {
        let pick = RecognisedTextPicker.pick(at: CGPoint(x: 0.45, y: 0.12), in: lines)
        #expect(pick == RecognisedPick(line: 0, word: 2))
    }

    /// The **line** box decides vertically: word boxes hug the glyphs, so a pointer above an
    /// x-height letter would otherwise miss.
    @Test func theLineBoxDecidesVertically() {
        #expect(RecognisedTextPicker.pick(at: CGPoint(x: 0.45, y: 0.105), in: lines) != nil)
    }

    @Test func betweenLinesPicksNothing() {
        #expect(RecognisedTextPicker.pick(at: CGPoint(x: 0.45, y: 0.22), in: lines) == nil)
    }

    @Test func betweenWordsPicksNothingWithoutSlack() {
        #expect(RecognisedTextPicker.pick(at: CGPoint(x: 0.17, y: 0.12), in: lines) == nil)
    }

    /// Where widened boxes overlap, the word whose **real edge** is nearest wins. Comparing
    /// centres instead lets a short neighbour steal the edge of a long word.
    @Test func theNearestRealEdgeWinsNotTheNearestCentre() {
        let slack = CGSize(width: 0.06, height: 0)
        let pick = RecognisedTextPicker.pick(at: CGPoint(x: 0.355, y: 0.12), in: lines, slack: slack)
        #expect(pick == RecognisedPick(line: 0, word: 1), "the long word's edge lost to a short neighbour")
    }
}

/// Joining lines back into the block a sentence runs across.
struct LineJoinerTests {
    private static func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> RecognisedLine {
        RecognisedLine(text: text, box: CGRect(x: x, y: y, width: width, height: height), words: [], confidence: 1)
    }

    /// Wrapped lines of one paragraph join, and the seed's offset shifts by what came before it.
    @Test func wrappedLinesJoin() {
        let lines = [
            Self.line("Serendipity favours the prepared mind,", x: 0.1, y: 0.1, width: 0.8, height: 0.04),
            Self.line("yet the prepared mind is itself", x: 0.1, y: 0.16, width: 0.8, height: 0.04),
        ]
        let block = LineJoiner.block(around: 1, in: lines)
        #expect(block.text == "Serendipity favours the prepared mind, yet the prepared mind is itself")
        #expect(block.offsetShift == 39)
        #expect(block.lineIndices == [0, 1])
    }

    /// A window title is close enough to join by distance alone. It is left out because it shares
    /// no column — which is how "fixture.txt An ephemeral beauty…" happened.
    @Test func aCentredWindowTitleIsNotJoined() {
        let lines = [
            Self.line("fixture.txt", x: 0.42, y: 0.02, width: 0.16, height: 0.035),
            Self.line("An ephemeral beauty, soon gone.", x: 0.05, y: 0.09, width: 0.9, height: 0.04),
        ]
        let block = LineJoiner.block(around: 1, in: lines)
        #expect(block.text == "An ephemeral beauty, soon gone.", "the title bar joined the sentence")
        #expect(block.lineIndices == [1])
    }

    /// A following paragraph, set far below, is a different block.
    @Test func adistantParagraphIsNotJoined() {
        let lines = [
            Self.line("The first paragraph ends here.", x: 0.1, y: 0.1, width: 0.8, height: 0.04),
            Self.line("A second one starts much later.", x: 0.1, y: 0.4, width: 0.8, height: 0.04),
        ]
        #expect(LineJoiner.block(around: 0, in: lines).lineIndices == [0])
    }

    /// Chinese has no inter-word spaces; inserting one corrupts the sentence.
    @Test func cjkLinesJoinWithoutASpace() {
        let lines = [
            Self.line("船舱里装满了", x: 0.1, y: 0.1, width: 0.5, height: 0.04),
            Self.line("饼干和老鼠。", x: 0.1, y: 0.16, width: 0.5, height: 0.04),
        ]
        #expect(LineJoiner.block(around: 0, in: lines).text == "船舱里装满了饼干和老鼠。")
    }

    /// A trailing hyphen joins without a space — and **keeps the hyphen**.
    ///
    /// This assertion was the other way round until an audit pointed out what deleting it costs.
    /// The two cases are indistinguishable from the text alone: deleting repairs a word broken
    /// across lines and destroys a real compound. On screen the compound is far the commoner case,
    /// because CSS `hyphens` is off by default and editors do not hyphenate — so a hyphen at a
    /// line end is usually one the reader could see.
    @Test func atrailingHyphenJoinsWithoutASpaceAndIsKept() {
        let compound = [
            Self.line("a well-", x: 0.1, y: 0.1, width: 0.3, height: 0.04),
            Self.line("known author", x: 0.1, y: 0.16, width: 0.3, height: 0.04),
        ]
        #expect(LineJoiner.block(around: 0, in: compound).text == "a well-known author",
                "a real compound was destroyed")

        // The cost of that choice, stated rather than hidden: a word genuinely broken across lines
        // keeps a hyphen it did not have. A wrong word the reader can see beats one that was never
        // on screen.
        let broken = [
            Self.line("an unglamorous prepa-", x: 0.1, y: 0.1, width: 0.8, height: 0.04),
            Self.line("ration nobody witnesses", x: 0.1, y: 0.16, width: 0.8, height: 0.04),
        ]
        #expect(LineJoiner.block(around: 0, in: broken).text == "an unglamorous prepa-ration nobody witnesses")
    }

    @Test func anIndexOutsideTheLinesIsEmpty() {
        #expect(LineJoiner.block(around: 5, in: []).text.isEmpty)
    }
}

/// The flag that stops a fabricated sentence being passed off as a real one.
struct CaptureEdgeTests {
    @Test func textReachingTheEdgeIsClipped() {
        #expect(CaptureEdge.clips([CGRect(x: 0, y: 0.4, width: 0.5, height: 0.05)]))
        #expect(CaptureEdge.clips([CGRect(x: 0.5, y: 0.4, width: 0.5, height: 0.05)]))
    }

    @Test func textWellInsideIsNot() {
        #expect(!CaptureEdge.clips([CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.05)]))
    }

    /// One clipped line among many is enough: it is the line that was cut.
    @Test func oneClippedLineClipsTheBlock() {
        #expect(CaptureEdge.clips([
            CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.05),
            CGRect(x: 0, y: 0.4, width: 0.6, height: 0.05),
        ]))
    }
}

/// Finding the word under an offset, and the sentence it sits in.
struct WordAtPointTests {
    @Test func thewordAndItsSentenceAreFound() throws {
        let text = "It was stowed in the ship's hold. The rats had got at the biscuit."
        let hit = try #require(TextSegmenter.word(in: text, utf16Offset: 28))
        #expect(hit.word == "hold")
        #expect(hit.sentence.text == "It was stowed in the ship's hold.")
        #expect(hit.sentence.mayBeCut == false)
    }

    /// A clipped capture marks its sentence, so a spliced one is never passed off as whole.
    @Test func aClippedCaptureMarksItsSentence() throws {
        let text = "stowed in the ship's hold where the rats"
        let hit = try #require(TextSegmenter.word(in: text, utf16Offset: 21, clipped: [.start, .end]))
        #expect(hit.word == "hold")
        #expect(hit.sentence.mayBeCut, "a sentence cut at the capture's edge claimed to be whole")
    }

    @Test func anOffsetOutsideTheTextFindsNothing() {
        #expect(TextSegmenter.word(in: "short", utf16Offset: 99) == nil)
        #expect(TextSegmenter.word(in: "short", utf16Offset: -1) == nil)
        #expect(TextSegmenter.word(in: "", utf16Offset: 0) == nil)
    }

    @Test func everyWordIsFoundAtEveryOffsetWithinIt() throws {
        let text = "the ship's hold"
        for offset in 11..<15 {
            #expect(try #require(TextSegmenter.word(in: text, utf16Offset: offset)).word == "hold")
        }
    }

    /// CJK segmentation: the tokeniser splits where the app may not have.
    @Test func cjkSegmentsAtTheOffset() throws {
        let hit = try #require(TextSegmenter.word(in: "他在看书。", utf16Offset: 3))
        #expect(hit.word == "书" || hit.word == "看书", "got \(hit.word)")
    }
}

/// Found by audit. Each of these was a real failure scenario, and each is pinned by the case that
/// produced it rather than by a description of it.
struct ScreenReadingAuditTests {
    private static func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> RecognisedLine {
        RecognisedLine(text: text, box: CGRect(x: x, y: y, width: width, height: height), words: [], confidence: 1)
    }

    private static func wordLine(
        _ text: String, y: CGFloat, height: CGFloat, words: [(String, CGFloat, CGFloat)]
    ) -> RecognisedLine {
        RecognisedLine(
            text: text, box: CGRect(x: 0.05, y: y, width: 0.9, height: height),
            words: words.map { word, x, width in
                RecognisedWord(
                    text: word, utf16Offset: (text as NSString).range(of: word).location,
                    box: CGRect(x: x, y: y + height * 0.2, width: width, height: height * 0.6))
            },
            confidence: 1)
    }

    /// A non-finite or wildly out-of-range coordinate used to trap: `Int(...)` does not saturate,
    /// and the x comes from a pointer position nothing validates.
    @Test func anExtremeCoordinateDoesNotTrap() {
        #expect(CaptureGeometry.characterIndex(at: .infinity, across: 0...100, count: 2) == 0)
        #expect(CaptureGeometry.characterIndex(at: -.infinity, across: 0...100, count: 2) == 0)
        #expect(CaptureGeometry.characterIndex(at: .nan, across: 0...100, count: 2) == 0)
        // A minute span overflows an ordinary coordinate into the conversion.
        #expect(CaptureGeometry.characterIndex(at: 1, across: 0...1e-20, count: 2) == 1)
        #expect(CaptureGeometry.characterIndex(at: 1e300, across: 0...1, count: 3) == 2)
        #expect(CaptureGeometry.characterIndex(at: -1e300, across: 0...1, count: 3) == 0)
    }

    /// Distances are compared in **points**, so the nearest edge wins — the same rule every other
    /// capture path uses. Comparing normalised numbers, by weight or lexicographically, compares
    /// two different scales, and both orderings were shown to reverse a correct pick.
    ///
    /// **Both lines have to reach the pointer, and the check has to name which one won.** This
    /// asked only `picked != nil` over a pair whose second line sat 20 pt away — outside its own
    /// slack, so it was never a candidate — and passed on the first line whichever way the
    /// comparator ran. The point now sits inside both widened bands and outside both real ones, so
    /// the two are *equally outside* and only the distance separates them.
    @Test func amongLinesEquallyOutsideTheNearestEdgeWins() {
        // A 1000 x 140 pt capture, so a normalised unit is 1000 pt across and 140 pt down.
        let region = CGSize(width: 1_000, height: 140)
        let a = Self.wordLine("a", y: 0.20, height: 0.05, words: [("aaa", 0.30, 0.10)])
        // 1 pt below a's band: outside it, and well inside the 2.8 pt of vertical slack.
        let y = (a.box.maxY * region.height + 1) / region.height
        // b begins 1.05 pt below the pointer — barely further away vertically than a is — but its
        // word is directly under the pointer, where a's ends 3 pt to the left of it. Nearest edge
        // in points: a is hypot(3, 1) = 3.16 pt away and b is 1.05, so b wins.
        let b = Self.wordLine(
            "b", y: (y * region.height + 1.05) / region.height, height: 0.05,
            words: [("bbb", 0.38, 0.10)])
        let point = CGPoint(x: (0.30 * region.width + 0.10 * region.width + 3) / region.width, y: y)
        let picked = RecognisedTextPicker.pick(
            at: point, in: [a, b], slack: CGSize(width: 0.01, height: 0.02), region: region)
        #expect(picked == RecognisedPick(line: 1, word: 0), "the further word in points was taken")
    }

    /// Where two slack-widened bands both reach the pointer, the line it is actually *inside* wins.
    /// Ranking on horizontal distance alone let the earlier line take it.
    @Test func thelinethePointerIsInsideWins() {
        let lines = [
            Self.wordLine("first line", y: 0.10, height: 0.04, words: [("first", 0.3, 0.2)]),
            Self.wordLine("second line", y: 0.15, height: 0.04, words: [("second", 0.3, 0.2)]),
        ]
        // y = 0.155 is inside the second line's real band and only inside the first's slack.
        let pick = RecognisedTextPicker.pick(
            at: CGPoint(x: 0.4, y: 0.155), in: lines, slack: CGSize(width: 0.01, height: 0.02))
        #expect(pick?.line == 1, "an earlier line stole a hit from the line under the pointer")
    }

    /// A two-column capture interleaves by y — left₁, right₁, left₂ — so stopping at the first
    /// non-joining neighbour dropped the seed's own continuation.
    @Test func asecondColumnDoesNotEndTheBlock() {
        let lines = [
            Self.line("the left column begins", x: 0.05, y: 0.10, width: 0.40, height: 0.04),
            Self.line("the right column begins", x: 0.55, y: 0.11, width: 0.40, height: 0.04),
            Self.line("and the left one continues", x: 0.05, y: 0.16, width: 0.40, height: 0.04),
        ]
        let block = LineJoiner.block(around: 0, in: lines)
        #expect(block.text == "the left column begins and the left one continues")
        #expect(block.lineIndices == [0, 2], "the other column joined, or the continuation was lost")
    }

    /// …but a genuine next paragraph, in the same column, still ends it.
    @Test func adifferentParagraphInTheSameColumnStillEndsTheBlock() {
        let lines = [
            Self.line("the first paragraph ends", x: 0.05, y: 0.10, width: 0.8, height: 0.04),
            Self.line("a second one starts later", x: 0.05, y: 0.60, width: 0.8, height: 0.04),
        ]
        #expect(LineJoiner.block(around: 0, in: lines).lineIndices == [0])
    }

    /// Found by the second verify pass: testing only the first scalar excluded a mixed-script word
    /// like "iPhone手机", which leads with Latin — exactly the case that needs the fallback.
    @Test func mixedScriptCountsAsCJK() {
        #expect(LineJoiner.isCJKText("看书"))
        #expect(LineJoiner.isCJKText("iPhone手机"), "a Latin-leading mixed word was not seen as CJK")
        #expect(LineJoiner.isCJKText("手机iPhone"))
        #expect(!LineJoiner.isCJKText("iPhone"))
        #expect(!LineJoiner.isCJKText(""))
    }

    /// An offset landing on the low surrogate of a pair has no `String.Index`. The hover paths
    /// estimate offsets from a pointer position, so this is reachable by pointing at the right
    /// half of a supplementary character.
    @Test func anOffsetInsideASurrogatePairStillFindsItsWord() throws {
        let text = "a 𝄞 clef"                      // U+1D11E is a surrogate pair at UTF-16 2...3
        let low = try #require(TextSegmenter.word(in: text, utf16Offset: 3))
        #expect(low.word == "𝄞", "the low surrogate lost its word")
        let high = try #require(TextSegmenter.word(in: text, utf16Offset: 2))
        #expect(high.word == "𝄞")
    }
}
