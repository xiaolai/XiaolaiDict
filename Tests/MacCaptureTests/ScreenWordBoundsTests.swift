import ApplicationServices
import Capture
import CaptureModel
import DictionaryModel
import Foundation
@testable import MacCapture
import Testing

/// **A hover hands the panel the word's box where the dialect has one** (plan-card-refinements WI-2): the text-range
/// dialect asks for the token's own range, the bounds scan keeps the box it already asked for. A box the app answers
/// empty is no box.
struct ScreenWordBoundsTests {
    /// A text view of fixed-width glyphs: character i spans x 100+10i … 110+10i, y 200 … 220 (y down).
    private final class Glyphs: AccessibilityReading {
        let text: String
        /// Which dialect the fake speaks: the Cocoa text range, or only a value and per-range boxes (Chromium).
        let speaksTextRange: Bool
        /// Answers the token's own box empty, as some views do — every one-character glyph box stays valid, so the word
        /// is still read and only its box is missing.
        let emptyTokenBox: Bool

        init(_ text: String, speaksTextRange: Bool, emptyTokenBox: Bool = false) {
            self.text = text
            self.speaksTextRange = speaksTextRange
            self.emptyTokenBox = emptyTokenBox
        }

        func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
            switch name {
            case kAXNumberOfCharactersAttribute: speaksTextRange ? text.utf16.count as CFNumber : nil
            case kAXValueAttribute: text as CFString
            case kAXRoleAttribute: "AXTextArea" as CFString
            default: nil
            }
        }

        func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
            switch name {
            case kAXRangeForPositionParameterizedAttribute:
                guard speaksTextRange else { return nil }
                var point = CGPoint.zero
                // swiftlint:disable:next force_cast
                AXValueGetValue(argument as! AXValue, .cgPoint, &point)
                var range = CFRange(location: max(0, Int((point.x - 100) / 10)), length: 1)
                return AXValueCreate(.cfRange, &range)
            case kAXStringForRangeParameterizedAttribute:
                guard speaksTextRange else { return nil }
                let range = Self.range(argument)
                let units = Array(text.utf16)[range.location..<(range.location + range.length)]
                return String(decoding: units, as: UTF16.self) as CFString
            case kAXBoundsForRangeParameterizedAttribute:
                let range = Self.range(argument)
                var box = emptyTokenBox && range.length > 1 ? CGRect.zero
                    : CGRect(x: 100 + 10 * CGFloat(range.location), y: 200, width: 10 * CGFloat(range.length), height: 20)
                return AXValueCreate(.cgRect, &box)
            default:
                return nil
            }
        }

        private static func range(_ argument: CFTypeRef) -> CFRange {
            var range = CFRange()
            // swiftlint:disable:next force_cast
            AXValueGetValue(argument as! AXValue, .cfRange, &range)
            return range
        }
    }

    /// **An app that says its text is `Int.max` long, and that the pointer is at its last character** — what a broken or
    /// hostile app can answer. Nothing else.
    private final class Endless: AccessibilityReading {
        func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
            switch name {
            case kAXNumberOfCharactersAttribute: Int.max as CFNumber
            case kAXRoleAttribute: "AXTextArea" as CFString
            default: nil
            }
        }

        func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
            guard name == kAXRangeForPositionParameterizedAttribute else { return nil }
            var range = CFRange(location: .max - 1, length: 1)
            return AXValueCreate(.cfRange, &range)
        }
    }

    private let target = ScreenWordReader.Target(
        element: AXUIElementCreateApplication(pid_t(4_100_000)), appName: "Glyphs", bundleID: "glyphs")
    /// Over "cat" in "The cat sat." — characters 4…6, x 140…170.
    private let point = CGPoint(x: 155, y: 210)

    private func hit(_ ax: some AccessibilityReading) -> ScreenWordReader.Hit? {
        guard case .hit(let hit) = ScreenWordReader.read(at: point, in: target, with: ax) else { return nil }
        return hit
    }

    @Test func theTextRangeDialectAsksForTheTokensOwnBox() throws {
        let hit = try #require(hit(Glyphs("The cat sat.", speaksTextRange: true)))
        #expect(hit.word.word == "cat")
        #expect(hit.bounds == ReadBounds(rect: DownRect(x: 140, y: 200, width: 30, height: 20), quality: .exact))
    }

    @Test func theBoundsScanKeepsTheBoxItAlreadyAskedFor() throws {
        let hit = try #require(hit(Glyphs("The cat sat.", speaksTextRange: false)))
        #expect(hit.source == .accessibilityBoundsScan)
        #expect(hit.bounds == ReadBounds(rect: DownRect(x: 140, y: 200, width: 30, height: 20), quality: .exact))
    }

    /// **An index from another process is summed without trapping** (audit of 2026-10-10): the window of text around it
    /// was `index + 300`, past `Int.max` for a pointer at the last character of an `Int.max`-long text — a trap in the
    /// hover path, which ends the app. It reads nothing there, and returns.
    @Test func anIndexAtTheLargestLengthReadsNothingAndNeverTraps() {
        #expect(hit(Endless()) == nil)
    }

    /// An app answering the token's box empty reads its word and locates nothing — the pointer rule, not a box at the
    /// origin. **The word must be read** (audit of 2026-10-10): this test emptied every box, the glyphs' too, so nothing
    /// was read at all, and `hit?.bounds == nil` passed on no hit.
    @Test func anEmptyBoxLocatesNothing() throws {
        let hit = try #require(hit(Glyphs("The cat sat.", speaksTextRange: true, emptyTokenBox: true)),
                               "the word was not read, so its missing box says nothing")
        #expect(hit.word.word == "cat")
        #expect(hit.bounds == nil)
    }
}
