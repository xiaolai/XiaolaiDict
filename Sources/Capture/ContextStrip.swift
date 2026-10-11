import CoreGraphics
import DictionaryModel
import Foundation

/// The sides of a strip: above the pointer's paragraph and below it.
public struct StripSides: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let above = StripSides(rawValue: 1 << 0)
    public static let below = StripSides(rawValue: 1 << 1)
}

/// **The strip the pixel path reads, and how it grows** — the window's full width, centred on the pointer's row.
///
/// The band was 140 pt, decided before anything was read, and a sentence taller than that was cut and stored as
/// `complete`: the owner's ledger (2026-10-11) holds a command soft-wrapped over about eight rows, kept from its bullet
/// to `pkill`, mid-command, at confidence 1.0. The height is now where reading starts, not where it must stop: the
/// paragraph around the pointer is found from the layout (`ParagraphFinder`), and a side that ran into the strip's edge
/// with no boundary in sight is read again from a taller strip, up to a maximum, inside a budget.
///
/// Heights are **points**, not a `Scale`: a strip measures someone else's window, and nothing about it grows with the
/// reader's own text size.
public enum ContextStrip {
    /// **Where reading starts.** Measured 2026-10-11 with the pointer on the first row of a five-row paragraph about
    /// 100 pt tall: 140 pt read three of the five rows and 300 pt read the whole paragraph. Cost, three tiles warm:
    /// 140 pt 0.85 s, 300 pt 0.99 s, 500 pt 1.40 s — a per-tile fixed cost dominates, so height is nearly free.
    public static let initialHeight: CGFloat = 300

    /// **How far an open side grows per read**: half the initial strip, so a paragraph that runs a little past it costs
    /// one more read and not two.
    public static let growthStep: CGFloat = 150

    /// **The tallest strip read.** Twice the initial height, still under the 1.8–2.3 s a whole window cost; past it a
    /// paragraph is a page, and the sentence is marked as possibly cut rather than chased.
    public static let maximumHeight: CGFloat = 600

    /// **The most text joined around the pointer**, in UTF-16 units — the dictionary service's own bound on a sentence
    /// (`LookupRequest.maximumSentenceLength`), past which it refuses to ask about phrases. A longer context would be
    /// read and then thrown away, so it is never assembled.
    public static let maximumCharacters = LookupRequest.maximumSentenceLength

    /// **How long the whole read may take before no further growth is started.** Inside the capture deadline (5 s) with
    /// room for a growth read that overruns its estimate, so growing can never turn a read into a timeout; and short,
    /// because the panel waits for the word, and the word waits for the read.
    public static let growthBudget: Duration = .seconds(3)

    /// **A growth read is estimated at twice the read just made.** Measured, a taller strip costs little more than the
    /// one before it (0.99 s against 1.40 s for 300 and 500 pt); twice is the margin for a busy Mac.
    static let growthEstimate = 2

    /// The strip grown toward `sides`, by `growthStep` on each, inside `window` and no taller than `maximumHeight` —
    /// or nil where it cannot grow at all on any side asked for. Vertical ranges in screen points, y down.
    public static func grown(
        _ strip: ClosedRange<CGFloat>, toward sides: StripSides, within window: ClosedRange<CGFloat>
    ) -> ClosedRange<CGFloat>? {
        var lower = strip.lowerBound
        var upper = strip.upperBound
        var allowance = maximumHeight - (upper - lower)
        if sides.contains(.above), allowance > 0 {
            let step = min(growthStep, allowance, max(0, lower - window.lowerBound))
            lower -= step
            allowance -= step
        }
        if sides.contains(.below), allowance > 0 {
            upper += min(growthStep, allowance, max(0, window.upperBound - upper))
        }
        guard lower < strip.lowerBound || upper > strip.upperBound else { return nil }
        return lower...upper
    }

    /// Whether a further read, estimated from the last, still ends inside `growthBudget` of the read's start.
    public static func affordable(elapsed: Duration, lastRead: Duration) -> Bool {
        elapsed + lastRead * growthEstimate <= growthBudget
    }
}

/// **The columns of a capture, found from where its ink is — never from a position.**
///
/// A window split into panes reads as rows that run across both. Measured 2026-10-11 on a 5344 px window with two
/// terminal panes: without a column split, words in the middle of the left pane were lost, and a boundary set by hand
/// at the wrong place (2000 px against a pane ending near 2500) is the defect this exists to prevent. A gutter is a band
/// at least `minimumGutter` line heights wide, interior to the text, with no ink on any row — or, where no such band
/// exists, with no ink on any row but one: a title or a status line over both panes, which leaves the gutter present on
/// a majority of rows as long as there are three or more. Two crossing rows are not tolerated, so a layout they cross
/// is read as one column, which is what the reading was before columns were found at all.
public enum ColumnLayout {
    /// **Wider than anything inside one row.** Fragments of one row are joined within one line height
    /// (`LineJoiner.sameRowGap`), and the two columns measured for that rule sat 2.5 line heights apart; a word space is
    /// a third of one.
    static let minimumGutter: CGFloat = 1.5

