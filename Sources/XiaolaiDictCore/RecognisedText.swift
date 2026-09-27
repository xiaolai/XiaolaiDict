import CoreGraphics
import Foundation

/// One recognised word. `box` is normalised to the capture: 0...1, top-left origin.
public struct RecognisedWord: Equatable, Sendable {
    public let text: String
    /// Where the word starts in its line, in UTF-16 units.
    public let utf16Offset: Int
    public let box: CGRect

    public init(text: String, utf16Offset: Int, box: CGRect) {
        self.text = text
        self.utf16Offset = utf16Offset
        self.box = box
    }
}

/// One recognised line and its words, in the same normalised space.
public struct RecognisedLine: Equatable, Sendable {
    public let text: String
    public let box: CGRect
    public let words: [RecognisedWord]
    /// Vision's confidence in this line, 0...1.
    ///
    /// **This is the signal that exposes a wrong reading.** Nothing in the geometry or the timings
    /// said anything was wrong while the recogniser returned `exthdt6n6` at confidence 0.5; the
    /// panel rendered it as confidently as a correct reading (finding 6b).
    public let confidence: Double

    public init(text: String, box: CGRect, words: [RecognisedWord], confidence: Double = 1) {
        self.text = text
        self.box = box
        self.words = words
        self.confidence = confidence
    }
}

/// Which word of which line the pointer landed on.
public struct RecognisedPick: Equatable, Sendable {
    public let line: Int
    public let word: Int

    public init(line: Int, word: Int) {
        self.line = line
        self.word = word
    }
}

public enum RecognisedTextPicker {
    /// The word under `point` — normalised, top-left origin — or nil between words or lines.
    ///
    /// The *line* box decides vertically, because word boxes hug the glyphs and a pointer above an
    /// x-height letter would otherwise miss. `slack` widens every box so box rounding and tight
    /// letter gaps still hit; where widened boxes overlap, the word whose real edge is nearest wins.
    /// `region` is the capture's size in points. Given it, distances are compared in **points**
    /// rather than in normalised units, which are not square — a capture is far wider than it is
    /// tall, so a normalised vertical and a normalised horizontal are simply different quantities.
    /// Passing `.zero` falls back to comparing the line first and then the horizontal distance.
    public static func pick(
        at point: CGPoint, in lines: [RecognisedLine], slack: CGSize = .zero, region: CGSize = .zero
    ) -> RecognisedPick? {
        var best: (pick: RecognisedPick, inside: Int, distance: CGFloat)?
        for (l, line) in lines.enumerated() {
            let band = line.box.insetBy(dx: 0, dy: -slack.height)
            guard band.minY <= point.y, point.y <= band.maxY else { continue }
            // Distance to the line's **real** band, before slack. Ranking on the horizontal alone
            // let an earlier line whose widened band merely reaches the pointer beat the line the
            // pointer is actually inside, whenever both had a word at that x.
            let vertical = max(line.box.minY - point.y, 0, point.y - line.box.maxY)
            for (w, word) in line.words.enumerated() {
                let span = word.box.insetBy(dx: -slack.width, dy: 0)
                guard span.minX <= point.x, point.x <= span.maxX else { continue }
                let horizontal = max(word.box.minX - point.x, 0, point.x - word.box.maxX)
                // Two ranks, and no weight between them. First: is the pointer *inside* this
                // line's real band? That is the question a reader would answer, and it settles
                // every ordinary case outright. Only among lines that are equally inside — or
                // equally not — does distance decide, and then it is the **nearest edge in
                // points**, the same rule `HitTolerance` applies to every other capture path.
                //
                // Comparing the normalised numbers directly, by weight or lexicographically,
                // compares two different scales; both were shown to reverse a correct pick.
                let inside = vertical == 0 ? 0 : 1
                let dx = region.width > 0 ? horizontal * region.width : horizontal
                let dy = region.height > 0 ? vertical * region.height : 0
                let distance = hypot(dx, dy)
                if best.map({ (inside, distance) < ($0.inside, $0.distance) }) ?? true {
                    best = (RecognisedPick(line: l, word: w), inside, distance)
                }
            }
        }
        return best?.pick
    }
}

