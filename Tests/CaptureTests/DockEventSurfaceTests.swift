import CoreGraphics
import Foundation
import Testing
@testable import Capture

/// **The Dock's own full-display window draws nothing**, and an instrument asking which window the compositor draws in
/// front at a point must not take it for something drawn. Measured on the Mac mini, 2026-10-12: the Dock owned a
/// 1920 × 1080 window at the Dock's level, alpha 1 in the list, and every one of its 2,073,600 pixels was fully
/// transparent; a click through it reached the window below. The `panel` stage named it in front of 24 pinned-note
/// controls it was not drawn over — and the other E2E Mac has none.
struct DockEventSurfaceTests {
    private let display = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)

    @Test func theDockWindowCoveringADisplayIsTheEventSurface() {
        #expect(DockEventSurface.isOne(owner: "Dock", layer: DockEventSurface.level, bounds: display, displays: [display]))
    }

    /// The Dock's real tiles are a window at the same level, and they are drawn: not a surface to look through.
    @Test func theDockBarItselfIsDrawn() {
        let bar = CGRect(x: 400, y: 1_000, width: 1_100, height: 80)
        #expect(!DockEventSurface.isOne(owner: "Dock", layer: DockEventSurface.level, bounds: bar, displays: [display]))
    }

    /// A positive control for each condition: change one thing and it is not the surface.
    @Test func anotherOwnerAnotherLevelOrAnotherSizeIsNot() {
        #expect(!DockEventSurface.isOne(owner: "Safari", layer: DockEventSurface.level, bounds: display, displays: [display]))
        #expect(!DockEventSurface.isOne(owner: "Dock", layer: 0, bounds: display, displays: [display]))
        #expect(!DockEventSurface.isOne(owner: nil, layer: DockEventSurface.level, bounds: display, displays: [display]))
        let small = CGRect(x: 0, y: 0, width: 1_919, height: 1_080)
        #expect(!DockEventSurface.isOne(owner: "Dock", layer: DockEventSurface.level, bounds: small, displays: [display]))
    }

    /// On a second display, the window that covers that display is the surface too.
    @Test func itMayCoverAnyOfSeveralDisplays() {
        let second = CGRect(x: 1_920, y: 0, width: 2_560, height: 1_440)
        #expect(DockEventSurface.isOne(owner: "Dock", layer: DockEventSurface.level, bounds: second,
                                       displays: [display, second]))
    }
}
