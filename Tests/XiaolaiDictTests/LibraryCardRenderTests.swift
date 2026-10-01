import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import XiaolaiDictUI

/// The real row initializer, without glass or scrolling that ImageRenderer cannot draw.
@MainActor
struct LibraryCardRenderTests {
    /// Marked where the ledger would mark it: the word's own range in the sentence, and nothing
    /// where the sentence does not hold it.
    private func row(excerpt: String = "They hold their place.", answer: String = "") -> LibraryPresentation.Row {
        let hold = (excerpt as NSString).range(of: "hold")
        return LibraryPresentation.Row(id: UUID(), word: "hold", excerpt: excerpt,
                                       marks: hold.location == NSNotFound ? [] : [hold],
                                       answer: answer, status: nil, due: nil)
    }

    private func render(_ row: LibraryPresentation.Row,
                        scheme: ColorScheme = .light) throws -> (CGImage, [UInt8]) {
        let renderer = ImageRenderer(content:
            LibraryRowView(row: row)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 360, alignment: .topLeading)
                .environment(\.scale, Scale.standard)
                .environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try #require(renderer.cgImage, "the actual Library row must render")
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Positive control: an empty/flat raster cannot establish any of the claims below.
        #expect(Set(stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }).count > 12,
                "visible word/sentence content must actually rasterise")
        return (image, pixels)
    }

    @Test func libraryRowsUseOpaqueCardSurface() throws {
        for scheme in [ColorScheme.light, .dark] {
            let (image, pixels) = try render(row(), scheme: scheme)
            let opaque = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] == 255 }.count
            #expect(Double(opaque) / Double(image.width * image.height) > 0.80,
                    "criterion 6: the row must carry an opaque card surface in \(scheme)")
        }
    }

    @Test func savedSentenceEmphasizesItsWord() throws {
        // Keep the title identical; only the sentence contains (or does not contain) the word.
        // No answer/reveal-link colour may stand in for emphasis on that word.
        let marked = try render(row())
        let unmarked = try render(row(excerpt: "They keep their place."))
        func colouredPixels(_ rendered: (CGImage, [UInt8])) -> Int {
            let (image, pixels) = rendered
            // The raster context has a bottom-left origin: the sentence occupies its lower half.
            return stride(from: 0, to: image.width * image.height / 2 * 4, by: 4).filter { i in
                let rgb = [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
                return pixels[i + 3] > 128 && rgb.max()! - rgb.min()! > 35
            }.count
        }
        #expect(colouredPixels(marked) > colouredPixels(unmarked) + 20,
                "criterion 6: the Saved sentence must emphasize its own word")
    }

    /// The row has no reveal of its own any more, so what this guards is that the answer it
    /// carries never reaches it: a long meaning and none draw the same card.
    @Test func theAnswerDoesNotChangeCardHeight() throws {
        let saved = row(answer: Array(repeating: "An intentionally long saved meaning.", count: 24).joined(separator: " "))
        let withAnswer = try render(saved)
        let without = try render(row())
        #expect(withAnswer.0.height == without.0.height,
                "criterion 4: full meanings belong in the inspector and must not resize the card")
    }
}
