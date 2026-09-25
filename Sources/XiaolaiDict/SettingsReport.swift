import AppKit
import XiaolaiDictUI

/// Whether the settings window is the size of the pane it is showing, and **moves between the
/// sizes rather than jumping** — measured inside the running bundle.
///
/// Asserting this from the source is not possible and guessing at it was worse. The window carried
/// `.frame(minWidth: 420, minHeight: 320)`, so every pane was drawn at one size: Dictionary and
/// About padded out with empty space, Lookup's 358 points of content scrolling inside a 320-point
/// box. Removing the fixed frame is a one-line change whose entire effect is at runtime, in a
/// window only a running app has — so the only honest check is to open it, select each pane, and
/// watch what the window does.
///
/// **A resize is measured as frames, not as endpoints.** A window that snaps and a window that
/// animates finish at exactly the same height, so comparing before with after cannot tell them
/// apart. What separates them is whether any height was ever seen *between* the two, which is why
/// this samples throughout the change rather than reading once at each end.
@MainActor
enum SettingsReport {
    /// How long to wait for the window itself.
    static let appearance: Duration = .seconds(5)
    /// How long a pane change is watched for. Comfortably longer than the movement, so a sample
    /// run never ends while the window is still moving and reports a height nothing settled at.
    static let movement: Duration = .milliseconds(900)
    /// How often the frame is read during a change. Fast enough to catch a movement of a few
    /// frames; slow enough not to starve the runloop that is drawing it.
    static let sampling: Duration = .milliseconds(8)
    /// How long a frame must hold still to count as at rest.
    static let rest: Duration = .milliseconds(300)
    /// How long to wait for that before reporting the window as never having settled.
    static let restDeadline: Duration = .seconds(3)

    /// Set before the scene starts, so the delegate measures instead of just running.
    nonisolated(unsafe) static var isWanted = false

