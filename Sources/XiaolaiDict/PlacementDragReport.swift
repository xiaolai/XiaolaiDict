import AppKit
import ApplicationServices
import Capture
import CaptureModel
import DictionaryModel
import MacCapture
import SwiftUI
import XiaolaiDictCore
import XiaolaiDictUI

/// A move the reader makes with the card, in points — right and down, as a `CGEvent` moves.
struct PlacementDrag: Equatable, Sendable {
    let dx: Double
    let dy: Double
}

/// **A reader's drag lets go of the word** — `--placement-report … --drag DX DY` (plan-card-refinements D3, 2026-10-10).
///
/// A window drag cannot be driven in a test process: AppKit's move by the window's background reads the window server's
/// events for itself, and pulling events in a test ends the process (`KeyboardHarness`). So the drag is driven here, in
/// the bundle on the E2E Mac, with real events, on the real panel — in the order a lookup fills a card: shown waiting,
/// before the dictionaries have answered, and dragged by the reader then; its entry arriving afterwards, as the runner
/// puts it on the same presentation; and a disclosure opened on it, pressed as VoiceOver presses it. The frame is read
/// from the compositor after each, with the tail the card carries. Nothing is recorded in the ledger: the runner is not
/// asked, the panel is.
extension PlacementReport {
    /// What happened to the card through the drag, its entry and a disclosure — each frame global and y down.
    static func dragged(
        by drag: PlacementDrag, word given: CGRect, protecting word: WordBounds, at pointer: UpPoint, selection: Selection,
        in app: XiaolaiDictApp
    ) async -> [String: Any] {
        let controller = app.panelController
        let ticket = controller.newRequest()
        let lemma = Lemmatizer.lemma(of: selection.text, in: selection.sentence, at: selection.rangeInSentence)
        // The runner's first step: the card shown before the dictionaries are asked, waiting.
        var presentation = LookupPresentation(
            request: ticket.number, term: selection.text, lemma: lemma, source: selection.place.name,
            capture: selection.quality, sentence: selection.sentence)
        if let range = selection.rangeInSentence { presentation.termPlacement = .at(range) }
        guard controller.show(.lookup(presentation), near: pointer, protecting: word, for: ticket) else {
            return ["problem": "the lookup panel would not show"]
        }
        guard await Instrument.settle(until: PanelReport.appearance, { Instrument.isOnScreen(controller.window) }),
              let window = controller.window, let shown = await steadyFrame(of: window)
        else { return ["problem": "the lookup panel was never listed by the compositor"] }
        let chrome = CardChrome(textSize: controller.textSize())
        let tailShown = controller.model.tail
        var report: [String: Any] = [
            "word": box(given),
            "shown": box(shown), "tailShown": describe(tailShown), "anchoredShown": controller.anchor != nil,
        ]

        // The drag, from the card's middle — its paper, clear of the tail's strip and of any control on a waiting card.
        let from = CGPoint(x: shown.midX, y: shown.midY)
        report["dragFrom"] = ["x": from.x, "y": from.y]
        report["dragPosted"] = await Self.drag(from: from, by: CGVector(dx: drag.dx, dy: drag.dy))
        // Where the window is the moment the button comes up, and once it has stayed put: a jump at the release is the
        // difference between the two.
        report["released"] = listedFrame(of: window).map(box) ?? NSNull()
        guard let dragged = await steadyFrame(of: window) else { return report.merging(["problem": "lost after the drag"]) { $1 } }
        report["dragged"] = box(dragged)
        report["tailDragged"] = describe(controller.model.tail)
        report["anchoredDragged"] = controller.anchor != nil
        // The strip the tail occupied is kept, so the card's paper does not move inside its window.
        report["cardInsetsKept"] = chrome.insets(tail: tailShown) == chrome.insets(tail: controller.model.tail)

        // The runner's second step, later than the drag: the entry on the same presentation. It leads with the first
        // sense of an entry that marks them, so the other meanings start closed and opening them is a growth of its own.
        let outcome = try? await DictionaryClient().lookup(selection.text)
        presentation.outcome = outcome
        if case .entries(let found, _)? = outcome,
           let lead = found.first(where: { $0.senseKeyKind != .none && $0.senseCount > 1 }),
           let key = lead.senses.first?.key {
            let owner = PanelSelection.identity(of: lead)
            presentation.primaryEntry = owner
            presentation.sense = .chosen(key: key, by: .model)
            presentation.senseOwner = owner
        }
        controller.update(.lookup(presentation), for: ticket)
        guard let arrived = await steadyFrame(of: window) else { return report.merging(["problem": "lost after the entry"]) { $1 } }
        report["arrived"] = box(arrived)
        report["tailArrived"] = describe(controller.model.tail)

        // A disclosure, pressed through Accessibility in this process, on the main actor (ADR-0042).
        report["disclosure"] = Self.press(endingWith: "other meanings", inWindowTitled: window.title)
        guard let expanded = await steadyFrame(of: window) else {
            return report.merging(["problem": "lost after the disclosure"]) { $1 }
        }
        report["expanded"] = box(expanded)
        report["tailExpanded"] = describe(controller.model.tail)
        report["anchoredExpanded"] = controller.anchor != nil
        return report
    }

