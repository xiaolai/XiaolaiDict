import CoreGraphics
import Foundation
import Testing
@testable import Capture

/// A system process's whole-display window draws next to nothing, and an instrument asking which window the compositor
/// draws in front at a point must not take it for something drawn. Measured on the Mac mini, 2026-10-12: the Dock's
/// window was fully transparent in all 2,073,600 pixels, and Notification Center's drew 71,748 of them (two banners in
/// a corner); a click through either reached the window below.
struct SystemOverlaySurfaceTests {
    private let display = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    private var dockLevel: Int { Int(CGWindowLevelForKey(.dockWindow)) }

    @Test func theDockAndNotificationCenterWindowsCoveringADisplayAreOverlaySurfaces() {
        #expect(SystemOverlaySurface.isOne(owner: "Dock", layer: dockLevel, bounds: display, displays: [display]))
        #expect(SystemOverlaySurface.isOne(owner: "Notification Center", layer: dockLevel + 1, bounds: display,
                                           displays: [display]))
    }

    /// The Dock's real tiles are a window at the same level, and they are drawn: not a surface to look through.
    @Test func theDockBarItselfIsDrawn() {
        let bar = CGRect(x: 400, y: 1_000, width: 1_100, height: 80)
        #expect(!SystemOverlaySurface.isOne(owner: "Dock", layer: dockLevel, bounds: bar, displays: [display]))
    }

    /// A positive control for each condition: change one thing and it is not the surface.
    @Test func anotherOwnerAnOrdinaryLayerOrAnotherSizeIsNot() {
        #expect(!SystemOverlaySurface.isOne(owner: "Safari", layer: dockLevel, bounds: display, displays: [display]))
        #expect(!SystemOverlaySurface.isOne(owner: nil, layer: dockLevel, bounds: display, displays: [display]))
        // An app's full-screen window is at layer 0, and is drawn.
        #expect(!SystemOverlaySurface.isOne(owner: "Dock", layer: 0, bounds: display, displays: [display]))
        let small = CGRect(x: 0, y: 0, width: 1_919, height: 1_080)
        #expect(!SystemOverlaySurface.isOne(owner: "Dock", layer: dockLevel, bounds: small, displays: [display]))
    }

    /// On a second display, the window that covers that display is the surface too.
    @Test func itMayCoverAnyOfSeveralDisplays() {
        let second = CGRect(x: 1_920, y: 0, width: 2_560, height: 1_440)
        #expect(SystemOverlaySurface.isOne(owner: "Dock", layer: dockLevel, bounds: second, displays: [display, second]))
    }
}
