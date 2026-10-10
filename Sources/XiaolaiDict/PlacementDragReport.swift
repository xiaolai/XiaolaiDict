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
              let window = controller.window
        else { return ["problem": "the lookup panel was never listed by the compositor"] }
        let watchedShown = await steadyFrame(of: window)
        guard let shown = watchedShown.frame else { return ["problem": watchedShown.problem("once shown") ?? ""] }
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
        let watchedDragged = await steadyFrame(of: window)
        guard let dragged = watchedDragged.frame else {
            return report.merging(["problem": watchedDragged.problem("after the drag") ?? ""]) { $1 }
        }
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
        let watchedArrived = await steadyFrame(of: window)
        guard let arrived = watchedArrived.frame else {
            return report.merging(["problem": watchedArrived.problem("after the entry arrived") ?? ""]) { $1 }
        }
        report["arrived"] = box(arrived)
        report["tailArrived"] = describe(controller.model.tail)

        // A disclosure, pressed through Accessibility in this process, on the main actor (ADR-0042).
        report["disclosure"] = Self.press(endingWith: "other meanings", inWindowTitled: window.title)
        let watchedExpanded = await steadyFrame(of: window)
        guard let expanded = watchedExpanded.frame else {
            return report.merging(["problem": watchedExpanded.problem("after the disclosure") ?? ""]) { $1 }
        }
        report["expanded"] = box(expanded)
        report["tailExpanded"] = describe(controller.model.tail)
        report["anchoredExpanded"] = controller.anchor != nil
        return report
    }

    /// What a window's frame did while it was watched.
    enum Watched: Equatable {
        /// It held this frame for `steady`.
        case steady(CGRect)
        /// It was still moving when the budget ran out; the last frame seen.
        case unsettled(last: CGRect)
        /// It was not listed — before the watch began, or once it had.
        case vanished
        /// The lookup never answered within the budget, so no frame of the card it fills was measured.
        case unanswered

        /// The frame, where it held still; nil otherwise.
        var frame: CGRect? {
            if case .steady(let frame) = self { return frame }
            return nil
        }

        /// Why there is no settled frame, for a report to say — nil where there is one.
        func problem(_ moment: String) -> String? {
            switch self {
            case .steady: nil
            case .unsettled(let last):
                "the lookup panel never held still \(moment), within the budget; last at \(last)"
            case .vanished: "the lookup panel was no longer listed by the compositor \(moment)"
            case .unanswered: "the lookup never answered \(moment), within the budget, so its card was not measured"
            }
        }
    }

    /// The window's compositor frame once it has held still for `steady`, within `budget` — or that it never did, or
    /// that the window went.
    static func steadyFrame(of window: NSWindow) async -> Watched {
        await watch({ listedFrame(of: window) }, steady: steady, budget: budget, every: .milliseconds(100))
    }

    /// **The card's frame once its lookup has answered and it has then held still** (second audit of 2026-10-10). A card
    /// is shown waiting before the dictionaries are asked, and "Looking up…" held for a second counted as settled
    /// whenever they took longer — the frame measured was the waiting card's. So the answer is waited for first, within
    /// the same budget, the window checked on throughout; then `frame` is watched as `watch` watches it.
    static func watch(
        answered: @escaping @MainActor () -> Bool, frame: () -> CGRect?, steady: Duration, budget: Duration,
        every interval: Duration
    ) async -> Watched {
        let deadline = ContinuousClock.now + budget
        while !answered() {
            guard frame() != nil else { return .vanished }
            guard ContinuousClock.now < deadline else { return .unanswered }
            try? await Task.sleep(for: interval)
        }
        return await watch(frame, steady: steady, budget: max(.zero, deadline - .now), every: interval)
    }

    /// **`frame` read until it has held one value for `steady`** (audit of 2026-10-10). Never the last value seen when
    /// the budget runs out — a card still moving then is `unsettled`, a measurement that failed — and never a frame
    /// once the window is not listed: it is `vanished` at the first read that does not find it, where this used to keep
    /// watching and answer with the frame from before it went.
    static func watch(_ frame: () -> CGRect?, steady: Duration, budget: Duration, every interval: Duration) async -> Watched {
        guard var settled = frame() else { return .vanished }
        var since = ContinuousClock.now
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: interval)
            guard let now = frame() else { return .vanished }
            if now != settled {
                settled = now
                since = .now
            } else if ContinuousClock.now - since >= steady {
                return .steady(settled)
            }
        }
        return .unsettled(last: settled)
    }

    /// A tail as the report says it: its edge, and its tip across the card — `null` once nothing points.
    private static func describe(_ tail: CardTail?) -> Any {
        guard let tail else { return NSNull() }
        return ["edge": tail.edge == .top ? "top" : "bottom", "tip": tail.tip.map { Double($0) } as Any? ?? NSNull()]
    }

    /// The longest step a posted drag takes, in points — what the window may lag the pointer by at the end.
    static let dragStep: CGFloat = 2
    /// **The farthest a drag may go on either axis**, in points — farther than the card can travel on any display it was
    /// measured on, and a thousand steps at most. Checked before the button goes down (third audit of 2026-10-10).
    nonisolated static let dragLimit: CGFloat = 2_000

    /// **A real drag**: the button down at `start` (global, y down), moved there by `delta` in steps, and up — each event
    /// through `post`, `Instrument.postMouse` by default, which states its modifiers. False where the drag could not be
    /// made, or was cancelled.
    ///
    /// **Bounded before the button goes down, and the button always comes up** (third audit of 2026-10-10): a distance
    /// that is not finite, or past `dragLimit`, posts nothing — `1e100` trapped on its step count with the button down and
    /// no mouse-up to follow; and once the button is down, an event that cannot be made or a cancellation ends the drag
    /// with the button released where the pointer last went.
    static func drag(
        from start: CGPoint, by delta: CGVector,
        post: (CGEventType, CGPoint) -> Bool = { Instrument.postMouse($0, at: $1) },
        pause: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Bool {
        guard delta.dx.isFinite, delta.dy.isFinite, abs(delta.dx) <= dragLimit, abs(delta.dy) <= dragLimit else {
            return false
        }
        // **Steps of at most `dragStep`, as a hand's are**: a drag begins on its first move, so the window follows from
        // there and the first step is the most it can lag the pointer by — measured on the E2E Mac, 12 steps of 10 pt
        // moved a window 110 of 120 pt, by AppKit's own background drag as by SwiftUI's. Bounded by `dragLimit` above.
        let steps = max(1, Int((max(abs(delta.dx), abs(delta.dy)) / dragStep).rounded(.up)))
        guard post(.leftMouseDown, start) else { return false }
        var at = start
        var released = false
        defer { if !released { _ = post(.leftMouseUp, at) } }
        await pause(.milliseconds(120))
        for step in 1...steps {
            guard !Task.isCancelled else { return false }
            let part = CGFloat(step) / CGFloat(steps)
            let next = CGPoint(x: start.x + delta.dx * part, y: start.y + delta.dy * part)
            guard post(.leftMouseDragged, next) else { return false }
            at = next
            await pause(.milliseconds(10))
        }
        released = true
        let posted = post(.leftMouseUp, at)
        await pause(.milliseconds(120))
        return posted && !Task.isCancelled
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
