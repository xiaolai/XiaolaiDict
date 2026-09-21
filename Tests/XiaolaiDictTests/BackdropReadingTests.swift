import Testing

@testable import XiaolaiDict

/// How the drawer's report decides whether the drawer lets what is behind it through.
///
/// The drawer was meant to be glass, and nothing ever measured whether it was: the report checked
/// that the window was on screen and docked, and a flat grey panel passes both. The measurement is
/// to put black and then white directly behind it and see how much of it changes. These tests pin
/// the arithmetic that turns two captures into that answer, so a real reading can be trusted.
struct BackdropReadingTests {
    /// A drawer that shows nothing of what is behind it reads identically over black and white.
    @Test func anOpaqueDrawerDoesNotShowThrough() {
        let flat = [UInt8](repeating: 133, count: 1000)
        let reading = HistoryReport.BackdropReading(black: flat, white: flat)
        #expect(reading.changedFraction == 0)
        #expect(!reading.showsThrough)
    }

    @Test func glassThatChangesEverywhereShowsThrough() {
        let reading = HistoryReport.BackdropReading(
            black: [UInt8](repeating: 60, count: 1000), white: [UInt8](repeating: 200, count: 1000))
        #expect(reading.changedFraction == 1)
        #expect(reading.showsThrough)
    }

    /// **Opaque cards cover most of a busy drawer**, and they read the same over any backdrop. So
    /// the answer cannot need the whole drawer to change — only the glass between and around the
    /// cards. A drawer that is 85% cards and 15% working glass still shows through.
    @Test func glassBetweenOpaqueCardsStillCounts() {
        var black = [UInt8](repeating: 255, count: 1000), white = black
        for i in 0..<150 { black[i] = 70; white[i] = 190 }
        #expect(HistoryReport.BackdropReading(black: black, white: white).showsThrough)
    }

    /// And a sliver that leaks — a transparent corner the inset did not quite exclude, sensor noise
    /// — is not glass. A handful of changed pixels must not pass a panel that is otherwise flat.
    @Test func aFewLeakingPixelsAreNotGlass() {
        var black = [UInt8](repeating: 133, count: 1000), white = black
        for i in 0..<20 { black[i] = 0; white[i] = 255 }
        #expect(!HistoryReport.BackdropReading(black: black, white: white).showsThrough)
    }

    /// Small differences — antialiasing, the compositor's dithering — are not a change.
    @Test func noiseIsNotAChange() {
        let black = [UInt8](repeating: 130, count: 1000)
        let white = [UInt8](repeating: 136, count: 1000)
        #expect(HistoryReport.BackdropReading(black: black, white: white).changedFraction == 0)
    }

    // MARK: - How dark the glass is over something dark

    /// **Over a dark window is where frosted and clear differ, so that is what is read** — and
    /// only from glass. Measured: frosted reads 133 over black, clear 71; a reader's terminal is
    /// the case that made frosted look broken. The glass pixels are exactly the ones that changed
    /// between the two backdrops, because cards do not change, so the reading is the same however
    /// full the drawer is.
    @Test func itReadsTheGlassOverBlackAndIgnoresTheCards() {
        // 70% glass that reads 71 over black and 190 over white; 30% opaque white cards.
        var black = [UInt8](repeating: 255, count: 1000), white = black
        for i in 0..<700 { black[i] = 71; white[i] = 190 }
        let reading = HistoryReport.BackdropReading(black: black, white: white)
        #expect(reading.glassOverBlack == 71, "the white cards leaked into the glass reading")
    }

    /// A drawer mostly covered by cards still gives the glass its own value, not the cards'.
    @Test func aDrawerFullOfCardsStillReadsItsGlass() {
        var black = [UInt8](repeating: 255, count: 1000), white = black
        for i in 0..<100 { black[i] = 133; white[i] = 240 }
        #expect(HistoryReport.BackdropReading(black: black, white: white).glassOverBlack == 133)
    }

    /// Nothing changed means there is no glass to read — not a reading of zero.
    @Test func withNoGlassThereIsNoReading() {
        let flat = [UInt8](repeating: 133, count: 1000)
        #expect(HistoryReport.BackdropReading(black: flat, white: flat).glassOverBlack == nil)
    }
}
