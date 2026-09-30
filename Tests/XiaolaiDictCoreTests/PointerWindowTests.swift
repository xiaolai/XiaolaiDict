import CoreGraphics
import Foundation
import Testing
@testable import XiaolaiDictCore

/// Whose window is under the pointer, which the hover path has to know **before** it asks
/// Accessibility anything — see `PointerWindow`'s own note and the 2026-09-25 crash report.
struct PointerWindowTests {
    private func window(_ pid: Int32, _ rect: CGRect) -> ListedWindow {
        ListedWindow(pid: pid, bounds: rect)
    }

    @Test func theFrontmostWindowContainingThePointOwnsIt() {
        let point = CGPoint(x: 500, y: 400)
        let windows = [
            window(11, CGRect(x: 400, y: 300, width: 300, height: 300)),
            window(22, CGRect(x: 0, y: 0, width: 1_400, height: 900)),
        ]
        #expect(PointerWindow.owner(at: point, in: windows) == 11)
    }

    /// The order is the answer: the same two windows the other way round give the other owner.
    /// Without this the test above would pass on a rule that simply searched the whole list.
    @Test func aWindowBehindAnotherDoesNotOwnThePoint() {
        let point = CGPoint(x: 500, y: 400)
        let windows = [
            window(22, CGRect(x: 0, y: 0, width: 1_400, height: 900)),
            window(11, CGRect(x: 400, y: 300, width: 300, height: 300)),
        ]
        #expect(PointerWindow.owner(at: point, in: windows) == 22)
    }

    @Test func aWindowThatDoesNotHoldThePointIsSkipped() {
        let point = CGPoint(x: 50, y: 50)
        let windows = [
            window(11, CGRect(x: 400, y: 300, width: 300, height: 300)),
            window(22, CGRect(x: 0, y: 0, width: 100, height: 100)),
        ]
        #expect(PointerWindow.owner(at: point, in: windows) == 22)
    }

    /// Nil, not a pid: the pointer over the desktop is owned by nobody, and answering with the first
    /// window in the list would make every such hover look like it was over that app.
    @Test func noWindowUnderThePointIsNobodysWindow() {
        #expect(PointerWindow.owner(at: CGPoint(x: -9_000, y: -9_000), in: [
            window(11, CGRect(x: 0, y: 0, width: 100, height: 100)),
        ]) == nil)
    }

    @Test func anEmptyListOwnsNothing() {
        #expect(PointerWindow.owner(at: .zero, in: []) == nil)
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
            ListedWindow(pid: 11, bounds: CGRect(x: 10, y: 20, width: 30, height: 40)),
            ListedWindow(pid: 22, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
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
