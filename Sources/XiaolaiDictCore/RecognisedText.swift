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
    /// **The lowest confidence of any line in it.**
    ///
    /// Measured on a reader's capture 2026-09-27: the line they pointed at came back at 1.00 while
    /// the fragment joined to it, standing where "because" was, came back at **0.30** as
    /// `00C211٢0`. Reporting the pointed-at line's confidence would have rendered that sentence as
    /// certain. `CaptureQuality.isDoubtful` is the reader's warning and it can only be as good as
    /// the number it is given.
    ///
    /// **A caller that returns less than the whole block must not use this.** A block spans several
    /// sentences and only one of them is handed to the reader; the minimum over all of them marks a
    /// perfectly read sentence as doubtful because its neighbour was not. `confidence(over:)` is
    /// the scoped answer, and it is what `ScreenTextRecogniser` asks for.
    public let confidence: Double
    /// Where each contributing observation starts in `text`, UTF-16, keyed by its index in the
    /// lines the block was built from. This is what lets a caller ask which observations a span of
    /// the text actually came from.
    public let offsets: [Int: Int]

    public init(
        text: String, offsetShift: Int, lineIndices: [Int] = [], confidence: Double = 1,
        offsets: [Int: Int] = [:]
    ) {
        self.text = text
        self.offsetShift = offsetShift
        self.lineIndices = lineIndices
        self.confidence = confidence
        self.offsets = offsets
    }

    /// The observations overlapping `span`, in the order they were read.
    public func lines(covering span: NSRange, in lines: [RecognisedLine]) -> [Int] {
        lineIndices.filter { index in
            guard let start = offsets[index], lines.indices.contains(index) else { return false }
            let length = lines[index].text.utf16.count
            return NSIntersectionRange(span, NSRange(location: start, length: length)).length > 0
                || (length == 0 && NSLocationInRange(start, span))
        }
    }

    /// The lowest confidence among the observations overlapping `span` — the honest number for a
    /// caller that returns only that span. Falls back to the whole block's where the span covers
    /// nothing, which cannot be more optimistic than the truth.
    public func confidence(over span: NSRange, in lines: [RecognisedLine]) -> Double {
        let covering = self.lines(covering: span, in: lines)
        guard !covering.isEmpty else { return confidence }
        return covering.map { lines[$0].confidence }.min() ?? confidence
    }
}

/// Recognition produces lines; sentences run across them. This rebuilds the block of lines around
/// the pointer so the sentence is segmented from the whole block rather than from one line.
public enum LineJoiner {
    /// The block containing line `index`. Neighbours are taken while they sit close enough
    /// vertically **and share a column**, so a following paragraph, a second column, or a window
    /// title is left out — a TextEdit band once produced the sentence "fixture.txt An ephemeral
    /// beauty…", with the title bar joined into it (finding 18).
    /// `region` is the capture's size in points, and it is **required**. The row test compares
    /// points, not normalised units, which are not square: a band is far wider than it is tall, so
    /// a normalised horizontal gap and a normalised vertical height are simply different
    /// quantities. `RecognisedTextPicker.pick` already says this about its own distances;
    /// comparing them directly here folded the *other pane* of a split terminal into the reader's
    /// sentence — a 122-point gutter read as 0.048 against a line height of 0.13.
    ///
    /// **It has no default, and that is the point.** A `.zero` fallback quietly restored exactly
    /// the arithmetic above as though the capture were square, and the tests — the only callers
    /// that would have taken it — are precisely where a silently wrong comparison survives. A
    /// caller with a genuinely square capture says so by passing a square size.
    public static func block(
        around index: Int, in lines: [RecognisedLine], region: CGSize,
        maximumGapRatio: CGFloat = 1.0, minimumOverlap: CGFloat = 0.2
    ) -> TextBlock {
        precondition(region.width > 0 && region.height > 0, "the capture's size is not known")
        guard lines.indices.contains(index) else { return TextBlock(text: "", offsetShift: 0) }
        // **Rows first: Vision does not return one observation per visual line.** Measured
        // 2026-09-27 on a terminal, it split one line at a sentence boundary — the wide gap after
        // "them." — into two observations at the same `minY`. Sorted by `minY` alone those are two
        // lines, `joins` sees a *negative* gap between them and passes it, and `sharesColumn` then
        // matched the right-hand fragment with the line *above* on their right edges, because a
        // right-hand fragment ends where the line above ends. The reader's own line lost its left
        // half and the line above was spliced in its place. `LineJoinerSplitLineTests` holds the
        // measured geometry.
        // **Rows first: Vision does not return one observation per visual line.** Measured
        // 2026-09-27 on a terminal, it split one line at a sentence boundary — the wide gap after
        // "them." — into two observations at the same `minY`. Sorted by `minY` alone those are two
        // lines, `joins` sees a *negative* gap between them and passes it, and `sharesColumn` then
        // matched the right-hand fragment with the line *above* on their right edges, because a
        // right-hand fragment ends where the line above ends. The reader's own line lost its left
        // half and the line above was spliced in its place. `LineJoinerSplitLineTests` holds the
        // measured geometry.
        //
        // **Sorted once and kept sorted**, so there are two index spaces here and not three: a
        // position in `rows`, and an observation's index in `lines`. The earlier shape carried a
        // third — a position in a separate y-ordering that had to be mapped back through — and
        // every read of it was a chance to map the wrong way.
        let rows = Self.rows(in: lines, region: region)
            .sorted { $0.line.box.minY < $1.line.box.minY }
        guard let seed = rows.firstIndex(where: { $0.members.contains(index) }) else {
            return TextBlock(
                text: lines[index].text, offsetShift: 0, lineIndices: [index],
                confidence: lines[index].confidence, offsets: [index: 0])
        }
        let members = Self.members(
            around: seed, in: rows, maximumGapRatio: maximumGapRatio, minimumOverlap: minimumOverlap)
        return Self.assemble(members, of: rows, seed: seed, pointingAt: index, in: lines)
    }

