import Foundation

/// **Today's new-meaning allowance, raised for today only** — "Introduce More Today" at the end of a
/// sitting (review-module-plan §3: worth it; WI-5).
///
/// Keyed by the start of the study day it was granted on, and worth nothing on any other: it expires
/// where that study day ends, at the next cutoff on the reader's calendar — not 24 hours after
/// anything, which on a fall-back weekend would end it an hour early. A value kept from an earlier day
/// is simply a value for another day.
///
/// **It spends nothing** (ADR-0037). The allowance is spent by introductions — a card's first graded,
/// unvoided review — so this raises only the ceiling they are counted against, and undoing an
/// introduction still refunds it without anything here remembering to.
public struct OneDayIncrease: Sendable, Equatable, Codable {
    /// The start of the study day it was granted on. **Nil matches no day**: a stored value missing
    /// its day says nothing about which day it was for.
    let day: Date?
    /// How many introductions it adds that day. Never negative.
    let extra: Int

    init(day: Date?, extra: Int) {
        self.day = day.map(ReviewInstant.stored)
        self.extra = max(0, extra)
    }

    /// `count` more introductions, on the study day containing `instant`.
    public static func granted(_ count: Int, in studyDay: StudyDay, at instant: Date) -> OneDayIncrease {
        OneDayIncrease(day: studyDay.start(containing: instant), extra: count)
    }

    /// What it adds to the allowance of the study day containing `instant`: all of it on the day it
    /// was granted, nothing on any other.
    public func extra(in studyDay: StudyDay, at instant: Date) -> Int {
        day == ReviewInstant.stored(studyDay.start(containing: instant)) ? extra : 0
    }

    /// This increase raised by `count` on the study day containing `instant`. **Today's adds up; an
    /// earlier day's is dropped and today's starts from `count`** — it raised that day's allowance,
    /// and that day is over. Saturates rather than trapping, and never goes down.
    public func raised(by count: Int, in studyDay: StudyDay, at instant: Date) -> OneDayIncrease {
        let today = extra(in: studyDay, at: instant)
        let (sum, overflowed) = today.addingReportingOverflow(max(0, count))
        return OneDayIncrease(day: studyDay.start(containing: instant), extra: overflowed ? .max : sum)
    }

    // MARK: - As kept between launches

    private enum CodingKeys: String, CodingKey {
        /// Seconds since 1970, as the ledger keeps its instants (`ReviewInstant`).
        case day
        case extra
    }

    /// **Whatever was kept, read as no increase where it cannot be one** — an absent day matches no
    /// day, an absent or negative count is zero — rather than a launch that fails over a preference.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(day: try values.decodeIfPresent(Double.self, forKey: .day).map(ReviewInstant.decoded),
                  extra: try values.decodeIfPresent(Int.self, forKey: .extra) ?? 0)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(day.map(ReviewInstant.encoded), forKey: .day)
        try values.encode(extra, forKey: .extra)
    }
}
