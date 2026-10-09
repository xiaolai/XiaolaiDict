import AppKit
import Capture
import CaptureModel
import MacCapture
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
        defer { Task { await PanelReport.removeLookups(after: before, in: app) } }

        app.lookUpHovered(selection, at: pointer, protecting: protected)
        guard await Instrument.settle(until: PanelReport.appearance, {
            Instrument.isOnScreen(app.panelController.window)
        }), let window = app.panelController.window, let first = listedFrame(of: window) else {
            _ = Instrument.write(["appeared": false, "problem": "the lookup panel was never listed by the compositor"])
            return .failure
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
        let report: [String: Any] = [
            "appeared": true,
            "word": box(given),
            "initial": box(first), "settled": box(settled),
            "grew": settled.height > first.height + slack,
            "coversWordInitially": first.intersects(given), "coversWordSettled": settled.intersects(given),
            "onScreenSettled": screenDown.insetBy(dx: -slack, dy: -slack)
                .contains(settled),
            "side": settled.minY >= given.maxY ? "below" : (settled.maxY <= given.minY ? "above" : "over"),
        ]
        app.panelController.close()
        guard Instrument.write(report) else { return .internalError }
        return (first.intersects(given) || settled.intersects(given)) ? .failure : .success
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
