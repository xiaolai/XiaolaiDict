import Foundation

/// One lookup, as the history drawer shows it.
///
/// There is deliberately **no gloss, definition or sense text on this type**, for the same reason
/// `PriorEncounter` has none: a review surface that answers the question destroys the retrieval
/// that makes reviewing worth anything (`feature-ledger-ux.md` C2). What a card carries is the word
/// and *the reader's own sentence* — their text, not a publisher's — which is the cue, not the
/// answer. The omission is enforced by what the type cannot hold.
public struct ReadingEntry: Identifiable, Equatable, Sendable {
    /// The ledger row, so a card can be traced back to the lookup it came from.
    public let id: Int
    public let lemma: String
    /// The word exactly as it was on screen, which is not always the lemma.
    public let surface: String
    /// The sentence it was read in, where one was captured.
    public let sentence: String
    /// Where the word sits inside `sentence`, so the card can mark it.
    public let sentenceRange: NSRange?
    public let place: ReadingPlace
    public let at: Date
    public let result: LookupResult
    /// How the capture went — the same kind of signal `ReadingPlace.precision` carries about
    /// *where*, for the same reason. Nil only for rows written before schema 4, which is an
    /// absence of evidence and never to be filled in with a guess.
    ///
    /// **A card reads this, never `sentence` alone.** The ledger stores the selection itself when
    /// nothing surrounded the word, so the text cannot say whether it is a sentence the reader read
    /// or the word echoed back into the column.
    public let quality: CaptureQuality?

    /// No default, deliberately. Every caller states how good the capture was, because the failure
    /// this replaced was a caller quietly not carrying it.
    public init(
        id: Int, lemma: String, surface: String, sentence: String, sentenceRange: NSRange?,
        place: ReadingPlace, at: Date, result: LookupResult, quality: CaptureQuality?
    ) {
        self.id = id
        self.lemma = lemma
        self.surface = surface
        self.sentence = sentence
        self.sentenceRange = sentenceRange
        self.place = place
        self.at = at
        self.result = result
        self.quality = quality
    }

    /// What the card may say about `sentence`.
    ///
    /// Derived, never stored twice — the same rule as `ReadingPlace.precision`. A cue that could
    /// drift from the quality it describes would be exactly the stale second copy this project's
    /// memory rules ban.
    public var cue: SentenceCue {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        switch quality?.context {
        case .complete: return .sentence
        case .mayBeCut: return .truncatedSentence
        case .missing: return .none
        // Written before the quality column existed, so the only evidence left is the text itself:
        // a context that is just the word again is the echo, whatever wrote it. This guesses, and
        // it guesses in the direction that shows less rather than claims more.
        case nil:
            let echo = trimmed.localizedLowercase
            let word = surface.localizedLowercase
            let dictionaryForm = lemma.localizedLowercase
            return echo == word || echo == dictionaryForm ? .none : .sentence
        }
    }
}

/// What a card may say about the context stored beside a word.
///
/// Three cases because there are three things that can have happened, and a review surface that
/// renders the worst of them like the best is the failure `CaptureQuality` exists to prevent.
public enum SentenceCue: Equatable, Sendable {
    /// Nothing to show. The app exposed no text around the word, so the ledger stored the
    /// selection itself — and a word printed under itself is not a cue, it is the same word twice
    /// with the second copy dressed up as evidence.
    case none
    /// A sentence the reader read the word in.
    case sentence
    /// A sentence whose end was never captured. Shown, because a partial cue is still a cue, and
    /// marked, because it is not a whole one.
    case truncatedSentence
}

/// How a day is named. A classification rather than a string: the drawer renders it in the reader's
/// own locale, so nothing about grouping depends on the machine's language.
public enum DayLabel: Equatable, Sendable {
    case today
    case yesterday
    /// Within the last week — near enough that a weekday name still places it.
    case weekday
    /// Older, or dated in the future by a clock that jumped. Shown as a date.
    case date
}

/// One calendar day's reading.
public struct ReadingDay: Identifiable, Equatable, Sendable {
    /// `yyyy-MM-dd` in the reader's own time zone. Stable across relaunches, unlike a fresh
    /// identifier, which is what lets the drawer remember which piles were fanned open.
    public let id: String
    /// The start of the day, in the reader's time zone.
    public let date: Date
    public let label: DayLabel
    /// Newest first.
    public let entries: [ReadingEntry]

    /// Today is never piled — it is the part the reader came to read.
    public var isPiled: Bool { label != .today }

    public init(id: String, date: Date, label: DayLabel, entries: [ReadingEntry]) {
        self.id = id
        self.date = date
        self.label = label
        self.entries = entries
    }
}

public enum ReadingHistory {
    /// Groups lookups into calendar days, newest day first and newest lookup first within each.
    ///
    /// By calendar day in the reader's own zone, never by a 24-hour window: a lookup at 23:59 and
    /// one at 00:01 belong to different days, and the day a daylight-saving change shortens is
    /// still one day. The calendar is a parameter rather than `.current` so both of those are
    /// testable without moving the machine's clock.
    public static func days(from entries: [ReadingEntry], now: Date, calendar: Calendar) -> [ReadingDay] {
        guard !entries.isEmpty else { return [] }

        let today = calendar.startOfDay(for: now)
        var byDay: [Date: [ReadingEntry]] = [:]
        for entry in entries {
            byDay[calendar.startOfDay(for: entry.at), default: []].append(entry)
        }

        return byDay.keys.sorted(by: >).map { day in
            ReadingDay(
                id: identifier(of: day, calendar: calendar),
                date: day,
                label: label(of: day, today: today, calendar: calendar),
                // Newest first, and the row id breaks a tie so two lookups sharing a timestamp
                // cannot swap places between one reading of the drawer and the next.
                entries: (byDay[day] ?? []).sorted {
                    $0.at == $1.at ? $0.id > $1.id : $0.at > $1.at
                })
        }
    }

    /// Built from date components rather than a `DateFormatter`, so the identifier is the same
    /// string whatever language the machine is set to.
    private static func identifier(of day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func label(of day: Date, today: Date, calendar: Calendar) -> DayLabel {
        let elapsed = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch elapsed {
        case 0: return .today
        case 1: return .yesterday
        // Seven would land on today's weekday name and read as this week rather than last.
        case 2...6: return .weekday
        // Anything older — and anything dated ahead of now, where `elapsed` is negative.
        default: return .date
        }
    }
}
