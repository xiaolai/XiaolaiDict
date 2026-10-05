import Foundation

/// **FSRS-6, ported from `Tools/fsrs/fsrs6.py` and measured against it.**
///
/// The specification is `dev-docs/memory-curve-algorithm.md`; the kernel beside it is the numerical
/// contract, and `MemorySchedulerParityTests` asserts this reproduces 2,000 of its transitions exactly.
/// That gate is the only reason to trust this file: every constant here is a number that produces
/// plausible intervals when it is wrong, and a scheduler that is subtly wrong looks exactly like one
/// that is right until a reader has lost a year of reviews.
///
/// **Pure.** No storage, no eligibility, no idempotency — those are the caller's, and they are where the
/// product decisions live. This answers one question: given a card, a grade and an instant, what is the
/// card now.
///
/// Three things the spec calls out that a careless port loses, each kept deliberately below:
///
/// - the mean-reversion anchor `d₀(4)` is **raw and unclamped**; clamping it first is a different model;
/// - stability is computed from the **old** difficulty, and difficulty updated after;
/// - the post-lapse **ceiling** on stability, which the overview wiki omits.
public struct MemoryScheduler: Sendable {
    /// **The default configuration's identity** — the pinned kernel with `defaultWeights` and
    /// `defaultMaximumDays` — which is what a replay in this build rebuilds. A change to rounding, time
    /// semantics, steps or fuzz is a change to the scheduling contract and must change this string, or a
    /// replay will silently use today's rules on yesterday's history.
    public static let version = "fsrs6-py9446cb0-one10m-no-fuzz-v1"

    /// The interval cap the default configuration schedules with, in days.
    public static let defaultMaximumDays = 36_500

    /// **What an event this scheduler grades records as its `scheduler_version`**: every parameter that
    /// changes a transition, except retention, which an event keeps in a column of its own and a
    /// replay reads back from there.
    ///
    /// `version` for the default configuration, whatever its retention; for any other, `version` with
    /// the cap and the weights after it, written exactly (`Double`'s description round-trips). A replay
    /// in this build rebuilds the default alone, so a grade by another configuration is
    /// `unreplayable(.unknownSchedulerVersion)` — never `inconsistent` because the default's cap or
    /// weights scheduled it differently (WI-8: a cap of one day moved a first Good from 1,800,172,800
    /// to 1,800,086,400, and the version said nothing of it).
    public let identity: String

    /// The population-derived starting model — **not** a calibrated profile of this reader.
    public static let defaultWeights: [Double] = [
        0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194,
        0.001, 1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629,
        1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
    ]

    static let lower: [Double] = [
        0.001, 0.001, 0.001, 0.001, 1, 0.001, 0.001, 0.001, 0, 0, 0.001,
        0.001, 0.001, 0.001, 0, 0, 1, 0, 0, 0, 0.1,
    ]
    static let upper: [Double] = [
        100, 100, 100, 100, 10, 4, 4, 0.75, 4.5, 0.8, 3.5,
        5, 0.25, 0.9, 4, 1, 6, 2, 2, 0.8, 0.8,
    ]

    /// One ten-minute learning step and one fifteen-minute one, exactly as the pinned reference. **Not
    /// a ladder**: a first Good graduates straight to the computed interval rather than being made to
    /// repeat.
    static let againDelay: TimeInterval = 10 * 60
    static let hardDelay: TimeInterval = 15 * 60
    static let secondsPerDay: TimeInterval = 86_400

    let weights: [Double]
    public let retention: Double
    public let maximumDays: Int
    private let decay: Double
    private let factor: Double

    public init(retention: Double = 0.9, maximumDays: Int = MemoryScheduler.defaultMaximumDays,
                weights: [Double] = MemoryScheduler.defaultWeights) throws {
        guard retention.isFinite, retention > 0, retention < 1 else {
            throw SchedulerError.retentionOutOfRange(retention)
        }
        guard maximumDays >= 1 else { throw SchedulerError.maximumDaysOutOfRange(maximumDays) }
        guard weights.count == 21 else { throw SchedulerError.wrongParameterCount(weights.count) }
        for (index, value) in weights.enumerated() {
            guard value.isFinite, value >= Self.lower[index], value <= Self.upper[index] else {
                throw SchedulerError.parameterOutOfRange(index: index, value: value)
            }
        }
        self.weights = weights
        self.retention = retention
        self.maximumDays = maximumDays
        self.decay = -weights[20]
        self.factor = pow(0.9, 1 / decay) - 1
        self.identity = weights == Self.defaultWeights && maximumDays == Self.defaultMaximumDays
            ? Self.version
            : "\(Self.version)+maximumDays=\(maximumDays)+weights=\(weights.map { String($0) }.joined(separator: ","))"
    }

