import CoreGraphics
import Foundation
import Testing
@testable import Capture

/// Whose window is under the pointer, which the hover path has to know **before** it asks
/// Accessibility anything — see `PointerWindow`'s own note and the 2026-09-25 crash report.
struct PointerWindowTests {
    private func window(_ pid: Int32, _ rect: CGRect) -> ListedWindow {
        ListedWindow(pid: pid, bounds: rect)
    }

    /// **Any window of ours at the point, at any depth, refuses the hover** — the rule `owner`'s
    /// topmost-window answer was replaced by, because the topmost window is not proof of where
    /// Accessibility's hit test lands.
    @Test func ourWindowAnywhereUnderThePointCounts() {
        let point = CGPoint(x: 500, y: 400)
        let windows = [
            window(22, CGRect(x: 0, y: 0, width: 1_400, height: 900)),
            window(99, CGRect(x: 400, y: 300, width: 300, height: 300)),
        ]
        #expect(PointerWindow.ours(at: point, in: windows, ours: 99))
    }

    /// Ours elsewhere on the screen does not count: the control for the test above.
    @Test func ourWindowElsewhereDoesNotCount() {
        let windows = [
            window(99, CGRect(x: 400, y: 300, width: 300, height: 300)),
            window(22, CGRect(x: 0, y: 0, width: 100, height: 100)),
        ]
        #expect(!PointerWindow.ours(at: CGPoint(x: 50, y: 50), in: windows, ours: 99))
    }

    /// Our own window counts even while invisible — one fading in is still serviced in-process.
    @Test func ourInvisibleWindowStillCounts() {
        let fading = ListedWindow(pid: 99, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), alpha: 0)
        #expect(PointerWindow.ours(at: CGPoint(x: 10, y: 10), in: [fading], ours: 99))
    }

    @Test func anEmptyListHasNothingOfOurs() {
        #expect(!PointerWindow.ours(at: .zero, in: [], ours: 99))
    }

    /// **The panel is at `.floating`, so a level filter would miss exactly the window this is for.**
    /// The recogniser's own search keeps `kCGWindowLayer == 0` on purpose; copying that line here
    /// would restore the crash while leaving every other test green.
    @Test func aWindowAboveTheOrdinaryLevelIsStillListed() {
        let listed = PointerWindow.listed([
            [
                kCGWindowOwnerPID as String: Int32(11),
                kCGWindowLayer as String: 3,
                kCGWindowBounds as String: CGRect(x: 10, y: 20, width: 30, height: 40)
                    .dictionaryRepresentation as NSDictionary,
            ],
            [
                kCGWindowOwnerPID as String: Int32(22),
                kCGWindowLayer as String: 0,
                kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 800, height: 600)
                    .dictionaryRepresentation as NSDictionary,
            ],
        ])
        #expect(listed == [
            ListedWindow(pid: 11, bounds: CGRect(x: 10, y: 20, width: 30, height: 40), layer: 3),
            ListedWindow(pid: 22, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 0),
        ])
    }

    /// A window the compositor described incompletely is dropped, not placed at the origin — a rect of
    /// zeros would claim every hover at the top-left corner of the screen.
    @Test func aWindowWithoutAPlaceOrAnOwnerIsDropped() {
        #expect(PointerWindow.listed([
            [kCGWindowOwnerPID as String: Int32(11)],
            [kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 10, height: 10)
                .dictionaryRepresentation as NSDictionary],
            [:],
        ]).isEmpty)
    }
}
