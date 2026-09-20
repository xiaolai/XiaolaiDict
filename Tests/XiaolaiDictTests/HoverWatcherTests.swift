import AppKit
import CoreGraphics
import XiaolaiDictCore
import Testing

@testable import XiaolaiDict

/// The watcher's own decisions. The gate itself lives in `HoverPolicy` and the reading in
/// `HoverReader`, both tested where they live; what is left here is what only the watcher does —
/// read the modifiers, decide the pointer is at rest, and hand the reader a point in the space it
/// actually works in.
struct HoverWatcherTests {
    // MARK: - Modifiers

    @Test func holdingOptionIsReportedAsOption() {
        #expect(HoverWatcher.modifiers(of: [.option]) == [.option])
    }

    @Test func everyModifierHeldIsReported() {
        #expect(HoverWatcher.modifiers(of: [.option, .control, .command, .shift])
                == [.option, .control, .command, .shift])
    }

    @Test func holdingNothingIsAnEmptySet() {
        #expect(HoverWatcher.modifiers(of: []).isEmpty)
    }

    /// Caps lock and the function key are not hover modifiers, and reporting them as none of the
    /// four is what keeps the policy's set comparison exact.
    @Test func keysThatAreNotHoverModifiersAreIgnored() {
        #expect(HoverWatcher.modifiers(of: [.capsLock, .function, .numericPad]).isEmpty)
        #expect(HoverWatcher.modifiers(of: [.capsLock, .option]) == [.option])
    }

    // MARK: - Rest

    /// A pointer resting on a word twitches by a point or two. Treating that as movement restarts
    /// the dwell every time and the popup never fires at all.
    @Test func aPointerThatTwitchesIsStillAtRest() {
        #expect(!HoverWatcher.hasMoved(from: UpPoint(x: 100, y: 100), to: UpPoint(x: 101, y: 99)))
    }

    @Test func aPointerThatCrossesTheToleranceHasMoved() {
        #expect(HoverWatcher.hasMoved(from: UpPoint(x: 100, y: 100), to: UpPoint(x: 140, y: 100)))
        #expect(HoverWatcher.hasMoved(from: UpPoint(x: 100, y: 100), to: UpPoint(x: 100, y: 140)))
    }

    @Test func aPointerThatHasNotMovedAtAllIsAtRest() {
        #expect(!HoverWatcher.hasMoved(from: UpPoint(x: 100, y: 100), to: UpPoint(x: 100, y: 100)))
    }

    /// Diagonal drift must count as movement too — measuring one axis at a time would let a
    /// pointer slide along a diagonal without ever being seen to move.
    @Test func diagonalDriftCountsAsMovement() {
        #expect(HoverWatcher.hasMoved(from: UpPoint(x: 100, y: 100), to: UpPoint(x: 103, y: 103)))
    }

    // MARK: - Which display CGEvent measures from

    @Test func thePrimaryIsTheDisplayAtTheGlobalOrigin() {
        let secondary = ScreenMetrics(
            frame: UpRect(x: -1920, y: 0, width: 1920, height: 1080),
            visibleFrame: UpRect(x: -1920, y: 0, width: 1920, height: 1050))
        let primary = ScreenMetrics(
            frame: UpRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: UpRect(x: 0, y: 0, width: 2560, height: 1410))
        // Listed first, but it is not the one at the origin.
        #expect(HoverWatcher.primaryHeight(among: [secondary, primary]) == 1440)
    }

    /// No display reports the origin — an arrangement that should not happen, and a flip about
    /// zero would put every lookup at the top of the screen rather than failing.
    @Test func withNoDisplayAtTheOriginTheFirstOneIsUsed() {
        let odd = ScreenMetrics(
            frame: UpRect(x: 100, y: 100, width: 1920, height: 1080),
            visibleFrame: UpRect(x: 100, y: 100, width: 1920, height: 1050))
        #expect(HoverWatcher.primaryHeight(among: [odd]) == 1080)
    }

    @Test func withNoDisplaysAtAllThereIsNoHeight() {
        #expect(HoverWatcher.primaryHeight(among: []) == nil)
    }

    /// The whole point of the conversion: the pointer arrives y up and the reader works y down.
    @Test func aPointerNearTheTopOfTheScreenReadsNearZeroGoingDown() {
        let screens = [ScreenMetrics(
            frame: UpRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: UpRect(x: 0, y: 0, width: 2560, height: 1410))]
        let height = HoverWatcher.primaryHeight(among: screens)!
        #expect(UpPoint(x: 800, y: 1400).flipped(aboutPrimaryHeight: height) == DownPoint(x: 800, y: 40))
    }
}
