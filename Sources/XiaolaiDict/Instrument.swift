import AppKit
import CoreGraphics

/// What the in-bundle instruments share — `--history-report`, `--settings-report`,
/// `--model-status`, `--model-report` and `--sense-report` — written once, so they cannot drift
/// apart. The polling helper was a verbatim copy in each.
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
    static func write(_ report: [String: Any], to write: (String) -> Bool = LookupCommand.writeLine) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else {
            LookupCommand.writeError("the report could not be serialised")
            return false
        }
        return write(String(decoding: data, as: UTF8.self))
    }
}
