import AppKit
import Foundation
import SwiftUI
import Testing

@testable import XiaolaiDictUI

/// **Every icon-only control is a named, hittable target — enforced structurally, not by convention.**
///
/// Measured 2026-09-25, before this: the card's and the drawer's icon buttons drew a bare
/// `Image(systemName:)` inside a `.plain` button with no padding and no `contentShape`, so the
/// clickable region was the glyph's own box — **13 to 19 pt**, six of them 6 pt apart, against
/// macOS's 28 pt default control size. And seven of the eight carried no accessibility name at all:
/// `.help()` sets a *hint*, not a name, so VoiceOver had the symbol and nothing else.
///
/// The fix is one component rather than a rule everyone remembers. `IconButton` supplies the name
/// and the floor together, and the scan below is what stops a call site from going around it —
/// because "a rule that quietly stops covering new code is worse than no rule, since it still reads
/// as one".
struct IconButtonTests {
    private var viewLayer: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/XiaolaiDictUI")
    }

    /// The whole view layer, comments stripped: these files explain themselves at length and a
    /// scanner that cannot tell a declaration from an explanation is satisfied by a call site written
    /// out inside a comment.
    private func sources() throws -> [(name: String, text: String)] {
        let files = try FileManager.default
            .contentsOfDirectory(at: viewLayer, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        // A scan of nothing passes. The count is named so an empty directory fails loudly.
        #expect(files.count >= 6, "only \(files.count) view files were found to scan")
        return try files.map { file in
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.isEmpty, "\(file.lastPathComponent) is empty")
            return (file.lastPathComponent, text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n"))
        }
    }

    /// **The floor is a floor, not a size.** A pointer target does not grow with the reader's text, so
    /// it lives in `Token` — but the glyph inside it does, so it is applied as a *minimum* and a
    /// larger glyph at `TextSize.large` still wins. Filing it in `Scale` would have been a claim that
    /// a reader asking for bigger text is asking for a bigger mouse.
    @Test func theTargetFloorIsAtLeastThePlatformDefault() {
        #expect(Token.Target.minimum >= 28, "macOS's default control size is 28 pt")
    }

    /// And the glyph is never clipped by it: at the largest text size the icon still fits.
    @Test func theFloorNeverClipsTheGlyphItHolds() {
        let largest = Scale(.large)
        #expect(Token.Target.minimum >= largest.text.body,
                "the target is smaller than the glyph it has to hold at TextSize.large")
    }

    /// **No view builds an icon button by hand.** This is the check that keeps the two properties —
    /// a name and a 28 pt region — from being reintroduced one call site at a time.
    ///
    /// It looks for a `Button` whose label is only an `Image(systemName:)`, in any of the shapes that
    /// spelling takes: a trailing-closure label, a `label:` argument, and one with modifiers hung off
    /// the image. `IconButton` is the way past it.
    @Test func noViewBuildsABareIconButton() throws {
        var offenders: [String] = []
        for (name, text) in try sources() where name != "IconButton.swift" {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, line) in lines.enumerated() {
                // The label of a button, wherever it is written: the image and the `Button` may be on
                // different lines, so a window of the next few lines is what is searched.
                guard line.contains("Button") else { continue }
                let window = lines[offset..<min(offset + 6, lines.count)].joined(separator: " ")
                guard window.contains("Image(systemName:") else { continue }
                // A `Label` carries its own name, which is the property this is about.
                guard !window.contains("Label(") else { continue }
                // **And a label with words in it is not icon-only.** The dictionary list's rows are a
                // symbol *and* their text, which names them — flagging those would be the scan
                // demanding a component for a control that is not what the component is for.
                //
                // The honest limit of a source scan, stated rather than glossed: the window is a few
                // lines, so a `Text(` belonging to the *next* control could excuse this one. What
                // closes that gap is not a cleverer regex but `IconButton` itself — the scan's job is
                // to make going around the component visible, and the component's job is to be the
                // easiest path.
                guard !window.contains("Text(") else { continue }
                offenders.append("\(name):\(offset + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(
            offenders.isEmpty,
            """
            these buttons draw a bare symbol, so they have no accessibility name and no minimum \
            target — use IconButton:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// **It draws.** A component that renders nothing satisfies every scan above: no bare symbol, a
    /// `Label` in its source, the token referenced. This is the pixel that says it is a control and
    /// not an empty view — and it is checked disabled as well as enabled, because "disabled" must mean
    /// faint rather than absent.
    @Test @MainActor func anIconButtonActuallyDraws() throws {
        func ink(_ view: some View) throws -> Int {
            let renderer = ImageRenderer(content: view.frame(width: 60, height: 60).background(.white))
            renderer.scale = 2
            let image = try #require(renderer.cgImage, "the button did not rasterise")
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(CGContext(
                data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return stride(from: 0, to: pixels.count, by: 4).reduce(into: 0) { count, index in
                if Int(pixels[index]) < 230 { count += 1 }
            }
        }
        let enabled = try ink(IconButton(title: "Keep this sense as a note", symbol: "pin") {})
        #expect(enabled > 50, "an enabled icon button drew \(enabled) ink pixels")
        let disabled = try ink(
            IconButton(title: "Keep this sense as a note", symbol: "pin", isEnabled: false) {})
        #expect(disabled > 0, "a disabled icon button vanished instead of dimming")
    }

    /// **And the component actually supplies both.** The scan above only proves nobody went around
    /// `IconButton`; if `IconButton` itself stopped naming or sizing, every call site would be
    /// compliant and every button would be wrong.
    @Test func theComponentSuppliesTheNameAndTheFloor() throws {
        let source = try String(
            contentsOf: viewLayer.appending(path: "IconButton.swift"), encoding: .utf8)
        #expect(source.contains("Label("), "IconButton draws no Label, so its buttons have no name")
        #expect(source.contains("Token.Target.minimum"), "IconButton does not apply the target floor")
        #expect(source.contains("contentShape("), "IconButton's frame is not hittable, only visible")
    }
}
