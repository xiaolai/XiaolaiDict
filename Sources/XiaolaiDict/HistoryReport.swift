import AppKit
import XiaolaiDictCore

/// Whether the history drawer actually appears, docked where it asked to be, **without taking
/// focus** — measured inside the running bundle rather than asserted from the source.
///
/// The focus question is the one that matters. The spike this drawer came from called
/// `NSApp.activate()` and made its panel key, and built Escape handling and click-away dismissal on
/// top of that. XiaolaiDict's panels must never do it: the reader is mid-sentence in another app. A unit
/// test can check that the code does not call `activate`; only a running bundle can check that
/// nothing else activated it either.
@MainActor
enum HistoryReport {
    /// How long the instrument will wait for the drawer to appear before calling it a failure.
    static let appearance: Duration = .seconds(3)

    /// Set before the scene starts, so the delegate knows to measure instead of just running.
    nonisolated(unsafe) static var isWanted = false

    /// Measures **the running app**, not a controller built for the occasion. It has to: a scene
    /// exists only inside the app that declares it. It is a better instrument for it — what it
    /// measures is what the reader gets.
    static func run(in app: XiaolaiDictApp) async -> CommandStatus {
        let screens = NSScreen.screens.map(ScreenMetrics.init)
        let expected = DrawerPlacement.screen(under: UpPoint(NSEvent.mouseLocation), among: screens)
            .map { DrawerGeometry.make(DrawerLayout(thickness: 380, edge: .right), on: $0) }

        app.toggleHistory()
        // Asks the compositor, not the controller. The controller's own answer is what once
        // reported a drawer that had never been drawn.
        let appeared = await settle(until: appearance) { app.drawerIsDrawn && app.drawerModel.revealed }
        await app.drawerReload?.value

        // Read while it shows, because that is the only moment they can be true.
        let drawn = app.drawerIsDrawn
        let activatedUs = NSApp.isActive
        let claimedEscape = app.drawerHoldsEscape
        let frame = app.drawerWindowFrame
        let docked = expected.map { $0.windowRect.cg == frame } ?? false

        app.toggleHistory()
        let released = await settle(until: .seconds(2)) { !app.drawerHoldsEscape && !app.drawerIsDrawn }

        let report: [String: Any] = [
            "bundle": Bundle.main.bundleIdentifier ?? "none",
            "insideBundle": Bundle.main.bundleIdentifier != nil,
            "screens": screens.count,
            "appeared": appeared,
            "drawnOnScreen": drawn,
            "dockedWhereAsked": docked,
            "frame": NSStringFromRect(frame),
            "expectedFrame": expected.map { NSStringFromRect($0.windowRect.cg) } ?? "none",
            // False is the passing value. True means the drawer stole focus from whatever the
            // reader was reading, which is the whole reason this report exists.
            "activatedTheApp": activatedUs,
            "claimedEscapeWhileShown": claimedEscape,
            "releasedEscapeAfterClosing": released,
            "days": app.drawerModel.days.count,
            "entries": app.drawerModel.totalEntries,
            "problem": app.drawerModel.problem ?? "none",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else {
            return .internalError
        }
        LookupCommand.writeLine(String(decoding: data, as: UTF8.self))
        return appeared && drawn && docked && !activatedUs && claimedEscape && released ? .success : .failure
    }

    /// Waits for `condition`, checking each runloop turn, and reports whether it came true.
    private static func settle(until deadline: Duration, _ condition: @MainActor () -> Bool) async -> Bool {
        let started = ContinuousClock.now
        while ContinuousClock.now - started < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
