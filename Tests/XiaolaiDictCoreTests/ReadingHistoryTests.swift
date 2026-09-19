import Foundation
import Testing

@testable import XiaolaiDictCore

private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

/// A date in `zone`, written the way the test reads.
private func at(_ text: String, _ zone: String = "UTC") -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: zone)!
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

private func entry(_ lemma: String, _ when: Date, id: Int = 0) -> ReadingEntry {
    ReadingEntry(
        id: id, lemma: lemma, surface: lemma, sentence: "A sentence with \(lemma) in it.",
        sentenceRange: nil, place: ReadingPlace(name: "TextEdit"), at: when, result: .found)
}

struct ReadingDayGroupingTests {
    @Test func lookupsOnTheSameCalendarDayShareADay() {
        let days = ReadingHistory.days(
            from: [entry("fine", at("2026-09-20 09:00")), entry("hold", at("2026-09-20 21:30"))],
            now: at("2026-09-20 22:00"), calendar: calendar("UTC"))

        #expect(days.count == 1)
        #expect(days[0].entries.count == 2)
    }

    /// A minute apart across midnight is two days. Grouping by a 24-hour window instead of by
    /// calendar day would put these together and label the pair with one date.
    @Test func aMinuteEitherSideOfMidnightIsTwoDays() {
        let days = ReadingHistory.days(
            from: [entry("fine", at("2026-09-19 23:59")), entry("hold", at("2026-09-20 00:01"))],
            now: at("2026-09-20 09:00"), calendar: calendar("UTC"))

        #expect(days.count == 2)
    }

    @Test func daysRunNewestFirstAndSoDoTheLookupsInThem() {
        let days = ReadingHistory.days(
            from: [
                entry("older", at("2026-09-18 10:00")),
                entry("morning", at("2026-09-20 08:00")),
                entry("evening", at("2026-09-20 20:00")),
            ],
            now: at("2026-09-20 22:00"), calendar: calendar("UTC"))

        #expect(days.map(\.id) == ["2026-09-20", "2026-09-18"])
        #expect(days[0].entries.map(\.lemma) == ["evening", "morning"])
    }

    /// The id has to survive a relaunch, because it is what remembers which piles are fanned open.
    @Test func aDayIsIdentifiedByItsDateNotByAFreshValue() {
        let lookups = [entry("fine", at("2026-09-20 09:00"))]
        let once = ReadingHistory.days(from: lookups, now: at("2026-09-20 10:00"), calendar: calendar("UTC"))
        let twice = ReadingHistory.days(from: lookups, now: at("2026-09-20 18:00"), calendar: calendar("UTC"))

        #expect(once[0].id == "2026-09-20")
        #expect(once[0].id == twice[0].id)
    }

    @Test func nothingReadMeansNoDaysAtAll() {
        #expect(ReadingHistory.days(from: [], now: at("2026-09-20 10:00"), calendar: calendar("UTC")).isEmpty)
    }

    /// A day is a calendar day, not 86,400 seconds. On the day a DST change makes 23 hours long,
    /// an arithmetic window drifts into the neighbouring day.
    @Test func aShortenedDaylightSavingDayIsStillOneDay() {
        let zone = "America/New_York"   // 2026-03-08: clocks go forward, the day is 23 hours
        let days = ReadingHistory.days(
            from: [entry("fine", at("2026-03-08 01:00", zone)), entry("hold", at("2026-03-08 23:00", zone))],
            now: at("2026-03-08 23:30", zone), calendar: calendar(zone))

        #expect(days.count == 1)
        #expect(days[0].entries.count == 2)
    }

    /// The reader's own day, not UTC's. At 20:00 in New York it is already tomorrow in UTC, and a
    /// drawer that said "Yesterday" about this afternoon would be wrong for the reader.
    @Test func daysAreGroupedInTheReadersOwnTimeZone() {
        let zone = "America/New_York"
        let days = ReadingHistory.days(
            from: [entry("fine", at("2026-09-20 20:00", zone)), entry("hold", at("2026-09-20 21:00", zone))],
            now: at("2026-09-20 22:00", zone), calendar: calendar(zone))

        #expect(days.count == 1)
        #expect(days[0].label == .today)
    }
}

struct ReadingDayLabelTests {
    private let now = at("2026-09-20 12:00")

    private func label(daysBack: Int) -> DayLabel {
        let when = calendar("UTC").date(byAdding: .day, value: -daysBack, to: now)!
        return ReadingHistory.days(from: [entry("fine", when)], now: now, calendar: calendar("UTC"))[0].label
    }

    @Test func theCurrentDayIsToday() { #expect(label(daysBack: 0) == .today) }

    @Test func theDayBeforeIsYesterday() { #expect(label(daysBack: 1) == .yesterday) }

    /// Two to six days back still have a weekday name the reader can place. Seven would repeat
    /// today's name, which reads as this week rather than last.
    @Test func theRestOfTheWeekIsNamedByItsWeekday() {
        for daysBack in 2...6 { #expect(label(daysBack: daysBack) == .weekday, "\(daysBack) days back") }
    }

    @Test func aWeekBackAndOlderIsADate() {
        #expect(label(daysBack: 7) == .date)
        #expect(label(daysBack: 400) == .date)
    }

    /// A clock that jumped, or a row written by a machine running ahead. It is not today, and
    /// calling it today would be the one label the reader cannot argue with.
    @Test func aLookupDatedInTheFutureIsNotLabelledToday() {
        let tomorrow = calendar("UTC").date(byAdding: .day, value: 1, to: now)!
        let days = ReadingHistory.days(from: [entry("fine", tomorrow)], now: now, calendar: calendar("UTC"))
        #expect(days[0].label != .today)
        #expect(days[0].label != .yesterday)
    }

    /// Labels are classifications, not strings: the drawer renders them in the reader's locale, so
    /// nothing here depends on the machine's language.
    @Test func todayIsTodayAtOneMinutePastMidnight() {
        let justAfterMidnight = at("2026-09-20 00:01")
        let days = ReadingHistory.days(
            from: [entry("fine", justAfterMidnight)], now: at("2026-09-20 00:02"), calendar: calendar("UTC"))
        #expect(days[0].label == .today)
    }
}

struct ReadingDayPileTests {
    /// Today is never piled — it is the part the reader came to read.
    @Test func todayIsNeverPiled() {
        let days = ReadingHistory.days(
            from: [entry("fine", at("2026-09-20 09:00"))],
            now: at("2026-09-20 10:00"), calendar: calendar("UTC"))
        #expect(!days[0].isPiled)
    }

    @Test func everyEarlierDayIsPiled() {
        let days = ReadingHistory.days(
            from: [entry("fine", at("2026-09-19 09:00")), entry("hold", at("2026-09-12 09:00"))],
            now: at("2026-09-20 10:00"), calendar: calendar("UTC"))
        let piled = days.map(\.isPiled)
        #expect(piled == [true, true])
    }
}
