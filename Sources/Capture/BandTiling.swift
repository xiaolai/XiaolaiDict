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
        let band = CGFloat(bandWidth)

        /// One box in the band, with how far it sits from the nearest edge of its tile that is not the band's own,
        /// and whether it is a run — which a pointer can pick — or the box of an observation that had none.
        struct Placed {
            let tile: Int
            let box: CGRect
            let depth: CGFloat
            let isRun: Bool
        }
        func place(_ box: CGRect, in tile: BandTile, index: Int, isRun: Bool) -> Placed {
            let left = CGFloat(tile.x) + box.minX * CGFloat(tile.width)
            let right = left + box.width * CGFloat(tile.width)
            let bandBox = CGRect(x: left / band, y: box.minY, width: box.width * CGFloat(tile.width) / band, height: box.height)
            var depth = CGFloat.infinity
            if tile.x > 0 { depth = min(depth, max(0, left - CGFloat(tile.x))) }
            if tile.x + tile.width < bandWidth { depth = min(depth, max(0, CGFloat(tile.x + tile.width) - right)) }
            return Placed(tile: index, box: bandBox, depth: depth, isRun: isRun)
        }
        /// Two boxes over the same ink: they overlap by half or more of the narrower along a row.
        func sameInk(_ a: CGRect, _ b: CGRect) -> Bool {
            let across = min(a.maxX, b.maxX) - max(a.minX, b.minX)
            let down = min(a.maxY, b.maxY) - max(a.minY, b.minY)
            return across > 0.5 * min(a.width, b.width) && down > 0.5 * min(a.height, b.height)
        }

        // Every box of every tile, once, each with a number to be kept or dropped by.
        var placed: [[[Placed]]] = []     // [tile][line] -> its runs' boxes, or its own box where it has none
        var ids: [[[Int]]] = []
        var all: [Placed] = []
        for (index, entry) in read.enumerated() {
            var tilePlaced: [[Placed]] = []
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
            return x.tile != y.tile ? x.tile < y.tile : a < b
        }
        /// How much of `box`'s width the kept runs of other tiles cover along its row. A word is a small part of a
        /// sentence: only runs that together cover most of an observation without runs are its duplicate, and one that
        /// covers a sixth of it leaves the rest of its text with no other source.
        func coverage(of box: Placed, by retained: [Placed]) -> CGFloat {
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
        var retained: [Placed] = []
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

        var merged: [RecognisedLine] = []
        for (t, entry) in read.enumerated() {
            for (l, line) in entry.lines.enumerated() {
                let boxes = placed[t][l]
                let lineIDs = ids[t][l]
                guard !line.runs.isEmpty else {
                    if let only = boxes.first, kept[lineIDs[0]] {
                        merged.append(RecognisedLine(text: line.text, box: only.box, runs: [], confidence: line.confidence))
                    }
                    continue
                }
                var group: [(run: RecognisedRun, box: CGRect)] = []
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
                    merged.append(RecognisedLine(
                        text: text, box: CGRect(x: left, y: line.box.minY, width: right - left, height: line.box.height),
                        runs: runs, confidence: line.confidence))
                }
                for (r, run) in line.runs.enumerated() {
                    if kept[lineIDs[r]] { group.append((run, boxes[r].box)) } else { flush() }
                }
                flush()
            }
        }
        return merged
    }
}