    /// The window's compositor frame once it has held still for `steady`, within `budget`; nil if it was never listed.
    static func steadyFrame(of window: NSWindow) async -> CGRect? {
        guard var settled = listedFrame(of: window) else { return nil }
        var since = ContinuousClock.now
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            guard let now = listedFrame(of: window) else { continue }
            if now != settled {
                settled = now
                since = .now
            } else if ContinuousClock.now - since >= steady {
                break
            }
        }
        return settled
    }

    /// A tail as the report says it: its edge, and its tip across the card — `null` once nothing points.
    private static func describe(_ tail: CardTail?) -> Any {
        guard let tail else { return NSNull() }
        return ["edge": tail.edge == .top ? "top" : "bottom", "tip": tail.tip.map { Double($0) } as Any? ?? NSNull()]
    }

    /// The longest step a posted drag takes, in points — what the window may lag the pointer by at the end.
    static let dragStep: CGFloat = 2

    /// **A real drag**: the button down at `start` (global, y down), moved there by `delta` in steps, and up. Every event
    /// states its modifiers — none — rather than inheriting the session's. False where an event could not be made.
    static func drag(from start: CGPoint, by delta: CGVector) async -> Bool {
        func post(_ type: CGEventType, _ point: CGPoint) -> Bool {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                                      mouseButton: .left) else { return false }
            event.flags = []
            event.post(tap: .cghidEventTap)
            return true
        }
        guard post(.leftMouseDown, start) else { return false }
        try? await Task.sleep(for: .milliseconds(120))
        // **Steps of at most `dragStep`, as a hand's are**: a drag begins on its first move, so the window follows from
        // there and the first step is the most it can lag the pointer by — measured on the E2E Mac, 12 steps of 10 pt
        // moved a window 110 of 120 pt, by AppKit's own background drag as by SwiftUI's.
        let steps = max(1, Int((max(abs(delta.dx), abs(delta.dy)) / dragStep).rounded(.up)))
        for step in 1...steps {
            let part = CGFloat(step) / CGFloat(steps)
            guard post(.leftMouseDragged, CGPoint(x: start.x + delta.dx * part, y: start.y + delta.dy * part)) else {
                return false
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let posted = post(.leftMouseUp, CGPoint(x: start.x + delta.dx, y: start.y + delta.dy))
        try? await Task.sleep(for: .milliseconds(120))
        return posted
    }

    /// **A control on this app's window pressed as VoiceOver presses it**: `AXPress`, found by a name ending `suffix`, in
    /// the window titled `title` — `pressed`, or why not. Asked of this process on the main actor, where HIServices
    /// serves it in-process on the calling thread (ADR-0042).
    static func press(endingWith suffix: String, inWindowTitled title: String) -> String {
        let application = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(application, 2)
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var out: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &out) == .success ? out : nil
        }
        guard let windows = value(application, kAXWindowsAttribute) as? [AXUIElement] else { return "no windows" }
        guard let window = windows.first(where: { value($0, kAXTitleAttribute) as? String == title }) else {
            return "no window titled \(title)"
        }
        var queue = [window]
        var head = 0
        while head < queue.count, head < 4_000 {
            let node = queue[head]
            head += 1
            if value(node, kAXRoleAttribute) as? String == kAXButtonRole,
               [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { (value(node, $0) as? String)?.hasSuffix(suffix) == true }) {
                let status = AXUIElementPerformAction(node, kAXPressAction as CFString)
                return status == .success ? "pressed" : "AXError \(status.rawValue)"
            }
            queue += value(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        return "no control named …\(suffix)"
    }
}