    /// The forgetting curve: the probability of recall after `elapsedDays`.
    ///
    /// Continuous, and accepts fractional days so a surface can explain it. **The scheduler evaluates it
    /// at whole elapsed days**, which is where parity with the reference lives.
    public func recall(elapsedDays: Double, stability: Double) throws -> Double {
        try Self.requirePositive(stability, SchedulerError.invalidStability(stability))
        guard elapsedDays.isFinite, elapsedDays >= 0 else {
            throw SchedulerError.invalidElapsedTime(elapsedDays)
        }
        return pow(1 + factor * elapsedDays / stability, decay)
    }

    /// The interval at which predicted recall falls to `retention`. At 0.9 it equals the stability.
    public func interval(stability: Double, retention: Double? = nil) throws -> Double {
        try Self.requirePositive(stability, SchedulerError.invalidStability(stability))
        let target = retention ?? self.retention
        guard target.isFinite, target > 0, target < 1 else {
            throw SchedulerError.retentionOutOfRange(target)
        }
        return stability / factor * (pow(target, 1 / decay) - 1)
    }

    /// Whole days, bounded, **ties to even** — `round()`'s behaviour in the reference, and the one
    /// rounding rule that is not what most people assume.
    ///
    /// **Capped before it becomes an `Int`.** Every retention in (0, 1) is accepted, and a low one makes
    /// the interval larger than `Int.max` days (0.001: about 6.7e19 for a first Good) or infinite, so
    /// converting first would trap. A whole number below 2^63 converts exactly, which is every value
    /// this gave before; anything at or past it is past every cap.
    public func scheduledDays(stability: Double) throws -> Int {
        let raw = try interval(stability: stability)
        guard !raw.isNaN else { throw SchedulerError.nonfiniteResult }
        let whole = raw.rounded(.toNearestOrEven)
        guard whole < 0x1p63 else { return maximumDays }
        guard whole >= 1 else { return 1 }  // `maximumDays` is at least 1, so the floor wins
        return min(maximumDays, Int(whole))
    }

    /// The raw initial-difficulty curve. **Unclamped on purpose**: it is the mean-reversion anchor as
    /// well as the initial value, and clamping it before the mean reversion changes the model.
    func initialDifficulty(_ grade: Grade) -> Double {
        weights[4] - exp(weights[5] * (Double(grade.rawValue) - 1)) + 1
    }

