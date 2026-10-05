import Foundation

/// **R3's values, every one a recommendation awaiting the owner, and kept here and nowhere else**
/// (review-module-plan §5.1, §5.2, §9 R3 — needs-owner). Nothing below was decided by evidence; each
/// is the plan's recommended value or, where the plan names none, a guess, labelled as one.
///
/// | Value | Recommended | Basis |
/// |---|---|---|
/// | Reminders on | **off** until the reader turns them on | H1, U04; R3 |
/// | Fire time | **19:00** | [guess] — the plan says "a chosen time" and names none |
/// | Show N | **yes**, as a predicted count | R3's recommendation: exact unless the clock or zone changed while quit, or a sense hash moved |
/// | Later | **+2 h**, of 1, 2 or 4 h the reader may choose (2026-10-05) | [guess] |
/// | Horizon | **7 study days** | [guess], under the 64-request cap |
/// | Log kept | **14 study days** | [guess] |
///
/// **Three more R3 rules are structural, not values**, so they are not constants a caller could
/// change: at most one unrequested reminder a study day (one `daily` identifier per day), at most one
/// Later (`ReminderLog.laterAsked`, once per day), and no catch-up (nothing is ever planned at or
/// before now). Changing any of them is a change to the planner, not to this table. **Catch-up was
/// weighed as a reader option on 2026-10-05 and not built** (ADR-0048, addendum): a fire time missed
/// asleep reads as `gone`, which cannot be told from a banner delivered and dismissed, so honouring
/// "I missed it" would add a second unrequested banner.
public enum ReminderRecommendation {
    /// Off by default (R3). A reminder the reader did not ask for is the thing being decided.
    public static let isEnabled = false
    /// 19:00 local, in the study day's zone — a guess awaiting the owner.
    public static let hour = 19
    public static let minute = 0
    /// Keep N — R3's recommendation, awaiting the owner.
    public static let showsPredictedCount = true
    /// Two hours after the reader asks — a guess awaiting the owner.
    public static let laterDelay: TimeInterval = 2 * 60 * 60
    /// Seven study days, today first — a guess awaiting the owner, the same week `Forecast` looks at.
    public static let horizon = 7
    /// Fourteen study days of log, today included — a guess awaiting the owner. Long enough to answer
    /// "why was there no reminder last week" from the instrument; short enough that the defaults entry
    /// stays a few kilobytes.
    public static let retainedStudyDays = 14
}

/// **What the reader chose about reminders.** Kept in the app's defaults (WI-7), so it decodes
/// whatever an earlier or later version left there: an absent field is the recommendation, an extra
/// one is ignored, and a value off the clock is clamped rather than refused — this is a preference,
/// not a boundary anything hostile reaches.
public struct ReminderSettings: Sendable, Equatable {
    public let isEnabled: Bool
    /// The hour of the daily reminder, 0–23, on the study day's own clock. **Before the study day's
    /// cutoff it belongs to the study day before**: 01:30 ends the day that began at 04:00 yesterday.
    public let hour: Int
    public let minute: Int
    /// Whether the reminder says how many meanings a sitting would hold. Off, it says only that one
    /// is waiting — and the count is still asked, because nothing is planned into an empty queue.
    public let showsPredictedCount: Bool
    /// How long Later waits, as elapsed time: "in two hours" is two hours on any night of the year.
    /// **The reader's, from `laterDelayChoices`** since 2026-10-05 (Settings › General › Review Reminder).
    public let laterDelay: TimeInterval
    /// How many study days ahead are planned, today included.
    public let horizon: Int

    /// The most pending requests the system keeps for one app [v1-verified, forum only]. Not a guess
    /// of ours and not R3's: a ceiling the horizon has to fit under.
    public static let pendingRequestCap = 64
    /// **Two identifiers a study day** — the daily and its Later — **so 32 days fill the cap.** A
    /// longer horizon would have the system drop requests nobody chose to drop.
    public static let longestHorizon = pendingRequestCap / ReminderKind.allCases.count

    public init(isEnabled: Bool = ReminderRecommendation.isEnabled,
                hour: Int = ReminderRecommendation.hour,
                minute: Int = ReminderRecommendation.minute,
                showsPredictedCount: Bool = ReminderRecommendation.showsPredictedCount,
                laterDelay: TimeInterval = ReminderRecommendation.laterDelay,
                horizon: Int = ReminderRecommendation.horizon) {
        self.isEnabled = isEnabled
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
        self.showsPredictedCount = showsPredictedCount
        // A delay that is not a duration is the recommendation; a negative one is none.
        self.laterDelay = laterDelay.isFinite ? max(0, laterDelay) : ReminderRecommendation.laterDelay
        self.horizon = min(Self.longestHorizon, max(0, horizon))
    }

    /// Every value as R3 recommends it.
    public static let recommended = ReminderSettings()

    /// **How long Later may wait, as Settings offers it**: one, two or four hours — the recommendation in
    /// the middle. A small set, because the delay is a guess and so is any value between these.
    public static let laterDelayChoices: [TimeInterval] = [60 * 60, ReminderRecommendation.laterDelay, 4 * 60 * 60]

    /// **The delays a picker offers for these settings**: the choices, and the delay kept if it is not
    /// one of them — written by another version, or by the `reminder` stage. Shown rather than snapped
    /// to a neighbour, because it is the delay `ReminderLog.askingLater` will use.
    public var offeredLaterDelays: [TimeInterval] {
        Set(Self.laterDelayChoices + [laterDelay]).sorted()
    }
}

extension ReminderSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case isEnabled, hour, minute, showsPredictedCount, laterDelay, horizon
    }

    /// **Through the initialiser, so the clamps are not optional**, and every absent field is the
    /// recommendation — a defaults entry written by an earlier version is still read.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let recommended = Self.recommended
        self.init(isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? recommended.isEnabled,
                  hour: try values.decodeIfPresent(Int.self, forKey: .hour) ?? recommended.hour,
                  minute: try values.decodeIfPresent(Int.self, forKey: .minute) ?? recommended.minute,
                  showsPredictedCount: try values.decodeIfPresent(Bool.self, forKey: .showsPredictedCount)
                      ?? recommended.showsPredictedCount,
                  laterDelay: try values.decodeIfPresent(TimeInterval.self, forKey: .laterDelay)
                      ?? recommended.laterDelay,
                  horizon: try values.decodeIfPresent(Int.self, forKey: .horizon) ?? recommended.horizon)
    }
}