    /// The columns, left to right, in points across `region`, split at the middle of each gutter. One column where
    /// there is no gutter, and for a capture with no size.
    public static func columns(of lines: [RecognisedLine], region: CGSize) -> [ClosedRange<CGFloat>] {
        let width = max(region.width, 0)
        guard width > 0, region.height > 0, !lines.isEmpty else { return [0...width] }
        let rows = LineJoiner.rows(in: lines, region: region)
        let ink: [[ClosedRange<CGFloat>]] = rows.map { row in
            row.members.map { lines[$0].box.minX * width...max(lines[$0].box.minX, lines[$0].box.maxX) * width }
        }
        let height = Statistics.median(rows.map { $0.line.box.height * region.height }) ?? 0
        let minimum = height * minimumGutter
        // Empty on every row first; only where none is found may a minority of rows cross a gutter. Asked in this order,
        // a sparse pane — a single prompt beside a page of text — is still found by the strict rule, which the tolerant
        // one would fold into the margin.
        var gutters = Self.gutters(in: ink, width: width, minimum: minimum)
        if gutters.isEmpty, ink.count >= 3 {
            // One row set aside at a time; of the layouts that then show a gutter, the one with the widest gutters.
            gutters = ink.indices
                .map { skipped in
                    Self.gutters(in: ink.indices.filter { $0 != skipped }.map { ink[$0] }, width: width, minimum: minimum)
                }
                .max { $0.map { $0.upperBound - $0.lowerBound }.reduce(0, +) < $1.map { $0.upperBound - $0.lowerBound }.reduce(0, +) }
                ?? []
        }
        var bounds: [CGFloat] = [0]
        bounds += gutters.map { ($0.lowerBound + $0.upperBound) / 2 }
        bounds.append(width)
        return zip(bounds, bounds.dropFirst()).map { $0...$1 }
    }

    /// The maximal bands at least `minimum` wide where no row has ink, touching neither side of the capture — a band
    /// that reaches the edge is a margin, with nothing beyond it to be a column.
    private static func gutters(
        in ink: [[ClosedRange<CGFloat>]], width: CGFloat, minimum: CGFloat
    ) -> [ClosedRange<CGFloat>] {
        let edges = Array(Set([0, width] + ink.flatMap { $0.flatMap { [$0.lowerBound, $0.upperBound] } }))
            .filter { $0 >= 0 && $0 <= width }.sorted()
        var found: [ClosedRange<CGFloat>] = []
        var start: CGFloat?
        for (left, right) in zip(edges, edges.dropFirst()) {
            let middle = (left + right) / 2
            if !ink.contains(where: { $0.contains { $0.contains(middle) } }) {
                if start == nil { start = left }
            } else if let open = start {
                if open > 0, left - open >= minimum { found.append(open...left) }
                start = nil
            }
        }
        // A band still open at the right-hand edge is the right margin.
        return found
    }
}

/// The paragraph around the pointer, and the sides on which the strip ran out before it did.
public struct StripParagraph: Equatable, Sendable {
    /// The paragraph's rows as one run of text, pointing back into the lines it was read from.
    public let block: TextBlock
    /// **The sides with no boundary in evidence**: the paragraph ran into the strip's edge, or into the length cap. A
    /// sentence that reaches an open side may be cut.
    public let open: StripSides
    /// The open sides a taller strip could close — every open side but one stopped by the length cap.
    public let growable: StripSides
}

