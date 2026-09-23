import AppKit
import CoreGraphics

/// What the in-bundle instruments share — `--history-report`, `--settings-report`,
/// `--model-status`, `--model-report`, `--sense-report`, `--speech-report` and
/// `--translation-report` — written once, so they cannot drift apart. The polling helper was a
/// verbatim copy in each.
@MainActor
enum Instrument {
    /// Waits for `condition`, checking every 20 ms, and reports whether it came true.
    static func settle(until deadline: Duration, _ condition: @MainActor () -> Bool) async -> Bool {
        let started = ContinuousClock.now
        while ContinuousClock.now - started < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Whether the compositor lists `window` as on screen. **Nothing else is evidence**: a
    /// `UtilityWindow` reports `isVisible` while being drawn nowhere, and a report that asked the
    /// window instead once passed a drawer that was never drawn.
    static func isOnScreen(_ window: NSWindow?) -> Bool {
        guard let number = window?.windowNumber else { return false }
        let listed = (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return listed.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == number }
    }

    /// The report, as one line of JSON — through `write`, which a caller can replace, so an
    /// instrument's own writer is not bypassed for its successful runs and its failures alike.
    /// **False when it could not be written**, which a run must not survive as a success: a report
    /// that measured everything and printed nothing reads to the harness exactly like one that
    /// never ran. The sink answers that question rather than the serialisation alone — a line
    /// handed to a closed pipe is a report nobody received.
    ///
    /// The serialisation diagnostic goes to standard error and not through `write`: `write` is
    /// where the **report** goes, and a run that could not build one has no report to send there.
    ///
    /// `nonisolated` because nothing here needs the main actor — the rest of `Instrument` does,
    /// and two of the instruments this serves, `--speech-report` and `--translation-report`, do
    /// not run on one. Isolated, they could not have called it where they stand: the hop would
    /// carry a `[String: Any]` and a sink, and neither is `Sendable`.
    /// **The report is asked whether it is valid JSON before it is written, and `try?` is not what
    /// asks.** On Darwin `dataWithJSONObject:` *raises* `NSInvalidArgumentException` for a value it
    /// cannot write — measured 2026-09-23 with `Double.nan`: "Invalid number value (NaN) in JSON
    /// write", and the process died. An Objective-C exception is not a Swift error, so `try?` never
    /// saw it and this branch could not be reached: what read as a handled failure was an
    /// instrument taking the run down with it. `isValidJSONObject` answers the same question by
    /// returning, and refuses NaN and a `Date` alike.
    nonisolated static func write(_ report: [String: Any], to write: (String) -> Bool = LookupCommand.writeLine) -> Bool {
        guard JSONSerialization.isValidJSONObject(report),
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        else {
            LookupCommand.writeError("the report could not be serialised")
            return false
        }
        return write(String(decoding: data, as: UTF8.self))
    }
}