    /// Which rows belong to the block, walking out from the seed.
    ///
    /// A row from *another column* is skipped rather than treated as the end: sorted by y, a
    /// two-column capture interleaves left₁, right₁, left₂ …, and stopping at right₁ dropped
    /// left₁'s own continuation. A row that *does* share the column and still fails the gap test
    /// is a different paragraph, and does end the block.
    private static func members(
        around seed: Int, in rows: [Row], maximumGapRatio: CGFloat, minimumOverlap: CGFloat
    ) -> [Int] {
        var members = [seed]
        for step in [-1, 1] {
            var edge = seed
            var position = seed + step
            while rows.indices.contains(position) {
                let candidate = rows[position].line
                if joins(
                    step < 0 ? candidate : rows[edge].line,
                    step < 0 ? rows[edge].line : candidate,
                    maximumGapRatio, minimumOverlap) {
                    members.append(position)
                    edge = position
                } else if sharesColumn(rows[seed].line, candidate) {
                    break  // same column, too far away: another paragraph
                }
                position += step
            }
        }
        return members.sorted()
    }

    /// The chosen rows as one run of text, with everything a caller needs to point back into it.
    private static func assemble(
        _ members: [Int], of rows: [Row], seed: Int, pointingAt index: Int, in lines: [RecognisedLine]
    ) -> TextBlock {
        var text = ""
        var shift = 0
        var offsets: [Int: Int] = [:]
        for position in members {
            let row = rows[position]
            let at = append(row.line.text, to: &text)
            for member in row.members { offsets[member] = at + row.offset(of: member) }
            // The seed is an *observation*, and its row may hold fragments before it — so the shift
            // is where the row starts plus where the observation starts inside the row. Pointing at
            // the row would put the word's offset before text that precedes it on the same line.
            if position == seed { shift = at + row.offset(of: index) }
        }
        let joined = members.flatMap { rows[$0].members }
        return TextBlock(
            text: text, offsetShift: shift, lineIndices: joined,
            confidence: joined.map { lines[$0].confidence }.min() ?? 1,
            offsets: offsets)
    }

    /// One visual line, however many observations Vision made of it.
    struct Row {
        /// The observations that make it up, in reading order — left to right.
        let members: [Int]
        /// Their union: one box spanning the whole line, which is what `joins` and `sharesColumn`
        /// were written for and what a half-line box quietly breaks.
        let line: RecognisedLine
        /// Where each member starts inside this row's text, UTF-16.
        let offsets: [Int: Int]

        /// Where observation `index` starts inside this row's text. Zero where it is not in it.
        func offset(of index: Int) -> Int { offsets[index] ?? 0 }
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

