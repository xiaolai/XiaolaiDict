import Foundation
import Synchronization
import XiaolaiDictCore

/// Ends the model service once nothing has asked it anything for `interval` — which is how the model
/// is unloaded.
///
/// **Ending the process, not releasing the model inside it.** MLX does give its memory back — the
/// MLX-in-XPC spike (S3) measured active and cache at 0 after release — but the OS returns the
/// process's pages lazily, and the footprint left behind ran from 54 to 798 MB across runs. A process
/// that has exited holds nothing, and launchd starts a fresh one on the next request.
///
/// Never while a request is in flight: a long answer is not idleness. And **once it has decided to
/// end, it admits nothing more** — a request let in between the decision and the exit would be
/// killed without a reply, and its caller would wait out a deadline for an answer that is not coming.
/// The decision is taken under the lock that admits requests; `onIdle` runs after it is released, so
/// a callback of any kind cannot deadlock the service it is ending.
public final class IdleExit: Sendable {
    private struct State {
        var inFlight = 0
        var lastActivity: ContinuousClock.Instant
        /// Set when the service has decided to end, or is draining to end. Nothing is admitted
        /// after, and nothing ever clears it — so this is also what says the ending already
        /// happened. A second `fired` flag beside it could not disagree: both were set together,
        /// under one lock, and neither was ever cleared, which made the first half of `fireIfIdle`'s
        /// guard unable to be false. One state, or a guard with a clause that cannot fail.
        var draining = false
        var watching = false
    }

    private let interval: Duration
    private let state: Mutex<State>
    private let onIdle: @Sendable () -> Void

    public init(after interval: Duration, onIdle: @escaping @Sendable () -> Void) {
        self.interval = interval
        self.onIdle = onIdle
        state = Mutex(State(lastActivity: .now))
    }

    /// Starts watching, once; a second call does nothing. The watch lives as long as the process.
    public func start() {
        let first = state.withLock { state in
            defer { state.watching = true }
            return !state.watching
        }
        guard first else { return }
        Task.detached(priority: .utility) { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(until: nextCheck(), clock: .continuous)
                if fireIfIdle() { return }
            }
        }
    }

    /// Counts a request in **now**, before the work that will run it is even scheduled — the gap
    /// between XPC accepting a message and its task starting is a gap the watch could exit in.
    /// Released once, however the request ends.
    ///
    /// **Nil once the service is ending.** The caller answers that request itself, rather than
    /// starting work the process will not live to finish.
    public func admit() -> Lease? {
        let admitted = state.withLock { state -> Bool in
            guard !state.draining else { return false }
            state.inFlight += 1
            state.lastActivity = .now
            return true
        }
        guard admitted else { return nil }
        return Lease { [weak self] in self?.finish() }
    }

    /// One request's place in the count. Releasing twice is releasing once.
    public final class Lease: Sendable {
        private let released = Mutex(false)
        private let end: @Sendable () -> Void

        init(end: @escaping @Sendable () -> Void) { self.end = end }

        public func release() {
            guard released.withLock({ taken in
                defer { taken = true }
                return !taken
            }) else { return }
            end()
        }

        deinit { release() }
    }

    private func finish() {
        state.withLock {
            $0.inFlight -= 1
            $0.lastActivity = .now
        }
    }

    /// When the watch should look again: the moment the interval runs out — or, while a request is in
    /// flight, a whole interval from now, because the earliest the process can end is that long after
    /// the request finishes. Never a tight poll.
    func nextCheck(from now: ContinuousClock.Instant = .now) -> ContinuousClock.Instant {
        state.withLock { state in
            state.inFlight > 0 ? now.advanced(by: interval) : max(state.lastActivity.advanced(by: interval), now)
        }
    }

    /// Fires `onIdle` once, if nothing is in flight and the interval has passed since the last request
    /// began or ended. **Admission closes inside the lock, and `onIdle` runs outside it**: nothing can
    /// slip in between the decision and the ending, and nothing the callback does can deadlock against
    /// a request arriving. Exposed so the rule can be tested without waiting on a clock.
    ///
    /// `draining` is what makes it fire once: it is set here and never cleared, so a second call
    /// after the first — or after `drain(within:)` was asked directly — finds the service already
    /// ending and declines.
    @discardableResult
    func fireIfIdle(at now: ContinuousClock.Instant = .now) -> Bool {
        let fire = state.withLock { state -> Bool in
            guard !state.draining, state.inFlight == 0,
                  now >= state.lastActivity.advanced(by: interval)
            else { return false }
            state.draining = true
            return true
        }
        if fire { onIdle() }
        return fire
    }

    /// **Stops admitting, then waits** for everything already in flight to finish, up to `limit`, and
    /// says whether it did. Used before the service ends itself on request: a request admitted while
    /// it waited would be killed by the exit that follows, unanswered.
    public func drain(within limit: Duration) async -> Bool {
        state.withLock { $0.draining = true }
        let deadline = ContinuousClock.now.advanced(by: limit)
        while state.withLock({ $0.inFlight > 0 }), ContinuousClock.now < deadline {
            guard !Task.isCancelled else { break }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                break  // cancelled: stop waiting rather than spinning on a sleep that throws at once
            }
        }
        return state.withLock { $0.inFlight == 0 }
    }

    /// Whether the service has stopped admitting work.
    public var isDraining: Bool { state.withLock { $0.draining } }

    /// The idle interval, from the app's own defaults domain — see `ModelIdle`.
    public static func interval(appDomain: String) -> Duration {
        let configured = CFPreferencesCopyAppValue(ModelIdle.defaultsKey as CFString, appDomain as CFString) as? NSNumber
        return .seconds(ModelIdle.seconds(configured: configured?.intValue))
    }
}