/// Lines joined into one run of text, and where the seed line landed in it.
public struct TextBlock: Equatable, Sendable {
    public let text: String
    /// Add this to an offset within the seed line to get the offset in `text`.
    public let offsetShift: Int
    /// Indices of the lines joined, in the order they were read.
    public let lineIndices: [Int]
    /// **The lowest confidence of any line in it**, because the whole block is what the reader is
    /// shown and what the sense selector is asked about — not just the line the word sat on.
    ///
    /// Measured on a reader's capture 2026-09-27: the line they pointed at came back at 1.00 while
    /// the fragment joined to it, standing where "because" was, came back at **0.30** as
    /// `00C211٢0`. Reporting the pointed-at line's confidence would have rendered that sentence as
    /// certain. `CaptureQuality.isDoubtful` is the reader's warning and it can only be as good as
    /// the number it is given.
    public let confidence: Double

    public init(text: String, offsetShift: Int, lineIndices: [Int] = [], confidence: Double = 1) {
        self.text = text
        self.offsetShift = offsetShift
        self.lineIndices = lineIndices
        self.confidence = confidence
    }
}

/// Recognition produces lines; sentences run across them. This rebuilds the block of lines around
/// the pointer so the sentence is segmented from the whole block rather than from one line.
public enum LineJoiner {
    /// The block containing line `index`. Neighbours are taken while they sit close enough
    /// vertically **and share a column**, so a following paragraph, a second column, or a window
    /// title is left out — a TextEdit band once produced the sentence "fixture.txt An ephemeral
    /// beauty…", with the title bar joined into it (finding 18).
    /// `region` is the capture's size in points. **Given it, the row test compares points rather
    /// than normalised units**, which are not square: a band is far wider than it is tall, so a
    /// normalised horizontal gap and a normalised vertical height are simply different quantities.
    /// `RecognisedTextPicker.pick` already says this about its own distances; comparing them
    /// directly here folded the *other pane* of a split terminal into the reader's sentence —
    /// a 122-point gutter read as 0.048 against a line height of 0.13. Passing `.zero` keeps the
    /// normalised comparison, which is right only where the capture is roughly square.
    public static func block(
        around index: Int, in lines: [RecognisedLine], region: CGSize = .zero,
        maximumGapRatio: CGFloat = 1.0, minimumOverlap: CGFloat = 0.2
    ) -> TextBlock {
        guard lines.indices.contains(index) else { return TextBlock(text: "", offsetShift: 0) }
        // **Rows first: Vision does not return one observation per visual line.** Measured
        // 2026-09-27 on a terminal, it split one line at a sentence boundary — the wide gap after
        // "them." — into two observations at the same `minY`. Sorted by `minY` alone those are two
        // lines, `joins` sees a *negative* gap between them and passes it, and `sharesColumn` then
        // matched the right-hand fragment with the line *above* on their right edges, because a
        // right-hand fragment ends where the line above ends. The reader's own line lost its left
        // half and the line above was spliced in its place. `LineJoinerSplitLineTests` holds the
        // measured geometry.
        let rows = Self.rows(in: lines, region: region)
        let ordered = rows.enumerated().map { (offset: $0.offset, element: $0.element.line) }
            .sorted { $0.element.box.minY < $1.element.box.minY }
        guard let seed = ordered.firstIndex(where: { rows[$0.offset].members.contains(index) }) else {
            return TextBlock(
                text: lines[index].text, offsetShift: 0, lineIndices: [index],
                confidence: lines[index].confidence)
        }

        // Which lines belong to the block, walking out from the seed. A line from *another column*
        // is skipped rather than treated as the end: sorted by y, a two-column capture interleaves
        // left₁, right₁, left₂ …, and stopping at right₁ dropped left₁'s own continuation. A line
        // that *does* share the column and still fails the gap test is a different paragraph, and
        // does end the block.
        var members: [Int] = [seed]
        for step in [-1, 1] {
            var edge = seed
            var position = seed + step
            while ordered.indices.contains(position) {
                let candidate = ordered[position].element
                if joins(
                    step < 0 ? candidate : ordered[edge].element,
                    step < 0 ? ordered[edge].element : candidate,
                    maximumGapRatio, minimumOverlap) {
                    members.append(position)
                    edge = position
                } else if sharesColumn(ordered[seed].element, candidate) {
                    break  // same column, too far away: another paragraph
                }
                position += step
            }
        }
        members.sort()

        var text = ""
        var shift = 0
        for position in members {
            let row = rows[ordered[position].offset]
            let line = row.line.text
            // The seed is an *observation*, and its row may hold fragments before it — so the shift
            // is where the row starts plus where the observation starts inside the row. Pointing at
            // the row would put the word's offset before text that precedes it on the same line.
            let within = row.offset(of: index)
            guard !text.isEmpty else {
                if position == seed { shift = within }
                text = line
                continue
            }
            let separator = separator(between: text, and: line)
            if position == seed { shift = text.utf16.count + separator.utf16.count + within }
            text += separator + line
        }
        let joined = members.flatMap { rows[ordered[$0].offset].members }
        return TextBlock(
            text: text, offsetShift: shift, lineIndices: joined,
            confidence: joined.map { lines[$0].confidence }.min() ?? 1)
    }

