import CoreGraphics
import Foundation

/// One tile of a band that is too wide to read in one piece: where it starts and how wide it is, in pixels of the band.
public struct BandTile: Equatable, Sendable {
    public let x: Int
    public let width: Int

    public init(x: Int, width: Int) {
        self.x = x
        self.width = width
    }
}

/// A wide band read as overlapping tiles and put back together by position.
///
/// **Why it exists.** Vision reads small text only in an image up to ~2400 px wide: the window's whole width, 5120
/// px on the dev Mac, read 47% of uncommon words exactly against 100% for a 2000 px strip (measured 2026-10-05,
/// ADR-0016 addendum). The band is as wide as the window because the sentence the reader pointed into is what it
/// is for — so cutting the width would trade the accuracy of the word for the context of the sentence. Tiling keeps
/// both: each tile is read at the accuracy of a narrow strip, and the sentence is rebuilt across all of them.
///
/// **One decision over both measurements, not one per tile.** Tiles overlap so that a word on a boundary is whole in
/// one of them. Two boxes from different tiles over the same ink — they overlap in a row — are one word, and the one
/// read **further from its tile's edge** is kept: a fragment a tile's edge cut is at distance zero and loses to the
/// tile that saw the word entire, and two readings of one word keep the better placed. A first version gave each tile
/// the places it "owned" and kept the runs whose centre fell in them; on real Ghostty pixels the same word's centre
/// was 1701 in one tile and 1698 in the next with the boundary at 1700, and **both tiles dropped it**. A choice made
/// twice from two noisy measurements can disagree with itself; this one is made once. A token longer than the overlap
/// can still be cut in both tiles, which for a path or a URL costs nothing a lookup would use.
public enum BandTiling {
    /// The plan for a band `width` pixels wide: one tile where it fits, otherwise tiles of at most `maximum`
    /// overlapping by at least `overlap`, the last flush with the right edge.
    ///
    /// A limit that cannot tile — not above the overlap, or not positive — is a caller's mistake and answers with
    /// the whole band as one tile, which is what the band was before tiling: loud in its result and not a trap, and
    /// never a loop.
    public static func tiles(forWidth width: Int, maximum: Int, overlap: Int) -> [BandTile] {
        guard width > 0 else { return [] }
        guard width > maximum, maximum > overlap, overlap > 0 else { return [BandTile(x: 0, width: width)] }
        let step = maximum - overlap
        var starts = [0]
        while starts[starts.count - 1] + maximum < width { starts.append(starts[starts.count - 1] + step) }
        // The last tile sits flush with the edge rather than hanging past it, so every tile is `maximum` wide.
        // It starts further right than the plan's next step would have, never further left, so overlap only grows.
        starts[starts.count - 1] = width - maximum
        return starts.map { BandTile(x: $0, width: maximum) }
    }