    /// One grade, applied. Eligibility, idempotency and storage are the caller's contract.
    public func review(_ card: ScheduledCard, grade: Grade, now: Date) throws -> ScheduledCard {
        let stability: Double
        let difficulty: Double
        var phase: SchedulePhase

        switch card.phase {
        case .new:
            // A new card must carry no invented memory. Anything else is a caller that made one up.
            guard card.state == nil, card.lastReview == nil, card.due == nil else {
                throw SchedulerError.newCardCarriesState
            }
            stability = max(0.001, weights[grade.rawValue - 1])
            difficulty = min(10, max(1, initialDifficulty(grade)))
            phase = .learning
        case .learning, .review, .relearning:
            guard let state = card.state, state.stability.isFinite, state.stability >= 0.001,
                  state.difficulty.isFinite, state.difficulty >= 1, state.difficulty <= 10
            else { throw SchedulerError.invalidMemoryState }
            guard let previous = card.lastReview, card.due != nil else {
                throw SchedulerError.invalidMemoryState
            }
            guard now >= previous else { throw SchedulerError.clockRolledBack(now: now, previous: previous) }

            let s = state.stability, d = state.difficulty
            // Whole elapsed days, floored — **not calendar days**. 23:55 → 00:05 is the short-term
            // branch, and a daylight-saving boundary decides nothing here.
            let elapsed = floor(now.timeIntervalSince(previous) / Self.secondsPerDay)
            // A span no whole-day count holds is damage, not a clock — a last review at -1e30 s. It is
            // refused, never converted: converting traps, and the grade path and a replay both reach
            // this with stored data (audit-fix round 1).
            guard elapsed < 0x1p63 else { throw SchedulerError.invalidElapsedTime(elapsed) }
            let days = Int(elapsed)
            if days == 0 {
                let gain = exp(weights[17] * (Double(grade.rawValue) - 3 + weights[18]))
                    * pow(s, -weights[19])
                // A successful short-term repetition may not *shrink* stability; a failure may.
                stability = max(0.001, s * (grade.rawValue >= 2 ? max(1, gain) : gain))
            } else {
                let r = try recall(elapsedDays: Double(days), stability: s)
                if grade == .again {
                    let afterLapse = weights[11] * pow(d, -weights[12])
                        * (pow(s + 1, weights[13]) - 1) * exp(weights[14] * (1 - r))
                    // **The post-lapse ceiling**, which the overview wiki omits and the pinned
                    // implementation has. Without it a lapse can raise stability.
                    let ceiling = s / exp(weights[17] * weights[18])
                    stability = max(0.001, min(afterLapse, ceiling))
                } else {
                    let multiplier = grade == .hard ? weights[15] : grade == .easy ? weights[16] : 1
                    stability = max(0.001, s * (1 + exp(weights[8]) * (11 - d) * pow(s, -weights[9])
                        * (exp(weights[10] * (1 - r)) - 1) * multiplier))
                }
            }
            // **Difficulty after stability, from the old `d`.** Substituting the new one is a
            // different algorithm, and one that produces entirely plausible numbers.
            let damped = d - weights[6] * (Double(grade.rawValue) - 3) * (10 - d) / 9
            difficulty = min(10, max(1, weights[7] * initialDifficulty(.easy) + (1 - weights[7]) * damped))
            phase = card.phase
        }

        let delay: TimeInterval
        switch (phase, grade) {
        case (.learning, .again), (.relearning, .again):
            delay = Self.againDelay
        case (.learning, .hard), (.relearning, .hard):
            delay = Self.hardDelay
        case (.learning, _), (.relearning, _):
            phase = .review
            delay = Double(try scheduledDays(stability: stability)) * Self.secondsPerDay
        case (.review, .again):
            phase = .relearning
            delay = Self.againDelay
        case (.review, _):
            delay = Double(try scheduledDays(stability: stability)) * Self.secondsPerDay
        case (.new, _):
            throw SchedulerError.invalidMemoryState  // unreachable: `.new` became `.learning` above
        }

        guard stability.isFinite, difficulty.isFinite else { throw SchedulerError.nonfiniteResult }
        return ScheduledCard(state: MemoryState(stability: stability, difficulty: difficulty),
                             phase: phase, lastReview: now, due: now.addingTimeInterval(delay))
    }

    private static func requirePositive(_ value: Double, _ error: @autoclosure () -> SchedulerError) throws {
        guard value.isFinite, value > 0 else { throw error() }
    }
}

/// What the reader answered. **Four, because the reference implements four** and a stored history has to
/// be replayable; the first interface offers two of them, and never maps a failure to `hard`.
public enum Grade: Int, Codable, Sendable, CaseIterable, Comparable {
    case again = 1, hard, good, easy

    public static func < (a: Grade, b: Grade) -> Bool { a.rawValue < b.rawValue }
}

/// Where the card is in the scheduler's own progression. **Not** whether it is due, which is derived
/// from `due` and the reader's eligibility rules.
public enum SchedulePhase: String, Codable, Sendable, CaseIterable {
    case new, learning, review, relearning
}

/// The memory the model estimates. **`S` is a time, not a score**: the days at which predicted recall
/// falls to 90%.
public struct MemoryState: Sendable, Equatable, Codable {
    public let stability: Double
    public let difficulty: Double

    public init(stability: Double, difficulty: Double) {
        self.stability = stability
        self.difficulty = difficulty
    }
}

/// A card as the scheduler sees it. **Absent, never zero**, for one that has not been reviewed: a
/// stability of 0 is a claim about memory, and "no attempt yet" is not one.
public struct ScheduledCard: Sendable, Equatable {
    public let state: MemoryState?
    public let phase: SchedulePhase
    public let lastReview: Date?
    public let due: Date?

    public init(state: MemoryState? = nil, phase: SchedulePhase = .new,
                lastReview: Date? = nil, due: Date? = nil) {
        self.state = state
        self.phase = phase
        self.lastReview = lastReview
        self.due = due
    }
}

public enum SchedulerError: Error, Equatable {
    case retentionOutOfRange(Double)
    case maximumDaysOutOfRange(Int)
    case wrongParameterCount(Int)
    case parameterOutOfRange(index: Int, value: Double)
    case invalidStability(Double)
    case invalidElapsedTime(Double)
    case invalidMemoryState
    case newCardCarriesState
    case clockRolledBack(now: Date, previous: Date)
    case nonfiniteResult
}