    /// One visual line, however many observations Vision made of it.
    struct Row {
        /// The observations that make it up, in reading order — left to right.
        let members: [Int]
        /// Their union: one box spanning the whole line, which is what `joins` and `sharesColumn`
        /// were written for and what a half-line box quietly breaks.
        let line: RecognisedLine

        /// Where observation `index` starts inside this row's text, UTF-16. Zero where it is not
        /// in this row.
        func offset(of index: Int) -> Int { offsets[index] ?? 0 }
        let offsets: [Int: Int]
    }

    /// **Two observations are the same visual line when their boxes overlap vertically *and* sit
    /// beside each other.** Measured on the capture this was found in, the two halves of one line
    /// overlap by 1.00 of the shorter box and the lines above and below by 0.22 and 0.04.
    static let sameRowOverlap: CGFloat = 0.5

    /// **Vertical overlap alone is not enough, and a two-column capture is why.** Side-by-side
    /// columns overlap vertically as completely as the two halves of one line do, so merging on
    /// overlap alone folded a second column into the reader's sentence — which is the defect
    /// `asecondColumnDoesNotEndTheBlock` already existed to prevent, reintroduced one layer lower.
    ///
    /// What separates them is the white space between: measured, the split line's halves are
    /// **0.22** line-heights apart and the two columns **2.5**. One line-height is a few
    /// characters, which is what a sentence break inside a line looks like and what a column
    /// gutter never is.
    static let sameRowGap: CGFloat = 1.0

    static func rows(in lines: [RecognisedLine], region: CGSize = .zero) -> [Row] {
        var groups: [[Int]] = []
        for index in lines.indices.sorted(by: { lines[$0].box.minY < lines[$1].box.minY }) {
            let box = lines[index].box
            if let existing = groups.firstIndex(where: { group in
                group.contains { sameRow(lines[$0].box, box, region) }
            }) {
                groups[existing].append(index)
            } else {
                groups.append([index])
            }
        }
        return groups.map { group in
            let members = group.sorted { lines[$0].box.minX < lines[$1].box.minX }
            var text = ""
            var offsets: [Int: Int] = [:]
            var union = lines[members[0]].box
            for member in members {
                let fragment = lines[member].text
                let separator = text.isEmpty ? "" : separator(between: text, and: fragment)
                offsets[member] = text.utf16.count + separator.utf16.count
                text += separator + fragment
                union = union.union(lines[member].box)
            }
            let widest = members.max { lines[$0].box.height < lines[$1].box.height }!
            return Row(
                members: members,
                line: RecognisedLine(
                    text: text, box: union, words: members.flatMap { lines[$0].words },
                    confidence: members.map { lines[$0].confidence }.min() ?? 1),
                offsets: offsets.merging([widest: offsets[widest] ?? 0]) { a, _ in a })
        }
    }