    /// The tiles' lines as the lines of one band: every run once, in the band's own normalised space, as the fragments
    /// of the lines they were — so the picker's cursor and the line joiner see the band they always did.
    ///
    /// `read` pairs each tile with the lines Vision gave for it, normalised to the tile. Heights are the band's own,
    /// since every tile is as tall as the band. A fragment keeps its line's own spacing and its runs index into the
    /// fragment's text. An observation with no runs competes as a whole, by its own box.
    public static func merged(_ read: [(tile: BandTile, lines: [RecognisedLine])], bandWidth: Int) -> [RecognisedLine] {
        guard bandWidth > 0 else { return [] }
        func place(_ box: CGRect, in tile: BandTile, index: Int, isRun: Bool) -> PlacedBox {
            PlacedBox(box, in: tile, index: index, isRun: isRun, bandWidth: bandWidth)
        }
        func sameInk(_ a: CGRect, _ b: CGRect) -> Bool { PlacedBox.sameInk(a, b) }

        // Every box of every tile, once, each with a number to be kept or dropped by.
        var placed: [[[PlacedBox]]] = []     // [tile][line] -> its runs' boxes, or its own box where it has none
        var ids: [[[Int]]] = []
        var all: [PlacedBox] = []
        for (index, entry) in read.enumerated() {
            var tilePlaced: [[PlacedBox]] = []
            var tileIDs: [[Int]] = []
            for line in entry.lines {
                let boxes = line.runs.isEmpty
                    ? [place(line.box, in: entry.tile, index: index, isRun: false)]
                    : line.runs.map { place($0.box, in: entry.tile, index: index, isRun: true) }
                tilePlaced.append(boxes)
                tileIDs.append(boxes.map { box in all.append(box); return all.count - 1 })
            }
            placed.append(tilePlaced)
            ids.append(tileIDs)
        }
        // **Best first, and a box is dropped only for one that was kept.** Dropping a box for one that was itself
        // dropped loses words: `bbbb` loses to `aa`, and `cc` — which only `bbbb` covered — would then lose to
        // `bbbb` and vanish with it. Runs come before observations without any, which a pointer cannot pick and
        // which must never cost a run its place; then the box further from its tile's edge; then the earlier tile.
        let order = all.indices.sorted { a, b in
            let (x, y) = (all[a], all[b])
            if x.isRun != y.isRun { return x.isRun }
            if x.depth != y.depth { return x.depth > y.depth }
            // **Two pieces that are both cut, the one that saw more of the ink.** Both are at depth zero, and the tile
            // order used to decide: a 200 px piece of a path from the earlier tile then dropped the 1600 px reading
            // of the same path, and the line lost everything only the longer piece held.
            if x.box.width != y.box.width { return x.box.width > y.box.width }
            return x.tile != y.tile ? x.tile < y.tile : a < b
        }
        /// How much of `box`'s width the kept runs of other tiles cover along its row. A word is a small part of a
        /// sentence: only runs that together cover most of an observation without runs are its duplicate, and one that
        /// covers a sixth of it leaves the rest of its text with no other source.
        func coverage(of box: PlacedBox, by retained: [PlacedBox]) -> CGFloat {
            guard box.box.width > 0 else { return 0 }
            // The union of what they cover, not the sum: two runs that overlap cover their overlap once.
            let spans = retained.filter { $0.isRun && $0.tile != box.tile }.compactMap { other -> (CGFloat, CGFloat)? in
                let down = min(box.box.maxY, other.box.maxY) - max(box.box.minY, other.box.minY)
                guard down > 0.5 * min(box.box.height, other.box.height) else { return nil }
                let start = max(box.box.minX, other.box.minX), end = min(box.box.maxX, other.box.maxX)
                return end > start ? (start, end) : nil
            }.sorted { $0.0 < $1.0 }
            var covered: CGFloat = 0
            var reach = -CGFloat.infinity
            for (start, end) in spans {
                covered += max(0, end - max(start, reach))
                reach = max(reach, end)
            }
            return covered / box.box.width
        }
        var kept = [Bool](repeating: false, count: all.count)
        var retained: [PlacedBox] = []
        for id in order {
            let box = all[id]
            let duplicate = box.isRun
                ? retained.contains { $0.tile != box.tile && sameInk(box.box, $0.box) }
                : retained.contains { $0.tile != box.tile && !$0.isRun && sameInk(box.box, $0.box) }
                    || coverage(of: box, by: retained) > 0.5
            guard !duplicate else { continue }
            kept[id] = true
            retained.append(box)
        }

        // **A run that lost but saw ink no kept run covers**: the reading kept over it is missing that text — Vision can
        // leave characters out of the middle of a long token in one tile and read them in another (measured
        // 2026-10-11). The kept runs it overlapped are marked, so their line says it is cut inside.
        var holed = Set<Int>()
        for id in all.indices where !kept[id] && all[id].isRun {
            let box = all[id].box
            let over = all.indices.filter {
                kept[$0] && all[$0].isRun && PlacedBox.sameRow(all[$0].box, box)
                    && min(all[$0].box.maxX, box.maxX) > max(all[$0].box.minX, box.minX)
            }
            let spans = over.map { (max(all[$0].box.minX, box.minX), min(all[$0].box.maxX, box.maxX)) }.sorted { $0.0 < $1.0 }
            var covered: CGFloat = 0
            var reach = -CGFloat.infinity
            for (start, end) in spans {
                covered += max(0, end - max(start, reach))
                reach = max(reach, end)
            }
            if (box.width - covered) * CGFloat(bandWidth) > holeSlack { holed.formUnion(over) }
        }

        var merged: [RecognisedLine] = []
        for (t, entry) in read.enumerated() {
            for (l, line) in entry.lines.enumerated() {
                let boxes = placed[t][l]
                let lineIDs = ids[t][l]
                guard !line.runs.isEmpty else {
                    if let only = boxes.first, kept[lineIDs[0]] {
                        merged.append(RecognisedLine(text: line.text, box: only.box, runs: [], confidence: line.confidence,
                                                     cutInside: line.cutInside))
                    }
                    continue
                }
                var group: [(run: RecognisedRun, box: CGRect, cut: Bool)] = []
                func flush() {
                    defer { group.removeAll() }
                    guard let first = group.first?.run, let last = group.last?.run else { return }
                    let start = first.utf16Offset, end = last.utf16Offset + last.text.utf16.count
                    let text = (line.text as NSString).length >= end
                        ? (line.text as NSString).substring(with: NSRange(location: start, length: end - start))
                        : group.map(\.run.text).joined(separator: " ")
                    let runs = group.map {
                        RecognisedRun(text: $0.run.text, utf16Offset: $0.run.utf16Offset - start, box: $0.box)
                    }
                    let left = runs.map(\.box.minX).min() ?? 0, right = runs.map(\.box.maxX).max() ?? 0
                    // **A kept run some tile's inner edge still cuts was seen whole by no tile** — the text on the far side
                    // of that edge is missing from this line, and saying so is all that can be done with it.
                    let cut = group.contains { $0.cut }
                    merged.append(RecognisedLine(
                        text: text, box: CGRect(x: left, y: line.box.minY, width: right - left, height: line.box.height),
                        runs: runs, confidence: line.confidence, cutInside: line.cutInside || cut))
                }
                for (r, run) in line.runs.enumerated() {
                    if kept[lineIDs[r]] {
                        group.append((run, boxes[r].box, boxes[r].depth <= edgeSlack || holed.contains(lineIDs[r])))
                    } else { flush() }
                }
                flush()
            }
        }
        return merged
    }
    /// **How close to a tile's inner edge a box may end and still be called cut by it**, in band pixels: a glyph the edge
    /// halved is boxed to the edge, or a pixel or two short of it.
    static let edgeSlack: CGFloat = 4