    static func run(in app: XiaolaiDictApp) async -> CommandStatus {
        // **Asked for only once the environment's action exists.** `openSettings` is captured from
        // the menu-bar item's label, which is a view and runs its `.task` when SwiftUI gets to it —
        // and this runs from `applicationDidFinishLaunching`, which is earlier. Calling first and
        // hoping would open nothing at all, silently, exactly as an `EnvironmentValues()` built on
        // the spot once did.
        guard await WindowActions.shared.ready(within: appearance) else {
            return finish(["appeared": false, "problem": "the scene's openSettings action never arrived"], .failure)
        }
        // The Dictionary pane lists what the service reports, and nothing asks the service until
        // the menu is opened. Unasked, this measured the pane saying "Asking the dictionary
        // service…" — a different height from the pane a reader sees.
        await app.askForDictionaries()
        // Whether the service actually answered. Unanswered, the Dictionary pane shows "Asking the
        // dictionary service…" — a different pane from the one a reader sees, and a different
        // height. Reported rather than assumed, so a measurement of the placeholder says so.
        let dictionariesKnown = app.dictionaries != nil
        app.showSettings()
        // The compositor, not `isVisible`: a window can say it is visible and be drawn nowhere.
        let appeared = await Instrument.settle(until: appearance) { Instrument.isOnScreen(app.settingsWindow) }
        guard appeared, let window = app.settingsWindow else {
            return finish(["appeared": false, "problem": "the settings window never came up"], .failure)
        }

        // **Every pane is measured arriving from another one.** The first reading used to be of the
        // pane already showing, taken while the window could still be fitting itself after
        // opening — so the startup fit could stand in for the pane-to-pane movement this exists to
        // watch. Instead: wait for the opening fit to come to rest, visit every other pane, then
        // come back to the first.
        let opening = app.settings.pane
        // At rest *and* measured: a frame that has not moved yet is not the same as a pane that has
        // finished laying itself out, and an opening still settling would lend its movement to the
        // first pane change measured after it.
        // Both together, not one after the other: a frame that has not moved *yet* is not a pane
        // that has finished, and content arriving after a stability check starts the opening
        // resize just as the first transition begins to be sampled.
        let openedAtRest = await restingFrame(of: window) { app.settings.heights[opening] != nil }
        var measured: [Pane] = []
        for pane in SettingsPane.allCases where pane != opening {
            measured.append(await select(pane, in: app, of: window))
        }
        measured.append(await select(opening, in: app, of: window))

        // **A recording does not outlive the pane it is on** — measured here, in the running app,
        // because that is where two fixes for it failed while their unit tests passed: Settings
        // keeps a hidden pane's views alive and does not re-evaluate them, so neither the field's
        // `onDisappear` nor a flag handed to it ever fired, and the key monitor went on listening
        // on the other pane, where a combination pressed became the reader's new shortcut.
        let capture = app.settings.shortcutCapture
        app.settings.pane = .lookup
        var putBack = false
        capture.begin(in: app.settingsWindow, onPress: { _ in }, onEnd: { putBack = true })
        let listensOnItsOwnPane = capture.isListening
        app.settings.pane = .reading
        let endedWithThePane = !capture.isListening && putBack
        capture.end()

        // What the panes together say about the window. Kept as a comparison rather than as a
        // verdict: e2e.sh makes the assertions, and a report that decided for it could only ever
        // be checked against itself.
        let heights = measured.map(\.height)
        let widths = Set(measured.map(\.width))
        let biggest = measured.max { $0.move.change < $1.move.change }

        return finish([
            "appeared": true,
            "bundle": Bundle.main.bundleIdentifier ?? "none",
            "insideBundle": Bundle.main.bundleIdentifier != nil,
            "panes": measured.map(\.asReport),
            // The window came to rest after opening before anything was measured.
            "openedAtRest": openedAtRest,
            // And the dictionary service answered, so the Dictionary pane is the reader's and not
            // its loading placeholder.
            "dictionariesKnown": dictionariesKnown,
            // And after every pane change: an endpoint read while the window was still moving would
            // be a height nothing settled at, and would become the next pane's starting point.
            "settledEveryPane": measured.allSatisfy(\.settled),
            // One width across every pane. The panes' own ideal widths are 744, 714 and 131
            // points, so a window that let each decide would slide sideways on every click.
            "oneWidth": widths.count == 1,
            "width": widths.first ?? -1,
            // And the width it should be. One width was not enough to ask for: every pane came out
            // at SwiftUI's default of 900, the same as each other, with the panes adrift inside.
            "expectedWidth": SettingsView.paneWidth,
            // **The window is its pane plus the same chrome, every time** — the title bar and tabs
            // do not change between panes, so neither may the difference. The pane's height is
            // clamped the way the window clamps it, floor and ceiling both: without the floor, a
            // short pane padded up to it would report the padding as chrome.
            "chromes": measured.map { ($0.height - $0.fittedHeight).rounded() },
            // The window is the size of its pane: two panes of the same height would mean the
            // fixed frame is still deciding, under another name.
            "distinctHeights": Set(heights).count,
            "shortest": heights.min() ?? -1,
            "tallest": heights.max() ?? -1,
            // The largest change any one click made, and whether the window was ever seen
            // part-way through it. `steps` is the measurement that separates a movement from a
            // jump; the height at each end cannot.
            "biggestChange": biggest?.move.change ?? 0,
            "biggestChangePane": biggest?.name ?? "none",
            "stepsInBiggestChange": biggest?.move.steps ?? 0,
            // The top edge stays put: a settings window grows downward from its title bar, and
            // one that kept its bottom edge instead would walk up the screen on every click.
            "topEdgeDrift": measured.map(\.topDrift).max() ?? 0,
            // The jitter. 0 and 0 are the passing values: every pane change moved the bottom edge
            // one way, and never past where it was going.
            "reversals": measured.map(\.move.reversals).reduce(0, +),
            "worstOvershoot": measured.map(\.move.overshoot).max() ?? 0,
            // False is the passing value: the pane decides the height, and an edge the reader could
            // drag would be a second answer disagreeing with it.
            "resizable": window.styleMask.contains(.resizable),
            // Both must be true: the recorder listens while its pane is showing, and stops — hot
            // key put back — the moment the reader is on another one.
            "recordingListensOnItsOwnPane": listensOnItsOwnPane,
            "recordingEndsWithItsPane": endedWithThePane,
        ], .success)
    }

    /// One pane's reading.
    private struct Pane {
        let name: String
        let width: Double
        let height: Double
        /// The height the pane measured *itself* at, or -1 when it never did. Beside `height` so a
        /// failure says which half broke: a pane that measured itself wrongly, or a window that
        /// was told the right height and did not follow.
        let measured: Double
        /// How the window's height got here from the previous pane's.
        let move: FrameTrajectory
        /// How far the top edge moved while it did — 0 is the passing value.
        let topDrift: Double
        /// Whether the window came to rest within `restDeadline`.
        let settled: Bool

        /// The pane's own height as the window holds it: at least the floor, at most the ceiling.
        var fittedHeight: Double {
            min(max(measured, SettingsView.paneMinHeight), SettingsView.paneMaxHeight)
        }

        var asReport: [String: Any] {
            ["pane": name, "width": width, "height": height, "measured": measured,
             "change": move.change, "steps": move.steps, "topDrift": topDrift,
             "reversals": move.reversals, "overshoot": move.overshoot,
             "path": move.path.map { ($0 * 10).rounded() / 10 }, "settled": settled]
        }
    }

