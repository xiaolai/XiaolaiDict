import XiaolaiDictBase
import XiaolaiDictCore
import os

/// Each lookup's stage timings, logged as one line when it is recorded — see `LookupTimeline`.
///
/// **A collaborator of its own, not state on the app delegate** (ADR-0011): the delegate composes
/// and routes, and the timeline is a subject with its own rules — bounded, keyed by request, and
/// dated on the monotonic clock from the reader's ask.
@MainActor
final class LookupTimings {
    private var timeline = LookupTimeline()
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "lookup")

    func begin(request: Int, at asked: ContinuousClock.Instant, source: String) {
        timeline.begin(request: request, at: asked, source: source)
    }

    func mark(_ stage: LookupTimeline.Stage, request: Int, at instant: ContinuousClock.Instant = .now) {
        timeline.mark(stage, request: request, at: instant)
    }

    /// The last line logged — what a test reads, since the log itself cannot be.
    private(set) var lastLine: String?

    /// Ends the request's timeline and logs its line — `.recorded` only where the ledger has its row.
    func finish(request: Int, ending: LookupTimeline.Ending) {
        guard let line = timeline.finish(request: request, at: .now, ending: ending) else { return }
        lastLine = line
        log.notice("timing: \(line, privacy: .public)")
    }
}
