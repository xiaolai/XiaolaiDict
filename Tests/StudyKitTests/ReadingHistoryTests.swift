import CaptureModel
import DictionaryModel
import Foundation
import Testing

@testable import StudyKit

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
        sentenceRange: nil, place: ReadingPlace(name: "TextEdit"), at: when, result: .found,
        quality: .accessibility(.accessibilityTextRange, context: .complete))
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

/// A card for each *reading*, not for each lookup.
///
/// A reader meets the same word again, and every meeting used to become its own card. Measured on
/// a real ledger 2026-09-30: `delirium` five times in 81 seconds in one sentence, `malleable`
/// twice in 17; 19 of 102 cards repeated a word already on screen that day, and one day drew 9
/// cards for 4 words.
struct ReadingRepeatTests {
    private static func read(
        _ lemma: String, _ when: Date, id: Int, sentence: String = "The sentence.",
        ordinal: Int? = 2, of outOf: Int = 2, by chosenBy: SenseChoice? = .model
    ) -> ReadingEntry {
        ReadingEntry(
            id: id, lemma: lemma, surface: lemma, sentence: sentence, sentenceRange: nil,
            place: ReadingPlace(name: "Chrome"), at: when, result: .found,
            quality: .accessibility(.accessibilityTextRange, context: .complete),
            sense: ordinal.map {
                SenseNote(dictionary: "NOAD", ordinal: $0, outOf: outOf, gloss: nil, chosenBy: chosenBy)
            })
    }

    private static func day(_ entries: [ReadingEntry]) -> ReadingDay {
        ReadingHistory.days(
            from: entries, now: at("2026-09-29 23:00"), calendar: calendar("UTC"))[0]
    }

    /// The reported case, in miniature.
    @Test func thesameWordInTheSameSentenceIsOneCard() {
        let day = Self.day([
            Self.read("delirium", at("2026-09-29 01:03"), id: 96),
            Self.read("delirium", at("2026-09-29 01:04"), id: 97),
            Self.read("delirium", at("2026-09-29 01:05"), id: 98),
        ])
        #expect(day.entries.count == 1, "drew \(day.entries.count) cards for one reading")
        #expect(day.entries[0].times == 3)
        #expect(day.entries[0].id == 98, "the newest reading should front the card")
        #expect(day.entries[0].repeats == [97, 96], "newest first, and never its own id")
    }

    /// **The load-bearing half.** A different sentence is a different reading, and folding those
    /// together would hide where the reader actually met the word.
    @Test func adifferentSentenceIsADifferentCard() {
        let day = Self.day([
            Self.read("hive", at("2026-09-29 10:00"), id: 1, sentence: "A hive of activity."),
            Self.read("hive", at("2026-09-29 10:01"), id: 2, sentence: "The bees left the hive."),
        ])
        #expect(day.entries.count == 2)
        #expect(day.entries.allSatisfy { $0.times == 1 })
    }

    /// And a different *sense* of the same word in the same sentence is a disagreement the reader
    /// is entitled to see, never noise to fold away.
    @Test func adifferentSenseIsNeverFoldedAway() {
        let day = Self.day([
            Self.read("fine", at("2026-09-29 10:00"), id: 1, ordinal: 1),
            Self.read("fine", at("2026-09-29 10:01"), id: 2, ordinal: 7),
        ])
        #expect(day.entries.count == 2, "two senses were drawn as one card")
    }

    /// **The reader's own tap fronts the group.** All five `delirium` lookups carried one sense
    /// key and one of them also carried `chosen_by = reader`; a card that showed the newest
    /// regardless would draw the reader's own confirmation as a guess.
    @Test func thereadersOwnTapFrontsTheGroup() {
        let day = Self.day([
            Self.read("delirium", at("2026-09-29 01:03"), id: 96, by: .model),
            Self.read("delirium", at("2026-09-29 01:04"), id: 97, by: .reader),
            Self.read("delirium", at("2026-09-29 01:05"), id: 98, by: .model),
        ])
        #expect(day.entries.count == 1)
        #expect(day.entries[0].id == 97, "the confirmed reading did not front the card")
        #expect(day.entries[0].sense?.isConfirmed == true)
        #expect(day.entries[0].repeats.sorted() == [96, 98])
    }

    /// Nothing is lost: a card answers for every row it stands for, which is what a removal reaches.
    @Test func acardAnswersForEveryLookupItStandsFor() {
        let ids = [96, 97, 98, 99, 100]
        let day = Self.day(ids.enumerated().map { index, id in
            Self.read("delirium", at("2026-09-29 01:0\(index)"), id: id)
        })
        #expect(day.entries.count == 1)
        #expect(day.entries[0].lookupIDs.sorted() == ids)
        #expect(Set(day.entries[0].lookupIDs).count == ids.count, "a row was counted twice")
    }

    /// Days are never crossed — a word read on two days is two cards, under the two dates.
    @Test func awordMetOnTwoDaysIsTwoCards() {
        let days = ReadingHistory.days(
            from: [
                Self.read("hive", at("2026-09-28 10:00"), id: 1),
                Self.read("hive", at("2026-09-29 10:00"), id: 2),
            ],
            now: at("2026-09-29 23:00"), calendar: calendar("UTC"))
        #expect(days.count == 2)
        #expect(days.allSatisfy { $0.entries.count == 1 && $0.entries[0].times == 1 })
    }

