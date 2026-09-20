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

    static func run() async -> CommandStatus {
        let ledger: LedgerStore?
        do {
            ledger = try await LedgerStore.openDefault()
        } catch {
            ledger = nil
        }

        let drawer = HistoryDrawerController(load: { [ledger] in
            guard let ledger else { return .unavailable("the ledger would not open") }
            do {
                let since = Date.now.addingTimeInterval(-HistoryDrawerController.window)
                return .entries(try await ledger.recentLookups(
                    since: since, limit: HistoryDrawerController.cardLimit))
            } catch {
                return .unavailable("\(error)")
            }
        })

        let screens = NSScreen.screens.map(ScreenMetrics.init)
        let expected = DrawerPlacement.screen(under: UpPoint(NSEvent.mouseLocation), among: screens)
            .map { DrawerGeometry.make(DrawerLayout(thickness: 380, edge: .right), on: $0) }

        drawer.show()
        // Polled, not slept: the instrument waits for the thing it is measuring and gives up after
        // a deadline, rather than guessing how long a spring takes on an unloaded machine.
        let appeared = await settle(until: appearance) { drawer.isOnScreen && drawer.model.revealed }
        await drawer.reload?.value

        // Read while the drawer shows, because that is the only moment they can be true.
        let activatedUs = NSApp.isActive
        let claimedEscape = drawer.isEscapeClaimed
        let frame = drawer.windowFrame
        let docked = expected.map { $0.windowRect.cg == frame } ?? false

        drawer.hide()
        let released = await settle(until: .seconds(2)) { !drawer.isEscapeClaimed && !drawer.isOnScreen }

        let report: [String: Any] = [
            "bundle": Bundle.main.bundleIdentifier ?? "none",
            "insideBundle": Bundle.main.bundleIdentifier != nil,
            "screens": screens.count,
            "appeared": appeared,
            "dockedWhereAsked": docked,
            "frame": NSStringFromRect(frame),
            "expectedFrame": expected.map { NSStringFromRect($0.windowRect.cg) } ?? "none",
            // False is the passing value. True means the drawer stole focus from whatever the
            // reader was reading, which is the whole reason this report exists.
            "activatedTheApp": activatedUs,
            "claimedEscapeWhileShown": claimedEscape,
            "releasedEscapeAfterClosing": released,
            "days": drawer.model.days.count,
            "entries": drawer.model.totalEntries,
            "problem": drawer.model.problem ?? "none",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else {
            return .internalError
        }
        LookupCommand.writeLine(String(decoding: data, as: UTF8.self))

        // A drawer that never appeared, or one that appeared by stealing focus, is a failed
        // measurement and says so in its exit status rather than only in its text.
        return appeared && !activatedUs && claimedEscape && released ? .success : .failure
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
