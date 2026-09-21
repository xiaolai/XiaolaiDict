import CoreGraphics
import XiaolaiDictCore
import Testing

@testable import XiaolaiDict

/// **What the backdrop instrument reads: the drawer, and nothing around it.**
///
/// The drawer's window is the drawer grown by `DrawerLayout.shadowMargin` for its shadow to land
/// in, and that margin is transparent — it shows the backdrop whether or not the glass works. The
/// capture was the window inset by 24 points, which kept 24 of the margin's 48: on a 380-point
/// drawer, 6.3% of the region, over the 5% the reading needs to call a drawer glass. So an opaque
/// drawer would have passed.
@MainActor struct BackdropRegionTests {
    private let screen = ScreenMetrics(
        frame: UpRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: UpRect(x: 0, y: 0, width: 2560, height: 1410))

    private func content(of geometry: DrawerGeometry) -> CGRect {
        let window = geometry.windowRect.cg
        return CGRect(
            x: window.minX + geometry.contentOrigin.x,
            y: window.maxY - geometry.contentOrigin.y - geometry.contentSize.height,
            width: geometry.contentSize.width, height: geometry.contentSize.height)
    }

    @Test(arguments: [DrawerEdge.right, .left, .top, .bottom], [CGFloat(0), 12])
    func theRegionIsInsideTheDrawer(edge: DrawerEdge, inset: CGFloat) {
        let geometry = DrawerGeometry.make(DrawerLayout(thickness: 380, edge: edge, inset: inset), on: screen)
        let region = HistoryReport.glassRegion(window: geometry.windowRect.cg, geometry: geometry)
        let drawer = content(of: geometry)
        #expect(drawer.contains(region), "the region \(region) reaches outside the drawer \(drawer)")
        #expect(region.width > 0 && region.height > 0)
    }

    /// The defect, pinned: the old crop reached into the shadow margin on the drawer's open side.
    @Test func theOldCropReachedIntoTheShadowMargin() {
        let geometry = DrawerGeometry.make(DrawerLayout(thickness: 380, edge: .right), on: screen)
        let old = geometry.windowRect.cg.insetBy(dx: 24, dy: 24)
        #expect(!content(of: geometry).contains(old))
    }

    /// The pixel arithmetic, apart from the screen it usually reads: black is 0, white 255, and a
    /// saturated red carries its whole channel spread as colour.
    @Test func aCaptureIsReadPixelForPixel() throws {
        var pixels: [UInt8] = [0, 0, 0, 255, 255, 255, 255, 255, 255, 0, 0, 255]
        let context = try #require(CGContext(
            data: &pixels, width: 3, height: 1, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let capture = try #require(HistoryReport.Capture(image: image))
        #expect(capture.luminance.count == 3)
        #expect(capture.luminance[0] == 0)
        #expect(capture.luminance[1] == 255)
        let expectedColour: Double = 255.0 / 3.0
        #expect(abs(capture.colour - expectedColour) < 1)
    }
}
