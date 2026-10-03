import XiaolaiDictBase

/// **How long each stage of one lookup took**, keyed by its request — gesture to capture, panel,
/// dictionary, sense, ledger row — logged as one line when the lookup is recorded.
///
/// The durations hover was designed against are *configured* limits: a 180 ms rest, a 5 s capture
/// deadline, a 3 s dictionary deadline. Nothing measured what a lookup actually spends where, so
/// the one open decision this plan left — whether the service should return the word before the
/// phrase — had no number to be decided on. This is that number, from the reader's own lookups.
///
/// A value, so the arithmetic is tested without a clock; bounded, because a superseded lookup is
/// never recorded and its entry would otherwise live for ever.
public struct LookupTimeline: Sendable {
    public enum Stage: String, Sendable, CaseIterable {
        /// The word was read — Accessibility, the pixels, or a selection.
        case captured
        case panelShown = "panel"
        case dictionaryAnswered = "dictionary"
        /// The selector answered — a mark or an abstention, drawn or not.
        case senseResolved = "sense"
        case recorded
        /// The ledger write failed: the lookup was shown and not kept.
        case notRecorded = "not recorded"
        /// Ended with no row, its panel never drawn — refused, or replaced before the compositor had it.
        /// From the reader's side nothing was shown, whichever it was.
        case notShown = "not shown"
        /// Ended with no row after its panel was drawn — a newer lookup or a dismissal took it.
        case superseded
    }

    /// How a lookup ended. **Not a Bool**: a lookup that ended before it had anything to record is
    /// neither a write that succeeded nor one that failed, and one the reader saw is not one they did not.
    public enum Ending: Sendable {
        case recorded, notRecorded, notShown, superseded

        var stage: Stage {
            switch self {
            case .recorded: .recorded
            case .notRecorded: .notRecorded
            case .notShown: .notShown
            case .superseded: .superseded
            }
        }
    }

    /// How many lookups may be in flight before the oldest is forgotten.
    public static let capacity = 64

    private struct Entry: Sendable {
        let started: ContinuousClock.Instant
        var source: String
        var marks: [(Stage, Duration)] = []
    }

    private var entries: [Int: Entry] = [:]
    private var order: [Int] = []

    public init() {}

    /// The lookup for `request` began at `started` — when the reader asked, not when the word came.
    public mutating func begin(request: Int, at started: ContinuousClock.Instant, source: String) {
        if entries[request] == nil { order.append(request) }
        entries[request] = Entry(started: started, source: source)
        while order.count > Self.capacity { entries[order.removeFirst()] = nil }
    }

    /// Notes that `stage` was reached. The first time counts; a stage is not reached twice.
    public mutating func mark(_ stage: Stage, request: Int, at instant: ContinuousClock.Instant) {
        guard var entry = entries[request], !entry.marks.contains(where: { $0.0 == stage }) else { return }
        entry.marks.append((stage, instant - entry.started))
        entries[request] = entry
    }

    /// Ends the lookup and returns its line — `request 12 · accessibilityTextRange · captured 8 ms ·
    /// panel 20 ms · …` — or nil for a request that was never begun. Each figure is from the start.
    public mutating func finish(request: Int, at instant: ContinuousClock.Instant, ending: Ending = .recorded) -> String? {
        mark(ending.stage, request: request, at: instant)
        guard let entry = entries.removeValue(forKey: request) else { return nil }
        order.removeAll { $0 == request }
        let stages = entry.marks.map { "\($0.0.rawValue) \(Int($0.1.milliseconds)) ms" }
        return (["request \(request)", entry.source] + stages).joined(separator: " · ")
    }
}