    /// The observations grouped into visual lines.
    ///
    /// **A candidate joins a row when it shares a band with *every* member and sits next to *some*
    /// member.** The two halves are anchored differently because each guards a different failure,
    /// and an earlier attempt that walked outwards from one edge got both wrong:
    ///
    /// - **Adjacency to any member**, so three fragments `A … B … C` where B bridges A and C
    ///   become one row even though A and C are far apart. Walking edge-to-edge instead looks
    ///   right until a short fragment sits *inside* a long one: the walk steps into it and can no
    ///   longer reach anything beyond, splitting a row that used to hold together.
    /// - **A band shared with every member**, so a chain cannot drift down the page one small step
    ///   at a time. Anchoring only to the seed is not enough either: a tall seed overlaps a
    ///   fragment high on its left and another low on its right, and those two share no band at
    ///   all.
    ///
    /// Adding a member can bring a further candidate within reach, so the row grows to a fixed
    /// point rather than in one pass.
    static func rows(in lines: [RecognisedLine], region: CGSize) -> [Row] {
        var remaining = Set(lines.indices)
        var groups: [[Int]] = []
        let readingOrder = lines.indices.sorted {
            lines[$0].box.minY != lines[$1].box.minY
                ? lines[$0].box.minY < lines[$1].box.minY
                : lines[$0].box.minX < lines[$1].box.minX
        }
        for seed in readingOrder where remaining.contains(seed) {
            remaining.remove(seed)
            var members = [seed]
            var grew = true
            while grew {
                grew = false
                // Nearest first, so a row that could take two candidates takes the closer one and
                // the further one is then judged against a row that already holds it.
                let reachable = remaining.filter { candidate in
                    members.allSatisfy { sharesRowBand(lines[$0].box, lines[candidate].box) }
                        && members.contains { sameRow(lines[$0].box, lines[candidate].box, region) }
                }
                guard let next = reachable.min(by: {
                    distance(lines[$0].box, to: members, in: lines)
                        < distance(lines[$1].box, to: members, in: lines)
                }) else { continue }
                remaining.remove(next)
                members.append(next)
                grew = true
            }
            groups.append(members)
        }
        return groups.map { row(of: $0, in: lines) }
    }

    /// The smallest horizontal gap between `box` and any member — how near the row it is.
    private static func distance(_ box: CGRect, to members: [Int], in lines: [RecognisedLine]) -> CGFloat {
        members.map { max(lines[$0].box.minX, box.minX) - min(lines[$0].box.maxX, box.maxX) }
            .min() ?? .greatestFiniteMagnitude
    }

    private static func row(of group: [Int], in lines: [RecognisedLine]) -> Row {
        let members = group.sorted { lines[$0].box.minX < lines[$1].box.minX }
        var text = ""
        var offsets: [Int: Int] = [:]
        var words: [RecognisedWord] = []
        var union = lines[members[0]].box
        for member in members {
            let at = append(lines[member].text, to: &text)
            offsets[member] = at
            // **Rebased.** A word's offset is into its own fragment; in the row it has to be into
            // the row. Flat-mapping them unchanged left every word after the first claiming a
            // position that is not its own — latent today, because the pick reads the original
            // observation, and a trap for the next reader who does not know that.
            words += lines[member].words.map {
                RecognisedWord(text: $0.text, utf16Offset: at + $0.utf16Offset, box: $0.box)
            }
            union = union.union(lines[member].box)
        }
        return Row(
            members: members,
            line: RecognisedLine(
                text: text, box: union, words: words,
                confidence: members.map { lines[$0].confidence }.min() ?? 1),
            offsets: offsets)
    }

    /// Appends `fragment` to `text` with the separator the two earn, and answers where it landed.
    ///
    /// One implementation, because the row assembly and the block assembly had a copy each and any
    /// change to the boundary rules had to be made in both.
    @discardableResult
    private static func append(_ fragment: String, to text: inout String) -> Int {
        let separator = text.isEmpty ? "" : separator(between: text, and: fragment)
        let at = text.utf16.count + separator.utf16.count
        text += separator + fragment
        return at
    }

    /// Whether two boxes sit in the same horizontal band — the vertical half of `sameRow`.
    static func sharesRowBand(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let shorter = min(a.height, b.height)
        guard shorter > 0 else { return false }
        return overlap / shorter >= sameRowOverlap
    }

    static func sameRow(_ a: CGRect, _ b: CGRect, _ region: CGSize) -> Bool {
        guard sharesRowBand(a, b) else { return false }
        // Negative where the boxes overlap horizontally, which is nearer still. Both sides are put
        // into points before they are compared; see `block(around:in:region:)`.
        let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
        return gap * region.width <= min(a.height, b.height) * region.height * sameRowGap
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

    /// Whether a scalar belongs to a script **written without spaces between words** — which is
    /// the question both callers are really asking: whether a line break between two of them is a
    /// word boundary, and whether the tokeniser may disagree with an app's own word breaks.
    ///
    /// Two corrections, 2026-09-27. **Kana were missing**: 0x3040–0x30FF is neither punctuation
    /// nor an ideograph, so joining `カタ` to `カナ` inserted a space that is not in the text. And
    /// **fullwidth Latin letters and digits were included**, because they sit inside the fullwidth
    /// block — so `ＨＥＬＬＯ` and `ＷＯＲＬＤ` were joined with no space at all. They are Latin
    /// wearing a wide glyph and take a space like their ASCII spellings.
    ///
    /// **Hangul is deliberately absent.** Korean is written *with* inter-word spaces, so two
    /// Korean fragments want the space that omitting it here gives them.
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // Fullwidth Latin letters and digits: Latin, whatever their width.
        case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            false
        case 0x3000...0x303F,  // CJK punctuation
             0x3040...0x309F, 0x30A0...0x30FF,  // hiragana, katakana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,  // ideographs
             0xFF00...0xFFEF,  // the rest of the fullwidth forms, incl. halfwidth katakana
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
