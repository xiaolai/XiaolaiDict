import CoreGraphics
import Foundation
import Testing
import XiaolaiDictCore
@testable import XiaolaiDict

/// **The band is the window's width, and Vision is given it in tiles no wider than it reads reliably.**
///
/// Measured 2026-10-05 on real Ghostty captures made with the dev Mac's own configuration (SauceCodePro Nerd
/// Font Mono, Light, Catppuccin Mocha and Latte, 12–20 pt, 2x; 320 uncommon words per capture), reading the whole
/// 5120 px band in one call against tiles of it:
///
///     one call, 5120 px     47.3% of words read exactly  (0% at 12 pt, 25–30% at 14 pt, 94% at 20 pt)
///     tiles of 2000 px     100.0%  (640/640), the whole band's context kept
///     a strip 1200 pt/2400 px    99.7%        1300 pt/2600 px   93.1%        1400 pt/2800 px   96.4%
///
/// The one call also came back in 24 ms against ~50 ms a tile — Vision answering fast with almost nothing, the
/// silent empty result `reading-the-screen.md` §4 records without a cause. The context is the reason for the band,
/// so it is tiled rather than narrowed. What tiling costs is time: four tiles take ~200–250 ms where the one call
/// took 30 ms, and Vision does not run them faster side by side (measured, no speed-up).
struct ScreenTextRecogniserBandTests {
    /// A blank band `width` px wide — nothing to read; the reading is the stub's.
    private static func band(width: Int, height: Int = 280) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        return try #require(context.makeImage())
    }

    @Test func theLimitsStayInsideWhatWasMeasured() {
        #expect(ScreenTextRecogniser.maximumTilePixels <= 2400, "the last width read at 99.7% was 2400 px")
        #expect(ScreenTextRecogniser.tileOverlapPixels >= 600, "a word of 25 cells at 2x must fit in the overlap")
        #expect(ScreenTextRecogniser.tileOverlapPixels < ScreenTextRecogniser.maximumTilePixels)
    }

    /// **The wire:** a wide band reaches Vision as tiles, none wider than the limit, each the band's full height,
    /// and what comes back is one band's lines, each run once.
    @Test func aWideBandIsReadInTilesAndMergedBack() throws {
        let image = try Self.band(width: 5120)
        var widths: [Int] = []
        var heights: [Int] = []
        let lines = try ScreenTextRecogniser.recognise(image) { tile in
            widths.append(tile.width)
            heights.append(tile.height)
            // One run in the middle of every tile.
            let box = CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.2)
            return [RecognisedLine(
                text: "t\(widths.count)", box: box,
                runs: [RecognisedRun(text: "t\(widths.count)", utf16Offset: 0, box: box)], confidence: 1)]
        }
        #expect(widths == [2000, 2000, 2000, 2000])
        #expect(widths.allSatisfy { CGFloat($0) <= ScreenTextRecogniser.maximumTilePixels })
        #expect(heights.allSatisfy { $0 == 280 }, "tiles keep the band's height, so a row stays one row")
        #expect(lines.flatMap(\.runs).map(\.text) == ["t1", "t2", "t3", "t4"], "each tile's run once, in order")
    }

    /// A band that already fits is read in one call, exactly as before tiling: nothing changes for an ordinary window.
    @Test func aNarrowBandIsOneCallAndUntouched() throws {
        let image = try Self.band(width: 1600)
        var calls = 0
        let canned = RecognisedLine(
            text: "word", box: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.2),
            runs: [RecognisedRun(text: "word", utf16Offset: 0, box: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.2))],
            confidence: 0.9)
        let lines = try ScreenTextRecogniser.recognise(image) { tile in
            calls += 1
            #expect(tile.width == 1600)
            return [canned]
        }
        #expect(calls == 1)
        #expect(lines == [canned], "the lines are the reader's own, not rebuilt")
    }

    /// **A reader who has moved on stops being read for between tiles.** Vision cannot be interrupted, but the next
    /// tile need not be started.
    @Test func aCancelledReadStartsNoMoreTiles() async throws {
        let image = try Self.band(width: 5120)
        let calls = Counter()
        let task = Task {
            try ScreenTextRecogniser.recognise(image) { _ in
                calls.increment()
                withUnsafeCurrentTask { $0?.cancel() }
                return []
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(calls.value == 1, "tile \(calls.value) was read after the reader moved on")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
