// Compiled beside every helper in `Tools/e2e`, as `running-app.swift` is (`e2e.sh`'s install step), so the one way a
// helper writes its report is written once. Declarations only.
import CoreGraphics
import Foundation

/// **A helper's report as one line of JSON, or nil where it holds a value JSON cannot**, asked first.
///
/// On Darwin `JSONSerialization.data(withJSONObject:)` *raises* `NSInvalidArgumentException` for NaN or infinity — an
/// Objective-C exception no `try` sees — so a report holding one frame of NaN took its helper down instead of answering
/// (AGENTS.md; the third audit of 2026-10-10 found five helpers calling it directly). `isValidJSONObject` answers the same
/// question by returning. The keys are sorted, so a line reads the same every run.
func jsonLine(_ report: [String: Any]) -> String? {
    guard JSONSerialization.isValidJSONObject(report),
          let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    else { return nil }
    return String(decoding: data, as: UTF8.self)
}

/// A rectangle every one of whose numbers is finite — what Accessibility should answer and need not — or nil.
func finite(_ rect: CGRect) -> CGRect? {
    [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) ? rect : nil
}
