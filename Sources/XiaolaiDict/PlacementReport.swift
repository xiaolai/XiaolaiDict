import AppKit
import Capture
import CaptureModel
import MacCapture
import SwiftUI
import Synchronization
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

    /// The rectangle `main.swift` was given, y down. Set once before the scene starts.
    private nonisolated static let word = Mutex<CGRect?>(nil)

    nonisolated static func aim(at rect: CGRect) { word.withLock { $0 = rect } }

    static func run(in app: XiaolaiDictApp) async -> CommandStatus {
        guard await WindowActions.shared.ready() else {
            _ = Instrument.write(["problem": "the window actions never arrived, so nothing could open"])
            return .failure
        }
        guard let given = word.withLock({ $0 }) else {
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
        var settled = first
        var since = ContinuousClock.now
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard let now = listedFrame(of: window) else { continue }
            if now != settled { settled = now; since = .now } else if ContinuousClock.now - since >= steady { break }
        }
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

    /// The window's frame as the compositor lists it — global, y down. Nil while it is not listed.
    private static func listedFrame(of window: NSWindow) -> CGRect? {
        let listed = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        guard let entry = listed.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.windowNumber }),
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    private static func box(_ rect: CGRect) -> [String: Double] {
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
