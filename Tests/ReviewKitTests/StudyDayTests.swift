import Foundation
import ReviewKit
import Testing

/// **The daily new-card allowance** (C08, and §10.4/§10.7 of the scheduler specification).
///
/// A P0 row that went unbuilt through WI-003: without it a first session is ten cards the reader
/// has never seen, all of which come back tomorrow, and the day after that they have twenty. The
/// allowance is the only thing standing between "I saved some words" and a backlog that grows
/// faster than anyone answers it.
struct StudyDayTests {
    /// 2027-01-15 12:00 UTC, built from its components rather than an epoch literal so the
    /// arithmetic below can be checked by eye against the comments.
    private let noon: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 12))!
    }()

    private func utc(_ cutoff: Int = 4) -> StudyDay {
        StudyDay(timeZone: TimeZone(identifier: "UTC")!, cutoffHour: cutoff)
    }

    /// **Before the cutoff belongs to yesterday**, which is the whole point of a boundary that is
    /// not midnight: someone reviewing at half past midnight is finishing the day they were awake
    /// for, and handing them a second day's new cards then is the opposite of helpful.
    @Test func atimeBeforeTheCutoffBelongsToTheDayBefore() {
        let day = utc()
        let start = day.start(containing: noon)
        // 04:00 the same day.
        #expect(start == noon.addingTimeInterval(-8 * 3_600))

        let oneAM = noon.addingTimeInterval(13 * 3_600)  // 01:00 the next calendar day
        #expect(day.start(containing: oneAM) == start, "01:00 is still the previous study day")

        let fiveAM = noon.addingTimeInterval(17 * 3_600)  // 05:00 the next calendar day
        #expect(day.start(containing: fiveAM) == start.addingTimeInterval(86_400),
                "05:00 has crossed into the next study day")
    }

    /// Exactly at the cutoff is the new day, not the old one.
    @Test func thecutoffInstantItselfStartsTheNewDay() {
        let day = utc()
        let start = day.start(containing: noon)
        #expect(day.start(containing: start) == start)
        #expect(day.start(containing: start.addingTimeInterval(-1)) == start.addingTimeInterval(-86_400))
    }

    /// **The cutoff is 04:00 on every day of the year, including the two that are not 24 hours
    /// long.** Adding `4 * 3600` to midnight is real-time arithmetic over a local-time boundary:
    /// on a spring-forward day an hour is missing, so it lands at 05:00, and on a fall-back day
    /// an hour repeats, so it lands at 03:00. A reader in a DST zone got a day that started an
    /// hour early or an hour late, twice a year, silently — and the allowance turns over on it.
    @Test func thecutoffIs0400OnDaylightSavingDaysToo() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let day = StudyDay(timeZone: zone, cutoffHour: 4)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        // 2026-03-08 springs forward at 02:00; 2026-11-01 falls back at 02:00.
        for (month, dayOfMonth) in [(3, 8), (11, 1)] {
            let noon = try #require(calendar.date(from: DateComponents(
                year: 2026, month: month, day: dayOfMonth, hour: 12)))
            let start = day.start(containing: noon)
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
            #expect(parts.hour == 4 && parts.minute == 0,
                    "2026-\(month)-\(dayOfMonth): the day started at \(parts.hour ?? -1):\(parts.minute ?? -1)")
            #expect(parts.day == dayOfMonth, "and on the day the reader is in")
        }
    }

    /// **A day before a short day is still one day.** Stepping back by 86,400 seconds from a
    /// cutoff lands an hour out whenever a transition falls between them.
    @Test func theDayBeforeAdaylightSavingDayEndsAtItsOwnCutoff() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let day = StudyDay(timeZone: zone, cutoffHour: 4)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // 01:00 on the spring-forward day belongs to the day before, which began at 04:00 on the 7th.
        let smallHours = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 1)))
        let parts = calendar.dateComponents([.month, .day, .hour], from: day.start(containing: smallHours))
        #expect(parts.day == 7 && parts.hour == 4,
                "started at 2026-\(parts.month ?? -1)-\(parts.day ?? -1) \(parts.hour ?? -1):00")
    }

    /// **A cutoff the clock skips moves that day's boundary and no other** (audit-fix round 1). New
    /// York at 02:00 on 2026-03-08 does not exist; the day's start resolves forward to 03:00 EDT. The
    /// day before was found by stepping a *calendar day* back from that resolved instant, which keeps
    /// its hour — 03:00 EST on the 7th, where the 7th's own start is 02:00 — and the day after likewise
    /// landed at 03:00 EDT on the 9th. One study day then had two starts depending on which side it
    /// was asked from. Each neighbour is built from its own calendar date and the cutoff hour.
    @Test func aCutoffTheClockSkipsMovesOnlyItsOwnDay() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let day = StudyDay(timeZone: zone, cutoffHour: 2)
        let iso = ISO8601DateFormatter()
        func at(_ text: String) throws -> Date { try #require(iso.date(from: text)) }
        let seventh = try at("2026-03-07T07:00:00Z"), eighth = try at("2026-03-08T07:00:00Z")
        let ninth = try at("2026-03-09T06:00:00Z")
        #expect(day.start(containing: try at("2026-03-07T17:00:00Z")) == seventh, "a control: 02:00 EST on the 7th")
        #expect(day.start(containing: try at("2026-03-08T06:30:00Z")) == seventh,
                "01:30 EST on the 8th is the 7th's study day, which began at 02:00")
        #expect(day.start(containing: try at("2026-03-08T16:00:00Z")) == eighth, "02:00 resolves to 03:00 EDT")
        #expect(day.startOfNextDay(containing: try at("2026-03-07T17:00:00Z")) == eighth)
        #expect(day.startOfNextDay(containing: try at("2026-03-08T16:00:00Z")) == ninth,
                "the 9th begins at 02:00 EDT, not at the 8th's resolved hour")
        #expect(day.start(containing: try at("2026-03-09T16:00:00Z")) == ninth)
    }

    /// **Every boundary is one boundary, asked from either side**, across every transition of 2026 in
    /// zones with an hour, a half-hour, and a midnight change, at every cutoff: the day ending is where
    /// the next begins, a start is its own start, and an instant lies inside its own day.
    @Test func eachBoundaryIsTheSameFromBothSidesAcrossEveryTransition() throws {
        var checked = 0
        for identifier in ["America/New_York", "Europe/London", "Australia/Lord_Howe", "America/Santiago",
                           "America/Havana"] {
            let zone = try #require(TimeZone(identifier: identifier))
            var transitions: [Date] = []
            var cursor = try #require(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
            while let next = zone.nextDaylightSavingTimeTransition(after: cursor), next.timeIntervalSince(cursor) < 400 * 86_400,
                  transitions.count < 2 {
                transitions.append(next)
                cursor = next
            }
            try #require(transitions.count == 2, "\(identifier) has no transitions to test in 2026")
            for cutoff in 0...23 {
                let day = StudyDay(timeZone: zone, cutoffHour: cutoff)
                for transition in transitions {
                    for step in -144...144 {
                        let instant = transition.addingTimeInterval(Double(step) * 1_800)
                        let start = day.start(containing: instant), next = day.startOfNextDay(containing: instant)
                        #expect(start <= instant && instant < next, "\(identifier) \(cutoff): \(instant) outside its day")
                        #expect(day.start(containing: next) == next, "\(identifier) \(cutoff): \(next) is not its own start")
                        #expect(day.startOfNextDay(containing: start.addingTimeInterval(-1)) == start,
                                "\(identifier) \(cutoff): the day before \(start) ended elsewhere")
                        checked += 1
                    }
                }
            }
        }
        #expect(checked == 5 * 24 * 2 * 289)
    }

    /// A cutoff of midnight is allowed and means what it says; nonsense is clamped rather than
    /// refused, because this is a preference and not a boundary anything hostile reaches.
    /// **Decoding goes through the clamp too.** Synthesised `Codable` assigns stored properties
    /// directly, so a persisted 99 came back as 99 and the day boundary landed days away.
    @Test func adecodedCutoffIsClampedLikeAconstructedOne() throws {
        let json = Data(#"{"timeZone":{"identifier":"UTC"},"cutoffHour":99}"#.utf8)
        let decoded = try JSONDecoder().decode(StudyDay.self, from: json)
        #expect(decoded.cutoffHour == 23, "decoding bypassed the clamp")

        // And a round trip of a legitimate value is unchanged.
        let original = StudyDay(timeZone: TimeZone(identifier: "UTC")!, cutoffHour: 4)
        let back = try JSONDecoder().decode(StudyDay.self, from: try JSONEncoder().encode(original))
        #expect(back == original)
    }

    @Test func anOutOfRangeCutoffIsClamped() {
        #expect(StudyDay(cutoffHour: -3).cutoffHour == 0)
        #expect(StudyDay(cutoffHour: 99).cutoffHour == 23)
        let midnight = StudyDay(timeZone: TimeZone(identifier: "UTC")!, cutoffHour: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(midnight.start(containing: noon) == calendar.startOfDay(for: noon))
    }
}
