import Foundation

/// **How long a test waits when the wait's only job is to stop a defect hanging the run** — the one copy.
///
/// Four times (c6b6260, 839fe6f, 4bc5bdc, and the commit that made this) a bound of a few seconds that
/// stood for "long enough" or "never" measured how loaded the Mac was rather than what the code did. A
/// test waiting on the main actor or the cooperative pool waits behind every other test's work on that
/// executor, and a full parallel run on a busy Mac starves both: on 2026-10-10, at a load average near
/// 90 on 10 cores, every main-actor test in `XiaolaiDictTests` finished in one burst after about 60 s
/// of AppKit layout, and two waits of **60 s** ran out on conditions that needed five 1 ms looks. A
/// count of sleeps is no better — 500 looks of 10 ms is a five-second clock in disguise.
///
/// So the three bounds below are long, and **a wait ends the moment its condition holds**: the length
/// is paid only by a test that is already failing. The order is the point — a wait fails by name
/// before the limit ends the test, and the limit ends a test before anything standing for "never" can
/// finish and let it pass. `PatienceTests` holds the order, and `PatienceScanTests` holds every test file to these
/// names — a poll, a time limit, a bound or a "never" spelled by hand is refused unless it is declared, with its reason.
///
/// A deadline that *is* a test's subject — the product's own, against a fake that never answers — is
/// short on purpose and is not this. A product deadline a test expects **not** to reach is: it stands
/// for "long enough", and is given `wait`.
public enum Patience {
    /// A wait for something that should happen.
    public static let wait: Duration = .seconds(300)
    /// A test's time limit, in minutes — the unit `.timeLimit` takes: `.timeLimit(.minutes(Patience.limitMinutes))`.
    public static let limitMinutes = 10
    /// What stands for "never": work nobody is meant to let finish, outlasting any limit.
    public static let never: Duration = .seconds(3_600)
    /// How often a wait looks.
    public static let look: Duration = .milliseconds(5)

    /// Whether `condition` held within `bound`, looked at every `interval` on the caller's actor. It is
    /// looked at first, so a condition already true costs no sleep, and once more when the caller is
    /// cancelled. **The answer is not discardable**: a wait whose outcome nobody asserts lets everything
    /// after it run against a state that never arrived.
    ///
    /// **`nonisolated(nonsending)`, the wait and its condition both**, so a condition runs where its caller
    /// is. An `isolated` parameter was not enough: a condition handed on as a value — `Wiring.settle`'s own
    /// `() -> Bool` — became a plain async function, ran on the global executor, and a main-actor
    /// condition there trapped the test process.
    public nonisolated(nonsending) static func until(
        within bound: Duration = wait, every interval: Duration = look,
        _ condition: nonisolated(nonsending) () async throws -> Bool
    ) async rethrows -> Bool {
        let deadline = ContinuousClock.now.advanced(by: bound)
        while true {
            if try await condition() { return true }
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: interval) } catch { return try await condition() }
        }
    }

    /// `until`, for a test that must not suspend — a synchronous test waiting on another process, or one
    /// turning the run loop itself, which passes a `pause` that turns it for `interval` instead of sleeping.
    public static func blockingUntil(
        within bound: Duration = wait, every interval: Duration = look,
        pause: (Duration) -> Void = { Thread.sleep(forTimeInterval: $0 / .seconds(1)) }, _ condition: () throws -> Bool
    ) rethrows -> Bool {
        let deadline = ContinuousClock.now.advanced(by: bound)
        while true {
            if try condition() { return true }
            guard ContinuousClock.now < deadline else { return false }
            pause(interval)
        }
    }
}