/// **The paragraph around the pointer, found from the layout alone** — a pure function of recognised lines and where
/// they sit, with no model and no screen.
///
/// Rows are grouped first (`LineJoiner.rows`, Vision splitting one visual line into several observations), then the
/// pointer's column is kept (`ColumnLayout`), then rows are walked up and down from the pointer's until the layout says
/// a paragraph ends: a gap clearly larger than the column's line spacing, a row that starts with a list marker, a
/// change of indentation that is neither a first-line indent nor a hanging one, or a change of type size. A soft-wrapped
/// row continues the paragraph. Where the walk runs out of rows instead, the side is closed only if the strip shows
/// enough empty space beyond the last row that a row hidden past the edge would itself have been a paragraph away.
///
/// Sentence boundaries are not decided here: the paragraph is what `TextSegmenter` cuts the sentence from, and a stop
/// followed by a capital is found there, in the joined text.
public enum ParagraphFinder {
    /// A row this much further from the last than the column's median spacing starts a new paragraph.
    static let paragraphPitch: CGFloat = 1.5
    /// A clear gap this many line heights tall starts a new paragraph, whatever the spacing elsewhere — the rule that
    /// holds where there are too few rows for a median to mean anything.
    static let paragraphGap: CGFloat = 1.5
    /// Two rows set this differently in size are not one paragraph — a title over body text. `LineJoiner`'s own ratio.
    static let sizeRatio: CGFloat = 0.6
    /// Two left edges closer than this many line heights are one margin: Vision's boxes jitter, and a character is
    /// about half a line height wide.
    static let marginTolerance: CGFloat = 0.5
    /// **A row this close to the strip's top or bottom edge, in line heights, may be cut by it.** Vision reads a row the
    /// edge cuts in half with a short box, and that box failed the size test and closed the paragraph there as complete
    /// (the E2E Mac, 2026-10-11). Such a row is the strip's edge, not a boundary: the walk stops before it, open.
    static let edgeContact: CGFloat = 0.25

    public static func paragraph(around index: Int, in lines: [RecognisedLine], region: CGSize) -> StripParagraph {
        guard lines.indices.contains(index), region.width > 0, region.height > 0 else {
            // A capture with no size has no layout to read; `LineJoiner` says so loudly and joins nothing.
            return StripParagraph(
                block: LineJoiner.block(around: index, in: lines, region: region), open: [.above, .below], growable: [])
        }
        let layout = Layout(around: index, in: lines, region: region)
        var top = layout.seed
        var bottom = layout.seed
        var open: StripSides = []
        var capped: StripSides = []
        if !layout.walkUp(from: &top) { open.insert(.above) }
        if !layout.walkDown(from: &bottom, paragraphTop: top) { open.insert(.below) }

        // **The cap, shared around the pointer**: the side further from it gives up a row first.
        var length = layout.length(top...bottom)
        while length > ContextStrip.maximumCharacters, top < bottom {
            if layout.seed - top > bottom - layout.seed {
                top += 1
                capped.insert(.above)
            } else {
                bottom -= 1
                capped.insert(.below)
            }
            length = layout.length(top...bottom)
        }
        open.formUnion(capped)
        let block = LineJoiner.assemble(
            Array(top...bottom), of: layout.rows, seed: layout.seed, pointingAt: index, in: lines)
        return StripParagraph(block: block, open: open, growable: open.subtracting(capped))
    }

    /// The pointer's column, as rows sorted top to bottom, measured in points.
    private struct Layout {
        let rows: [LineJoiner.Row]
        let seed: Int
        let region: CGSize
        /// The column's median row height, and the median distance from one row's top to the next.
        let lineHeight: CGFloat
        let pitch: CGFloat

        init(around index: Int, in lines: [RecognisedLine], region: CGSize) {
            self.region = region
            let columns = ColumnLayout.columns(of: lines, region: region)
            // A centre is clamped into the capture, so a box that overhangs it still belongs to the column at that side
            // rather than to none.
            func centre(_ line: Int) -> CGFloat { min(max(lines[line].box.midX, 0), 1) * region.width }
            let column = columns.first { $0.contains(centre(index)) } ?? 0...region.width
            let kept = lines.indices.filter { $0 == index || column.contains(centre($0)) }
            let sorted = LineJoiner.rows(in: kept.map { lines[$0] }, region: region)
                .map { row in
                    LineJoiner.Row(
                        members: row.members.map { kept[$0] }, line: row.line,
                        offsets: Dictionary(uniqueKeysWithValues: row.offsets.map { (kept[$0.key], $0.value) }))
                }
                .sorted { $0.line.box.minY < $1.line.box.minY }
            rows = sorted
            seed = sorted.firstIndex { $0.members.contains(index) } ?? 0
            let height = Statistics.median(sorted.map { $0.line.box.height * region.height }) ?? 0
            lineHeight = height
            let steps = zip(sorted, sorted.dropFirst())
                .map { ($1.line.box.minY - $0.line.box.minY) * region.height }
                .filter { $0 > height * 0.5 }
            pitch = Statistics.median(steps) ?? height * ParagraphFinder.paragraphPitch
        }

