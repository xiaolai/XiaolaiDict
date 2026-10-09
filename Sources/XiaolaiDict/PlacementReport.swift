import AppKit
import Capture
import CaptureModel
import MacCapture
import SwiftUI
import Synchronization
import XiaolaiDictBase
import XiaolaiDictUI

/// **Where the lookup panel goes for a word at a known rectangle, and whether it ever covers it** — the instrument
/// for plan-card-refinements WI-2.
///
/// The word's rectangle is given, y down, as Accessibility gives it: the `hover` E2E stage reads it twice, through
/// `--read-point` (the reader's own dialects) and through its own helper, and hands it here. The panel is filled by
/// `LookupRunner` through the hover door, protecting that rectangle, and its frame is read **from the compositor**
/// at first listing and again once the content has stopped growing — the entry arriving is the growth the protection
/// has to survive. Both frames are reported in the same y-down space as the word, with whether each intersects it.
@MainActor
enum PlacementReport {
    /// The word this instrument looks up, and its sentence — `PanelReport`'s, so the card grows as a real one does.
    static let term = PanelReport.term
    static let sentence = PanelReport.sentence
    /// How long the window must hold one frame to count as settled, and the longest it is given.
    static let steady: Duration = .seconds(1)
    static let budget: Duration = .seconds(45)
    /// A point of rounding between the compositor's frame and the screen's, as the window fit allows.
    static let slack: CGFloat = 1

    /// The rectangle `main.swift` was given, y down, and what to do with the card: keep a PNG of it, drag it. Set once
    /// before the scene starts.
    private nonisolated static let word = Mutex<(rect: CGRect, capture: String?, drag: PlacementDrag?)?>(nil)

    nonisolated static func aim(at rect: CGRect, capture: String? = nil, drag: PlacementDrag? = nil) {
        word.withLock { $0 = (rect, capture, drag) }
    }