    static func sameRow(_ a: CGRect, _ b: CGRect, _ region: CGSize = .zero) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let shorter = min(a.height, b.height)
        guard shorter > 0, overlap / shorter >= sameRowOverlap else { return false }
        // Negative where the boxes overlap horizontally, which is nearer still. Both sides are put
        // into points before they are compared; see `block(around:in:region:)`.
        let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
        let width = region.width > 0 ? region.width : 1
        let height = region.height > 0 ? region.height : 1
        return gap * width <= shorter * height * sameRowGap
    }

    /// Lines of one paragraph sit close together, are set in the same size, and share a margin.
    /// Window chrome fails one of those even when distance alone would join it.
    /// Whether two lines sit in the same column — the test that tells a second column from a
    /// second paragraph.
    static func sharesColumn(_ a: RecognisedLine, _ b: RecognisedLine) -> Bool {
        let widest = max(a.box.width, b.box.width)
        guard widest > 0 else { return false }
        let overlap = min(a.box.maxX, b.box.maxX) - max(a.box.minX, b.box.minX)
        return abs(a.box.minX - b.box.minX) <= widest * 0.04
            || abs(a.box.maxX - b.box.maxX) <= widest * 0.04
            || overlap >= widest * 0.6
    }

    private static func joins(
        _ upper: RecognisedLine, _ lower: RecognisedLine,
        _ maximumGapRatio: CGFloat, _ minimumOverlap: CGFloat
    ) -> Bool {
        let gap = lower.box.minY - upper.box.maxY
        let height = max(upper.box.height, lower.box.height)
        guard gap <= height * maximumGapRatio else { return false }

        // Roughly the same size. The threshold is low because Vision's line boxes are not tight —
        // a Chinese line and its own wrapped continuation measured 30.8 pt against 20.6 pt (0.67),
        // *closer* than a window title is to body text (0.71). Size alone therefore cannot
        // separate chrome from prose; the column test below is what does (finding 19).
        let heights = (min(upper.box.height, lower.box.height), max(upper.box.height, lower.box.height))
        guard heights.1 > 0, heights.0 / heights.1 >= 0.6 else { return false }

        // Same column: wrapped lines line up on the left, or on the right where a first line is
        // indented — and failing both, one line still sits almost entirely under the other. A
        // centred title matches none of the three. Heuristics fitted to real captures, not derived.
        guard sharesColumn(upper, lower) else { return false }
        let overlap = min(upper.box.maxX, lower.box.maxX) - max(upper.box.minX, lower.box.minX)
        return overlap >= min(upper.box.width, lower.box.width) * minimumOverlap
    }

    /// No space after a trailing hyphen, and none between CJK characters — Chinese has no
    /// inter-word spaces, so inserting one corrupts the sentence.
    ///
    /// The hyphen itself is **kept**. Deleting it repairs a word broken across lines
    /// (`prepa-` + `ration`) and destroys a real one (`a well-` + `known author` →
    /// `a wellknown author`), and the two are indistinguishable from the text alone. On screen the
    /// second case is far the commoner: CSS `hyphens` is off by default, editors do not hyphenate,
    /// so a hyphen at a line end is usually lexical and was visibly there. Keeping it leaves a
    /// wrong word that still shows the reader what was on screen; deleting it invents one that
    /// never was.
    private static func separator(between text: String, and next: String) -> String {
        if text.hasSuffix("-") { return "" }
        guard let last = text.unicodeScalars.last, let first = next.unicodeScalars.first else { return "" }
        return isCJK(last) && isCJK(first) ? "" : " "
    }

    /// Whether `text` is CJK — where the tokeniser and an app's own word breaks are *expected* to
    /// disagree, because Chinese has no inter-word spaces.
    public static func isCJKText(_ text: String) -> Bool {
        // *Any* CJK scalar, not just the first: a mixed-script word like "iPhone手机" leads with
        // Latin, and testing only the first character excluded exactly the case that needs the
        // fallback.
        text.unicodeScalars.contains(where: isCJK)
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,  // CJK punctuation
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,  // ideographs
             0xFF00...0xFFEF,  // fullwidth forms
             0x20000...0x2FA1F:  // supplementary ideographs
            true
        default: false
        }
    }
}

/// Whether recognised text ran into the edge of the capture, which means it may be cut off.
///
/// **This matters more than it looks.** Joining two lines that were each cut at the capture's edge
/// produces a fluent sentence that was never on screen — measured, and it reads perfectly:
/// "Serendipity favours the prepared mind, yet the unglamorous preparation that nobody witness".
/// Sent to a model as "explain this word in this sentence", it produces a confident answer about a
/// sentence the reader never saw.
public enum CaptureEdge {
    public static func clips(_ boxes: [CGRect], tolerance: CGFloat = 0.004) -> Bool {
        boxes.contains { box in
            box.minX <= tolerance || box.maxX >= 1 - tolerance
                || box.minY <= tolerance || box.maxY >= 1 - tolerance
        }
    }
}