    /// A card sits where its most recent reading does, not where its first did.
    @Test func acardSitsAtItsNewestReading() {
        let day = Self.day([
            Self.read("delirium", at("2026-09-29 09:00"), id: 1),
            Self.read("vanish", at("2026-09-29 10:00"), id: 2),
            Self.read("delirium", at("2026-09-29 11:00"), id: 3),
        ])
        #expect(day.entries.map(\.lemma) == ["delirium", "vanish"])
        #expect(day.entries[0].times == 2)
    }

    /// **A found and a not-found reading are two cards**, because they draw differently: one
    /// carries the miss badge. Collapsing them made one card stand for two visible states.
    @Test func afoundAndAmissedReadingDoNotCollapse() {
        // Identical in every other field, so only `result` can separate them. Built by hand rather
        // than through `read(_:_:id:)`, whose default sense would have separated them anyway — the
        // first version of this test passed without `result` in the key at all.
        func entry(_ result: LookupResult, id: Int, at when: Date) -> ReadingEntry {
            ReadingEntry(
                id: id, lemma: "qqqq", surface: "qqqq", sentence: "The sentence.",
                sentenceRange: nil, place: ReadingPlace(name: "Chrome"), at: when, result: result,
                quality: .accessibility(.accessibilityTextRange, context: .complete))
        }
        let day = Self.day([
            entry(.found, id: 1, at: at("2026-09-29 10:00")),
            entry(.notFound, id: 2, at: at("2026-09-29 10:01")),
        ])
        #expect(day.entries.count == 2, "a found and a missed reading were drawn as one card")
    }

    /// **And a reading with no captured sentence is its own card.** One draws the cue, the other
    /// draws nothing where the cue would be, so merging them puts a sentence on a card that has
    /// none — or takes one away.
    @Test func areadingWithNoCapturedSentenceIsItsOwnCard() {
        func entry(_ context: CaptureQuality.Context, id: Int, at when: Date) -> ReadingEntry {
            ReadingEntry(
                id: id, lemma: "qqqq", surface: "qqqq", sentence: "The sentence.",
                sentenceRange: nil, place: ReadingPlace(name: "Chrome"), at: when, result: .found,
                quality: .accessibility(.accessibilityTextRange, context: context))
        }
        let day = Self.day([
            entry(.complete, id: 1, at: at("2026-09-29 10:00")),
            entry(.missing, id: 2, at: at("2026-09-29 10:01")),
        ])
        #expect(day.entries.count == 2, "a cue and a silence were drawn as one card")
    }

    /// **Two senses at the same coordinates are two cards.** A dictionary name with a block and an
    /// ordinal says where a sense sits, not which sense it is — across homographs, or two revisions
    /// of one dictionary, the same coordinates carry different meanings.
    @Test func twoGlossesAtTheSameCoordinatesDoNotCollapse() {
        func withGloss(_ gloss: String, id: Int, at when: Date) -> ReadingEntry {
            ReadingEntry(
                id: id, lemma: "fine", surface: "fine", sentence: "The sentence.", sentenceRange: nil,
                place: ReadingPlace(name: "Chrome"), at: when, result: .found,
                quality: .accessibility(.accessibilityTextRange, context: .complete),
                sense: SenseNote(dictionary: "NOAD", ordinal: 2, outOf: 2, gloss: gloss, chosenBy: .model))
        }
        let day = Self.day([
            withGloss("of high quality", id: 1, at: at("2026-09-29 10:00")),
            withGloss("a sum exacted as a penalty", id: 2, at: at("2026-09-29 10:01")),
        ])
        #expect(day.entries.count == 2, "two meanings were drawn as one card")
    }

    /// **One lemma in two languages is two words**, which is what a study note is already keyed by.
    @Test func onelemmaInTwoLanguagesDoesNotCollapse() {
        func word(_ language: String, id: Int, at when: Date) -> ReadingEntry {
            ReadingEntry(
                id: id, lemma: "gift", surface: "gift", sentence: "Ein Wort.", sentenceRange: nil,
                place: ReadingPlace(name: "Chrome"), at: when, result: .found,
                quality: .accessibility(.accessibilityTextRange, context: .complete),
                language: language)
        }
        let day = Self.day([
            word("en", id: 1, at: at("2026-09-29 10:00")),
            word("de", id: 2, at: at("2026-09-29 10:01")),
        ])
        #expect(day.entries.count == 2, "two languages' words were drawn as one card")
    }

    /// A reading with no sense still collapses, and one that abstained differently does not.
    @Test func anAbstentionIsPartOfWhatMakesACardDifferent() {
        let plain = Self.read("qqqq", at("2026-09-29 10:00"), id: 1, ordinal: nil)
        let refused = ReadingEntry(
            id: 2, lemma: "qqqq", surface: "qqqq", sentence: "The sentence.", sentenceRange: nil,
            place: ReadingPlace(name: "Chrome"), at: at("2026-09-29 10:01"), result: .found,
            quality: .accessibility(.accessibilityTextRange, context: .complete),
            senseAbstention: .refused)
        #expect(Self.day([plain, plain.standing(for: [])]).entries.count == 1)
        #expect(Self.day([plain, refused]).entries.count == 2, "a refusal was folded into a silence")
    }
}