    static func run(in app: XiaolaiDictApp) async -> CommandStatus {
        guard await WindowActions.shared.ready() else {
            _ = Instrument.write(["problem": "the window actions never arrived, so nothing could open"])
            return .failure
        }
        guard let (given, capture, drag) = word.withLock({ $0 }) else {
            _ = Instrument.write(["problem": "no word rectangle was given"])
            return .usage
        }
        guard let primary = NSScreen.screens.first(where: { $0.frame.contains(NSPoint.zero) }) ?? NSScreen.screens.first else {
            _ = Instrument.write(["problem": "no display to measure from"])
            return .failure
        }
        let height = primary.frame.height
        let read = DownRect(given)
        let protected = WordBounds(rect: read.flipped(aboutPrimaryHeight: height), quality: .exact)
        let pointer = DownPoint(x: given.midX, y: given.midY).flipped(aboutPrimaryHeight: height)
        let range = (sentence as NSString).range(of: term)
        let selection = Selection(
            text: term, sentence: sentence, rangeInSentence: range.location == NSNotFound ? nil : range,
            quality: .accessibility(.accessibilityTextRange, context: .complete),
            place: ReadingPlace(bundleID: "com.apple.TextEdit", name: "TextEdit"))

        if let drag {
            let report = await dragged(by: drag, word: given, protecting: protected, at: pointer, selection: selection,
                                       in: app)
            app.panelController.close()
            guard Instrument.write(report) else { return .internalError }
            return report["problem"] == nil ? .success : .failure
        }

        // **Leaves the reader's ledger as it found it** — the same discipline as `PanelReport`.
        let before = await PanelReport.newestLookup(in: app)

        app.lookUpHovered(selection, at: pointer, protecting: protected)
        guard await Instrument.settle(until: PanelReport.appearance, {
            Instrument.isOnScreen(app.panelController.window)
        }), let window = app.panelController.window, let first = listedFrame(of: window) else {
            _ = Instrument.write(["appeared": false, "problem": "the lookup panel was never listed by the compositor"])
            return await PanelReport.leaving(.failure, after: before, in: app)
        }
        // Settled: the same compositor frame for `steady`, within the budget.
        let settled = await steadyFrame(of: window) ?? first
        let visible = (window.screen ?? primary).visibleFrame
        let screenDown = UpRect(visible).flipped(aboutPrimaryHeight: height).cg
        var report: [String: Any] = [
            "appeared": true,
            "word": box(given),
            "initial": box(first), "settled": box(settled),
            "grew": settled.height > first.height + slack,
            "coversWordInitially": first.intersects(given), "coversWordSettled": settled.intersects(given),
            "onScreenSettled": screenDown.insetBy(dx: -slack, dy: -slack)
                .contains(settled),
            "side": settled.minY >= given.maxY ? "below" : (settled.maxY <= given.minY ? "above" : "over"),
            "screen": box(screenDown),
        ]
        // **The card on its word** (the owner's decision of 2026-10-09): where the card's middle is across, from the
        // compositor's frame and the room the card keeps for its shadows; where its tail's tip is; and what a real click
        // on the tail, and one in the transparent strip beside it, reach.
        let chrome = CardChrome(textSize: app.panelController.textSize())
        let tail = app.panelController.model.tail
        let insets = chrome.insets(tail: tail)
        let cardLeft = settled.minX + insets.leading
        let cardWidth = settled.width - insets.leading - insets.trailing
        report["cardMidX"] = cardLeft + cardWidth / 2
        // **The card on its word, kept for a person to look at** (D3, 2026-10-10: whether cutting the faint lower shadow
        // under a card above its word leaves a conspicuous straight edge, and whether the tail's outline is whole) — before
        // the clicks below, which close it. The window and the word with a margin round them, as composited.
        if let capture {
            let region = settled.union(given).insetBy(dx: -Self.captureMargin, dy: -Self.captureMargin)
            let kept = await Self.capture(region, on: window.screen ?? primary, primaryHeight: height, to: capture,
                                          window: settled)
            report["capture"] = kept.problem ?? capture
            for (key, step) in [("bottomEdgeStep", kept.steps.bottom), ("leftEdgeStep", kept.steps.left),
                                ("rightEdgeStep", kept.steps.right)] {
                if let step { report[key] = step }
            }
            report["appearance"] = NSApplication.shared.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
            report["textSize"] = app.panelController.textSize().rawValue
        }
        if let tail, let tip = tail.tip {
            // y down: a tail on the card's top edge points up, at the word above it.
            let tipY = tail.edge == .top ? settled.minY + insets.top : settled.maxY - insets.bottom
            let inward: CGFloat = tail.edge == .top ? 1 : -1
            report["tail"] = ["edge": tail.edge == .top ? "top" : "bottom", "x": cardLeft + tip, "y": tipY]
            // On the tail, halfway along it; beside it, a quarter of its length in, as far across as the card allows.
            let onTail = CGPoint(x: cardLeft + tip, y: tipY + inward * chrome.tailLength / 2)
            let besideX = tip > cardWidth / 2 ? cardLeft + chrome.cornerRadius : cardLeft + cardWidth - chrome.cornerRadius
            let beside = CGPoint(x: besideX, y: tipY + inward * chrome.tailLength / 4)
            report["clickOnTheTail"] = await ClickProbe.reach(at: onTail)
            report["openAfterTheClickOnTheTail"] = window.isVisible
            report["clickBesideTheTail"] = await ClickProbe.reach(at: beside)
            try? await Task.sleep(for: .milliseconds(300))
            report["openAfterTheClickBeside"] = window.isVisible
        }
        app.panelController.close()
        guard Instrument.write(report) else { return await PanelReport.leaving(.internalError, after: before, in: app) }
        return await PanelReport.leaving((first.intersects(given) || settled.intersects(given)) ? .failure : .success,
                                         after: before, in: app)
    }

    /// The room kept round the card and its word in a capture, so the shadow's fall and what lies behind both show.
    static let captureMargin: CGFloat = 24