    /// **How much ink a dropped run may have seen that no kept run covers before the kept reading is missing text**, in
    /// band pixels: more than the jitter between two tiles' boxes for one word (3–4 px measured, 12 px tested), and
    /// about one character of 14 pt text at 2x.
    static let holeSlack: CGFloat = 16

    /// **Tiles to read again, each centred on a run that every tile saw only in part.**
    ///
    /// A token longer than the overlap — a path, a URL, a soft-wrapped command with no spaces — is cut by the edge of each
    /// tile that holds it, and the merge can keep only one of the pieces over the same ink: the text only the other piece
    /// held was lost from the *middle* of the line. Measured 2026-10-11 on a rendered terminal line at 2x (Menlo 14 pt,
    /// a 96-character path, 5120 px band, production tiles): **35 of 50** positions around a seam lost interior text —
    /// `…/worktrees/spel git -C …` — where one 2000 px read centred on the path read it exactly at every position.
    /// Such a run is read again from a tile of its own, in which it is whole and so outranks every piece of it.
    ///
    /// A run wider than `maximum` less the slack on both sides cannot be whole in any tile and is not re-read; the merge
    /// marks its line as cut inside. Empty where every run was whole somewhere — the ordinary case, which costs nothing.
    public static func rereads(
        _ read: [(tile: BandTile, lines: [RecognisedLine])], bandWidth: Int, maximum: Int
    ) -> [BandTile] {
        guard bandWidth > maximum, maximum > 0 else { return [] }
        let band = CGFloat(bandWidth)
        let runs: [PlacedBox] = read.enumerated().flatMap { index, entry in
            entry.lines.flatMap { line in
                line.runs.map { PlacedBox($0.box, in: entry.tile, index: index, isRun: true, bandWidth: bandWidth) }
            }
        }
        var extra: [BandTile] = []
        var settled = [Bool](repeating: false, count: runs.count)
        for seed in runs.indices where !settled[seed] && runs[seed].depth <= edgeSlack {
            // The pieces of one token: runs on the seed's row whose spans chain into one another.
            var members = [seed]
            var span = runs[seed].box.minX...runs[seed].box.maxX
            var grew = true
            while grew {
                grew = false
                for other in runs.indices where !members.contains(other) && PlacedBox.sameRow(runs[seed].box, runs[other].box) {
                    let box = runs[other].box
                    // Overlapping, not merely touching: neighbouring words read by two tiles can meet at a pixel.
                    guard min(box.maxX, span.upperBound) - max(box.minX, span.lowerBound) > edgeSlack / band else { continue }
                    members.append(other)
                    span = min(span.lowerBound, box.minX)...max(span.upperBound, box.maxX)
                    grew = true
                }
            }
            members.forEach { settled[$0] = true }
            // Whole somewhere: a reading no inner edge cut covers what every piece saw.
            let whole = members.contains { runs[$0].depth > edgeSlack
                && runs[$0].box.minX <= span.lowerBound + edgeSlack / band
                && runs[$0].box.maxX >= span.upperBound - edgeSlack / band }
            guard !whole else { continue }
            let width = (span.upperBound - span.lowerBound) * band
            guard width + 2 * edgeSlack < CGFloat(maximum) else { continue }
            let centre = (span.lowerBound + span.upperBound) / 2 * band
            let x = min(max(0, Int((centre - CGFloat(maximum) / 2).rounded())), bandWidth - maximum)
            let tile = BandTile(x: x, width: maximum)
            if !extra.contains(tile), !read.contains(where: { $0.tile == tile }) { extra.append(tile) }
        }
        return extra
    }
}