    /// Selects a pane and watches the window through the change, then until it is at rest.
    private static func select(
        _ pane: SettingsPane, in app: XiaolaiDictApp, of window: NSWindow
    ) async -> Pane {
        let before = window.frame
        app.settings.pane = pane

        // **Sampled all the way to rest**, not for a fixed spell and then again afterwards: a
        // movement that ran on past the watch would have had its late frames — where a reversal or
        // an overshoot would show — thrown away, and only its endpoints read.
        var heights: [Double] = []
        var tops: [Double] = []
        var still = ContinuousClock.now
        var last = window.frame
        let started = ContinuousClock.now
        var settled = false
        while ContinuousClock.now - started < movement + restDeadline {
            let frame = window.frame
            heights.append(frame.height)
            tops.append(frame.maxY)
            // Still *and* measured, judged on every sample: a pane whose height arrives late
            // starts its resize after a check that looked only at the frame.
            if frame != last || app.settings.heights[pane] == nil {
                last = frame
                still = ContinuousClock.now
            } else if ContinuousClock.now - started >= movement, ContinuousClock.now - still >= rest {
                settled = true
                break
            }
            try? await Task.sleep(for: sampling)
        }
        let measured = app.settings.heights[pane].map(Double.init) ?? -1
        let after = window.frame

        return Pane(
            name: pane.name,
            width: after.width,
            height: after.height,
            measured: measured,
            move: FrameTrajectory(from: before.height, samples: heights, to: after.height),
            topDrift: (tops + [before.maxY]).map { abs($0 - after.maxY) }.max() ?? 0,
            settled: settled)
    }

    /// Waits until the window's frame has held still for `rest` **while `measured` is true**, and
    /// reports whether it did within `restDeadline`. The two are judged together because either
    /// alone is satisfied by a pane that has not finished: a frame that has not moved yet, or a
    /// height reported a moment before the resize it causes.
    private static func restingFrame(
        of window: NSWindow, measured: @MainActor () -> Bool
    ) async -> Bool {
        let started = ContinuousClock.now
        var last = window.frame
        var stillSince = ContinuousClock.now
        while ContinuousClock.now - started < restDeadline {
            try? await Task.sleep(for: sampling)
            if window.frame != last || !measured() {
                last = window.frame
                stillSince = ContinuousClock.now
            } else if ContinuousClock.now - stillSince >= rest {
                return true
            }
        }
        return false
    }

    /// Writes the report and answers with `status` — or `.internalError` when it could not be
    /// written, because a measurement that printed nothing must not exit as a pass.
    private static func finish(_ report: [String: Any], _ status: CommandStatus) -> CommandStatus {
        Instrument.write(report) ? status : .internalError
    }
}

/// How a window's height moved between two resting points, from samples taken in between.
///
/// **A resize is measured as frames, not as endpoints.** A window that snaps and a window that
/// animates finish at exactly the same height, so comparing before with after cannot tell them
/// apart; and a window that shudders — past its target and back — takes as many frames as one that
/// glides. So three numbers: how many positions it was seen at between the ends (`steps`), how many
/// times it changed direction (`reversals`), and how far past either end it went (`overshoot`).
struct FrameTrajectory: Equatable {
    /// Less than this is not a movement. A frame lands on half points, and a half-point wobble is
    /// rounding rather than anything a reader could see.
    static let noise = 1.0

    /// Every distinct height seen, in order, starting where the window was.
    let path: [Double]
    let change: Double
    /// Positions strictly between the two ends. Zero means the window jumped.
    let steps: Int
    /// How many times the movement changed direction. A movement from one height to another goes
    /// one way; anything else is the window being pulled between two answers.
    let reversals: Int
    /// How far past either end the window went, in points.
    let overshoot: Double

    init(from start: Double, samples: [Double], to end: Double) {
        var path = [start]
        for height in samples where abs(height - (path.last ?? height)) >= Self.noise {
            path.append(height)
        }
        if abs(end - (path.last ?? end)) >= Self.noise { path.append(end) }
        let turns = zip(path, path.dropFirst()).map { $1 - $0 }
        let low = min(start, end)
        let high = max(start, end)
        self.path = path
        change = abs(end - start)
        // Strictly between the ends, so neither endpoint counts as a step towards itself; a height
        // read many times is one step — positions, not samples.
        steps = Set(path.filter { $0 > low && $0 < high }.map { ($0 * 100).rounded() }).count
        reversals = zip(turns, turns.dropFirst()).filter { ($0 > 0) != ($1 > 0) }.count
        overshoot = max(0, (path.max() ?? high) - high, low - (path.min() ?? low))
    }
}