    /// Writes the screen over `region` (global, y down) as a PNG at `path` — `problem` nil where it was written — and
    /// measures **the step at the window's bottom, left and right edges** (`window`, y down): how many grey levels the
    /// screen changes by from the pixel just inside the window to the one just outside, the median of four places along
    /// each edge, clear of the corners and of a tail at the middle. A shadow cut by the window's edge is a step; one that
    /// has faded out is none.
    static func capture(
        _ region: CGRect, on screen: NSScreen, primaryHeight: CGFloat, to path: String, window: CGRect
    ) async -> (problem: String?, steps: (bottom: Double?, left: Double?, right: Double?)) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return ("the display has no number", (nil, nil, nil))
        }
        // Display-local and top-left, which is what ScreenCaptureKit's `sourceRect` means.
        let top = primaryHeight - screen.frame.maxY
        let source = CGRect(x: region.minX - screen.frame.minX, y: region.minY - top, width: region.width, height: region.height)
        let pixels = CGSize(width: region.width * screen.backingScaleFactor, height: region.height * screen.backingScaleFactor)
        do {
            // The instrument's own deadline, not the product's: the first capture after boot is slow.
            let image = try await withDeadline(.seconds(30)) {
                try await Instrument.screenImage(of: source, size: pixels, onDisplay: number.uint32Value)
            }
            let scale = screen.backingScaleFactor
            let bitmap = NSBitmapImageRep(cgImage: image)
            func pixel(_ x: CGFloat, _ y: CGFloat) -> (x: Int, y: Int) {
                (Int(((x - region.minX) * scale).rounded()), Int(((y - region.minY) * scale).rounded()))
            }
            func grey(_ at: (x: Int, y: Int)) -> Double? {
                guard at.x >= 0, at.y >= 0, at.x < bitmap.pixelsWide, at.y < bitmap.pixelsHigh,
                      let colour = bitmap.colorAt(x: at.x, y: at.y)?.usingColorSpace(.sRGB) else { return nil }
                return (colour.redComponent + colour.greenComponent + colour.blueComponent) / 3 * 255
            }
            func median(_ steps: [Double]) -> Double? {
                let sorted = steps.sorted()
                return sorted.isEmpty ? nil : (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
            }
            func step(_ inside: (x: Int, y: Int), _ outside: (x: Int, y: Int)) -> Double? {
                guard let inside = grey(inside), let outside = grey(outside) else { return nil }
                return abs(inside - outside)
            }
            let bottom = median(Self.edgeSamples.compactMap { fraction in
                let edge = pixel(window.minX + window.width * fraction, window.maxY)
                return step((edge.x, edge.y - 1), edge)
            })
            let left = median(Self.edgeSamples.compactMap { fraction in
                let edge = pixel(window.minX, window.minY + window.height * fraction)
                return step(edge, (edge.x - 1, edge.y))
            })
            let right = median(Self.edgeSamples.compactMap { fraction in
                let edge = pixel(window.maxX, window.minY + window.height * fraction)
                return step((edge.x - 1, edge.y), edge)
            })
            return (Instrument.keep(image, as: URL(fileURLWithPath: path)), (bottom, left, right))
        } catch {
            return ("\(error)", (nil, nil, nil))
        }
    }

    /// Where along an edge it is read: clear of the corners, and of a tail at the middle.
    static let edgeSamples: [CGFloat] = [0.2, 0.35, 0.65, 0.8]

    /// The window's frame as the compositor lists it — global, y down. Nil while it is not listed.
    static func listedFrame(of window: NSWindow) -> CGRect? {
        let listed = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        guard let entry = listed.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber }),
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    static func box(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
}

/// **A real click, and who received it** — this app, or another one beneath it — so the placement report can say
/// whether the window answers to its tail and lets a click beside it through to the app below.
@MainActor
enum ClickProbe {
    /// `panel` where this app received the press, `elsewhere` where another app did, `nobody` where neither was told
    /// within a second, `notPosted` where the event could not be made. `point` is y down, as a `CGEvent` is.
    static func reach(at point: CGPoint) async -> String {
        final class Heard { var by: String? }
        let heard = Heard()
        let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            heard.by = heard.by ?? "panel"
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            MainActor.assumeIsolated { heard.by = heard.by ?? "elsewhere" }
        }
        defer {
            if let local { NSEvent.removeMonitor(local) }
            if let global { NSEvent.removeMonitor(global) }
        }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point,
                                 mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point,
                               mouseButton: .left)
        else { return "notPosted" }
        // Stated, never inherited: a click with no modifiers.
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        let deadline = ContinuousClock.now + .seconds(1)
        while heard.by == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return heard.by ?? "nobody"
    }
}