/// One box in the band, with how far it sits from the nearest edge of its tile that is not the band's own, and whether
/// it is a run — which a pointer can pick — or the box of an observation that had none.
struct PlacedBox {
    let tile: Int
    let box: CGRect
    let depth: CGFloat
    let isRun: Bool

    init(_ box: CGRect, in tile: BandTile, index: Int, isRun: Bool, bandWidth: Int) {
        let band = CGFloat(bandWidth)
        let left = CGFloat(tile.x) + box.minX * CGFloat(tile.width)
        let right = left + box.width * CGFloat(tile.width)
        self.box = CGRect(x: left / band, y: box.minY, width: box.width * CGFloat(tile.width) / band, height: box.height)
        var depth = CGFloat.infinity
        if tile.x > 0 { depth = min(depth, max(0, left - CGFloat(tile.x))) }
        if tile.x + tile.width < bandWidth { depth = min(depth, max(0, CGFloat(tile.x + tile.width) - right)) }
        self.depth = depth
        self.tile = index
        self.isRun = isRun
    }

    /// Two boxes over the same ink: they overlap by half or more of the narrower along a row.
    static func sameInk(_ a: CGRect, _ b: CGRect) -> Bool {
        let across = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return across > 0.5 * min(a.width, b.width) && sameRow(a, b)
    }

    /// Two boxes on one row: they overlap down the band by half or more of the shorter.
    static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0.5 * min(a.height, b.height)
    }
}