        func top(_ row: Int) -> CGFloat { rows[row].line.box.minY * region.height }
        func bottom(_ row: Int) -> CGFloat { rows[row].line.box.maxY * region.height }
        func left(_ row: Int) -> CGFloat { rows[row].line.box.minX * region.width }
        func height(_ row: Int) -> CGFloat { rows[row].line.box.height * region.height }
        func marked(_ row: Int) -> Bool { ListMarker.starts(rows[row].line.text) }
        func touchesTop(_ row: Int) -> Bool { top(row) <= lineHeight * ParagraphFinder.edgeContact }
        func touchesBottom(_ row: Int) -> Bool { bottom(row) >= region.height - lineHeight * ParagraphFinder.edgeContact }

        func length(_ range: ClosedRange<Int>) -> Int {
            range.map { rows[$0].line.text.utf16.count }.reduce(0, +) + range.count - 1
        }

        /// Whether a row whose top and bottom are `upper` lies a paragraph away from one at `lower`.
        func breaks(upper: (top: CGFloat, bottom: CGFloat), lower: (top: CGFloat, bottom: CGFloat)) -> Bool {
            lower.top - upper.top > pitch * ParagraphFinder.paragraphPitch
                || lower.top - upper.bottom > lineHeight * ParagraphFinder.paragraphGap
        }

        func breaks(_ upper: Int, _ lower: Int) -> Bool {
            let sizes = (min(height(upper), height(lower)), max(height(upper), height(lower)))
            if sizes.1 > 0, sizes.0 / sizes.1 < ParagraphFinder.sizeRatio { return true }
            return breaks(upper: (top(upper), bottom(upper)), lower: (top(lower), bottom(lower)))
        }

        func sameMargin(_ a: Int, _ b: Int) -> Bool {
            abs(left(a) - left(b)) <= lineHeight * ParagraphFinder.marginTolerance
        }

        /// Walks `top` upward to the paragraph's first row. True where a boundary was found, false where the strip ran
        /// out first. **The edge is a boundary only if a row hidden past it would be one**: the worst such row starts
        /// just above the edge and is a line height tall.
        func walkUp(from top: inout Int) -> Bool {
            while true {
                if marked(top) { return true }
                guard top > 0 else {
                    return breaks(upper: (0, lineHeight), lower: (self.top(top), bottom(top)))
                }
                let candidate = top - 1
                if touchesTop(candidate) { return false }
                if breaks(candidate, top) { return true }
                if !sameMargin(candidate, top) {
                    // A list item's hanging indent, or a first line set in from the rest: that row starts this
                    // paragraph. Any other change of margin is another block.
                    if marked(candidate) || left(candidate) > left(top) {
                        top = candidate
                    }
                    return true
                }
                top = candidate
            }
        }

        /// Walks `bottom` downward to the paragraph's last row; true where a boundary was found.
        func walkDown(from bottom: inout Int, paragraphTop: Int) -> Bool {
            while true {
                guard bottom < rows.count - 1 else {
                    let edge = region.height
                    return breaks(upper: (self.top(bottom), self.bottom(bottom)), lower: (edge - lineHeight, edge))
                }
                let candidate = bottom + 1
                if touchesBottom(candidate) { return false }
                if breaks(bottom, candidate) || marked(candidate) { return true }
                if !sameMargin(candidate, bottom) {
                    // Only the paragraph's first row may differ from the rest — a list marker hanging out, or a first
                    // line set in.
                    let firstLine = bottom == paragraphTop && (marked(bottom) || left(bottom) > left(candidate))
                    guard firstLine else { return true }
                }
                bottom = candidate
            }
        }
    }
}

/// **A row that starts a list item**: a bullet, a dash or star followed by a space, or a number with a stop or a
/// bracket. A dash running into a word — `-f`, a soft-wrapped flag — is not one.
enum ListMarker {
    private static let bullets: Set<Character> = ["•", "◦", "▪", "▫", "‣", "⁃", "●", "○", "■", "□", "⏺", "∙", "➤", "▶"]
    private static let dashes: Set<Character> = ["-", "*", "+"]

    static func starts(_ text: String) -> Bool {
        let trimmed = text.drop { $0.isWhitespace }
        guard let first = trimmed.first else { return false }
        let rest = trimmed.dropFirst()
        if bullets.contains(first) { return rest.first.map(\.isWhitespace) ?? true }
        if dashes.contains(first) { return rest.first?.isWhitespace ?? false }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count) else { return false }
        let after = trimmed.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")" else { return false }
        return after.dropFirst().first?.isWhitespace ?? false
    }
}

enum Statistics {
    /// The middle value — the lower of the two middles for an even count — or nil for none.
    static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[(values.count - 1) / 2]
    }
}
