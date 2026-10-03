/// Waits for a condition on the main actor, checking every `interval` — **the one copy**.
///
/// The panel's visibility check and the instruments' `settle` each had this loop and its 20 ms, and
/// they had already drifted: one looked once more when cancelled, the other did not (audit round 3,
/// #19). Three outcomes, because giving up is neither success nor a timeout, and the panel acts on the
/// difference — it closes a panel that timed out, and leaves alone one whose request was replaced.
@MainActor
enum Poll {
    enum Outcome: Equatable, Sendable {
        case met
        case timedOut
        /// The caller was cancelled, or `abandonIf` said to stop.
        case abandoned
    }

    static let interval: Duration = .milliseconds(20)

    /// `abandonIf` is asked before `condition` every time — **the last look on cancellation included** —
    /// so a reason to stop always wins over a condition that happens to hold. A cancelled poll looks once
    /// more, so a caller cancelled at the moment its condition came true is not told otherwise.
    static func until(
        within deadline: Duration, every interval: Duration = interval,
        abandonIf: @MainActor () -> Bool = { false }, _ condition: @MainActor () -> Bool
    ) async -> Outcome {
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            if abandonIf() { return .abandoned }
            if condition() { return .met }
            do { try await Task.sleep(for: interval) } catch {
                // The last look asks the reason to stop first, as every other look does — asked only
                // the condition, a superseded panel that happened to be drawn was reported seen.
                if abandonIf() { return .abandoned }
                return condition() ? .met : .abandoned
            }
        }
        if abandonIf() { return .abandoned }
        return condition() ? .met : .timedOut
    }
}
