import Foundation
@testable import ReviewKit
import Testing

/// **"Introduce more today" raises today's allowance, and today's alone** (review-module-plan §3,
/// WI-5; ADR-0037).
///
/// The increase is keyed by the study day it was granted on. It ends where that study day ends —
/// at the next 04:00 on the reader's calendar, not 24 hours after anything — and a value kept from
/// an earlier day raises nothing. It spends nothing either: the allowance is spent by introductions,
/// and this only moves the ceiling they are counted against.
struct OneDayIncreaseTests {
    private func newYork() throws -> TimeZone { try #require(TimeZone(identifier: "America/New_York")) }

    /// 2026-`month`-`day` at `hour`:`minute` in New York.
    private func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try newYork()
        return try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day,
                                                               hour: hour, minute: minute)))
    }

    /// **It lasts until the next study day starts, on the calendar.** Granted on Saturday evening
    /// 2026-10-31 in New York, whose study day runs from 04:00 Saturday to 04:00 Sunday — 25 hours,
    /// because the clocks go back at 02:00 on Sunday. An increase that expired 24 hours after the day
    /// began would be gone at 03:00 on Sunday, an hour early; this one holds until 04:00. Before the
    /// day it was granted on it never applied.
    @Test func aOneDayIncreaseExpiresAtTheNextStudyDay() throws {
        let day = StudyDay(timeZone: try newYork(), cutoffHour: 4)
        let increase = OneDayIncrease.granted(5, in: day, at: try local(10, 31, 22))

        #expect(increase.extra(in: day, at: try local(10, 31, 4)) == 5, "the start of the day it was granted on")
        #expect(increase.extra(in: day, at: try local(11, 1, 3, 30)) == 5,
                "24.5 hours after the day began, which is still that day")
        #expect(increase.extra(in: day, at: try local(11, 1, 3, 59)) == 5)
        #expect(increase.extra(in: day, at: try local(11, 1, 4)) == 0, "the next study day has begun")
        #expect(increase.extra(in: day, at: try local(11, 2, 12)) == 0)
        #expect(increase.extra(in: day, at: try local(10, 31, 3, 59)) == 0, "the day before it was granted")
    }

    /// **Raising adds to today's, and starts again on any other day.** A kept value from yesterday
    /// is not carried into today's: it raised yesterday's allowance, and that day is over.
    @Test func raisingAddsToTodaysAndAnEarlierDaysIsDropped() throws {
        let day = StudyDay(timeZone: try newYork(), cutoffHour: 4)
        let saturday = try local(10, 31, 22)
        let increase = OneDayIncrease.granted(5, in: day, at: saturday)

        #expect(increase.raised(by: 3, in: day, at: try local(11, 1, 0, 30)).extra(in: day, at: saturday) == 8)
        let sunday = try local(11, 1, 9)
        let next = increase.raised(by: 3, in: day, at: sunday)
        #expect(next.extra(in: day, at: sunday) == 3, "yesterday's five were carried into today")
        #expect(next.extra(in: day, at: saturday) == 0)

        // Nothing negative, and nothing that overflows: an increase is never a decrease or a trap.
        #expect(OneDayIncrease.granted(-4, in: day, at: sunday).extra(in: day, at: sunday) == 0)
        #expect(next.raised(by: -2, in: day, at: sunday).extra(in: day, at: sunday) == 3)
        #expect(OneDayIncrease.granted(.max, in: day, at: sunday).raised(by: 7, in: day, at: sunday)
                    .extra(in: day, at: sunday) == .max)
    }

    /// **Read back as it was written, and anything missing raises nothing.** The value is kept in
    /// the reader's defaults between launches, so it is decoded from whatever a later or earlier
    /// version left there: an absent day matches no day, an absent or negative count is zero.
    @Test func aStoredIncreaseReadsBackAndAMissingFieldIsNothing() throws {
        let day = StudyDay(timeZone: try newYork(), cutoffHour: 4)
        let saturday = try local(10, 31, 22)
        let increase = OneDayIncrease.granted(5, in: day, at: saturday)
        let decoded = try JSONDecoder().decode(OneDayIncrease.self, from: JSONEncoder().encode(increase))
        #expect(decoded == increase)
        #expect(decoded.extra(in: day, at: saturday) == 5)

        let start = day.start(containing: saturday).timeIntervalSince1970
        for json in ["{}", "{\"extra\": 5}", "{\"day\": \(start)}", "{\"day\": \(start), \"extra\": -3}"] {
            let read = try JSONDecoder().decode(OneDayIncrease.self, from: Data(json.utf8))
            #expect(read.extra(in: day, at: saturday) == 0, "\(json) raised the allowance")
        }
        // The control: the same shape with every field present does raise it.
        let whole = try JSONDecoder().decode(OneDayIncrease.self, from: Data("{\"day\": \(start), \"extra\": 2}".utf8))
        #expect(whole.extra(in: day, at: saturday) == 2)
    }
}
