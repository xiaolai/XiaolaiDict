import CaptureModel
import DictionaryModel
import Foundation

/// One **reading**, as the history drawer shows it — which is not one lookup.
///
/// A reader meets the same word again: measured on a real ledger 2026-09-30, `delirium` was looked
/// up five times in 81 seconds in one sentence, `malleable` twice in 17 — 19 of 102 cards repeated
/// a word already on screen that day, and one day was 9 cards for 4 words. Drawn one per lookup
/// that is a column of cards the reader cannot tell apart, and it buries the words they read once.
///
/// So a card stands for every lookup that would have drawn it identically, and `repeats` names the
/// others. What a card is answerable for is `lookupIDs`, never `id` alone — a removal that reached
/// only the row it was drawn from would leave the rest behind and the card would come back.
///
/// **This type carries no gloss of its own, but it is not a type-level guarantee** — `sense` holds a
/// `SenseNote`, and a `SenseNote` holds the gloss. `PriorEncounter` is the one whose omission the
/// compiler enforces. Here the answer is reachable and the protection is the view's: the drawer's
/// deliberate reveal, per-card `@State`, never persisted (`feature-ledger-ux.md` C2 — a review
/// surface that answers the question destroys the retrieval that makes reviewing worth anything).
/// Anything that renders a `ReadingEntry` inherits that obligation rather than the safety.
///
/// What a card shows unasked is the word and *the reader's own sentence* — their text, not a
/// publisher's — which is the cue, not the answer.
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
    /// How the word was being used, where that is known. Recorded at lookup time from schema 5 on,
    /// and tagged from the reader's own sentence for the rows written before that.
    public let partOfSpeech: String?
    /// Which sense the reader met — **never its wording, unless they ask for it**. See `SenseNote`.
    public let sense: SenseNote?
    /// Why the selector marked no sense, where it declined — from schema 6 on. What lets a card say
    /// "the model declined this sentence" rather than showing the same nothing as "no model here".
    public let senseAbstention: Abstention?
    /// The other lookups this card stands for — the same word, sentence and sense, met again the
    /// same day. Newest first, and never containing `id`.
    ///
    /// **Defaulted, because every existing caller means "this one lookup".** Only
    /// `ReadingHistory.days` collapses, and it is the only thing that passes anything here.
    public let repeats: [Int]
    /// The language of the word, where the ledger recorded one.
    ///
    /// **A lemma alone collides**, which this project already says of a study note and of a
    /// suggestion — *die*, *chat*, *pain*, and English *gift* against German *Gift*. The drawer
    /// filters by script, and two languages can share one; counting or grouping by lemma alone
    /// makes those one word.
    public let language: String?
    public let disposition: LookupDisposition
    public let studyNoteID: UUID?
    public let studyStatus: StudyReadiness?
    /// What the kept note lacks to be asked, from the same facts as `studyStatus`. **What History's
    /// Confirm is offered by**: an entry rung carrying the dictionary's text is `.needsConfirmation` and
    /// confirming it changes nothing (ADR-0030), so the verdict alone offered a control that did nothing.
    public let studyObstacle: StudyObstacle?
    /// What the kept note reveals — **its** answer, off the same association as `studyNoteID`.
    ///
    /// Not `sense?.gloss`: that is the newest encounter, which an auxiliary tap can be, and the note
    /// is the one the reading is kept under. Confirming a note after showing the encounter's gloss
    /// agreed to one meaning and confirmed another. Hidden by the same deliberate reveal as `sense`.
    public let studyAnswer: String?

    /// The encounter of the kept note's own target in this reading — its dictionary, sense and
    /// standing — never a newer encounter of something else. Nil where the reading met no encounter
    /// of that target, which draws no label rather than a borrowed one.
    public let studySense: SenseNote?

    /// The meaning a reveal shows: the kept note's own answer where the reading is kept under one, so
    /// "Confirm this meaning" confirms exactly what was shown; the encounter's gloss where it is not.
    public var meaning: String? { studyNoteID != nil ? studyAnswer : sense?.gloss }

    /// **What a surface beside "Confirm this meaning" draws: one value describing one note.** Where the
    /// reading is kept, its sense is the note's own encounter carrying the note's own answer, so the
    /// dictionary name, the sense badge and the revealed meaning all describe what confirming reaches.
    /// Where it is not kept, the reading as recorded.
    public var shown: ReadingEntry {
        guard studyNoteID != nil else { return self }
        let sense = studySense.map {
            SenseNote(dictionary: $0.dictionary, block: $0.block, ordinal: $0.ordinal, outOf: $0.outOf,
                      gloss: studyAnswer, chosenBy: $0.chosenBy)
        }
        return copy(sense: sense, repeats: repeats)
    }

    /// How many times this reading was looked up. One card, so at least one.
    public var times: Int { repeats.count + 1 }

    /// Every ledger row this card answers for. **What a removal has to reach** — ADR-0033's rule
    /// that a destructive control reaches exactly what its label counts.
    public var lookupIDs: [Int] { [id] + repeats }

    /// No default, deliberately. Every caller states how good the capture was, because the failure
    /// this replaced was a caller quietly not carrying it.
    public init(
        id: Int, lemma: String, surface: String, sentence: String, sentenceRange: NSRange?,
        place: ReadingPlace, at: Date, result: LookupResult, quality: CaptureQuality?,
        partOfSpeech: String? = nil, sense: SenseNote? = nil, senseAbstention: Abstention? = nil,
        language: String? = nil, repeats: [Int] = [], disposition: LookupDisposition = .kept,
        studyNoteID: UUID? = nil, studyStatus: StudyReadiness? = nil, studyAnswer: String? = nil,
        studySense: SenseNote? = nil, studyObstacle: StudyObstacle? = nil
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
        self.partOfSpeech = partOfSpeech
        self.sense = sense
        self.senseAbstention = senseAbstention
        self.repeats = repeats
        self.language = language
        self.disposition = disposition
        self.studyNoteID = studyNoteID
        self.studyStatus = studyStatus
        self.studyObstacle = studyObstacle
        self.studyAnswer = studyAnswer
        self.studySense = studySense
    }

    /// The same reading, answerable for the lookups it stands for.
    func standing(for repeats: [Int]) -> ReadingEntry { copy(sense: sense, repeats: repeats) }

    private func copy(sense: SenseNote?, repeats: [Int]) -> ReadingEntry {
        ReadingEntry(
            id: id, lemma: lemma, surface: surface, sentence: sentence, sentenceRange: sentenceRange,
            place: place, at: at, result: result, quality: quality, partOfSpeech: partOfSpeech,
            sense: sense, senseAbstention: senseAbstention, language: language, repeats: repeats,
            disposition: disposition, studyNoteID: studyNoteID, studyStatus: studyStatus,
            studyAnswer: studyAnswer, studySense: studySense, studyObstacle: studyObstacle)
    }

    /// The parts of `sentence` a card emphasises. The work is `Lemmatizer.parts` — locating a
    /// lemma's words in a sentence is lemma work, and it lives where the word boundaries and the
    /// tagger already do.
    public var markedRanges: [NSRange] {
        Lemmatizer.parts(of: lemma, surface: surface, in: sentence, at: sentenceRange)
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

/// Which sense of the word the reader met, and — only when they ask for it — what it said.
///
/// **The gloss is carried but never shown by default.** C2 says a review surface that answers the
/// question destroys the retrieval that makes reviewing worth anything, and that rule is intact:
/// revealing a meaning is a deliberate act the reader performs, which is a different thing from
/// reading it by accident on the way past. What the card shows unasked is *which* sense, not what
/// it means.
public struct SenseNote: Equatable, Sendable {
    /// The dictionary that issued it. A sense id means nothing outside the dictionary that issued
    /// it, so naming it is not decoration.
    public let dictionary: String
    /// Which part-of-speech block the sense sits in. Carried because **ordinals restart per
    /// block**: without it, sense 1 of the noun block and sense 1 of the verb block are both "1",
    /// and a card showing `1/12` for each of them claims they are the same sense.
    public let block: Int?
    /// Numbering restarts per block, so this is a label rather than a position — which is why it
    /// is shown beside `outOf`, and never alone.
    public let ordinal: Int?
    public let outOf: Int
    /// The sense's own words, as the ledger snapshotted them. **Local only.**
    public let gloss: String?
    /// A sense the selector proposed is a hypothesis; one the reader tapped is a fact. They must
    /// never merge, and a card draws them differently — which is the only reason this is here.
    public let chosenBy: SenseChoice?

    public init(
        dictionary: String, block: Int? = nil, ordinal: Int?, outOf: Int, gloss: String?,
        chosenBy: SenseChoice?
    ) {
        self.dictionary = dictionary
        self.block = block
        self.ordinal = ordinal
        self.outOf = outOf
        self.gloss = gloss
        self.chosenBy = chosenBy
    }

    /// Whether the card may state this as fact. A sense the model proposed is drawn as the
    /// hypothesis it is; the reader's own tap, and an entry with only one sense, are facts.
    public var isConfirmed: Bool { chosenBy == .reader || chosenBy == .onlySense }

    /// Nothing to reveal is not the same as a meaning withheld, and the card must not offer to
    /// show something it does not have.
    public var canReveal: Bool {
        guard let gloss else { return false }
        return !gloss.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    /// How many lookups this day's cards stand for: each card once, and once more for every time
    /// that reading was met again. What the day's count draws, so it adds up with each card's "×N".
    public var lookups: Int { entries.reduce(0) { $0 + $1.times } }

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
                // cannot swap places between one reading of the drawer and the next. Collapsed
                // after sorting, so a card sits where its most recent reading does.
                entries: collapsed((byDay[day] ?? []).sorted {
                    $0.at == $1.at ? $0.id > $1.id : $0.at > $1.at
                }))
        }
    }

    /// One card per reading rather than per lookup, within a day.
    ///
    /// **Grouped by what the card would draw**, because the complaint is a column of cards the
    /// reader cannot tell apart: the word, the sentence it was read in, and the sense badge. Two
    /// readings that differ in any of those are two cards, and that is the load-bearing half —
    /// the same word in the same sentence resolving to a *different* sense is a disagreement the
    /// reader is entitled to see, not noise to fold away.
    ///
    /// **The reader's own tap wins the group, and nothing is blended.** Measured on the ledger this
    /// came from: all five `delirium` lookups carried sense key `…9356.003`, and one of them also
    /// carried a `chosen_by = reader` row. The card that stands for the group is therefore a real
    /// lookup — the newest confirmed one, or simply the newest — never a record assembled from
    /// several. `chosen_by` never merges (ADR-0014), and this does not merge it: the group is one
    /// sense throughout, so choosing which row fronts it settles nothing about which sense was meant.
    ///
    /// Days are never crossed. Grouping happens inside one day's entries, so a word met on Monday
    /// and again on Tuesday is two cards, under the two dates the reader read it on.
    static func collapsed(_ newestFirst: [ReadingEntry]) -> [ReadingEntry] {
        var order: [Reading] = []
        var members: [Reading: [ReadingEntry]] = [:]
        for entry in newestFirst {
            let key = Reading(entry)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(entry)
        }
        return order.compactMap { key in
            guard let group = members[key], let newest = group.first else { return nil }
            // `group` is newest first, so `first(where:)` is the newest confirmed one.
            let front = group.first { $0.sense?.isConfirmed == true } ?? newest
            return front.standing(for: group.lazy.filter { $0.id != front.id }.map(\.id))
        }
    }

    /// What makes two lookups the same reading: everything a card shows about which word, which
    /// sentence and which sense. Not the sense *key*, which a `ReadingEntry` does not carry —
    /// this is the identity of the card, and two cards a reader cannot tell apart are one card.
    private struct Reading: Hashable {
        let lemma: String
        /// Part of the key for the reason it is part of a study note's: one lemma is two words in
        /// two languages, and they must not become one card.
        let language: String?
        let sentence: String
        let result: LookupResult
        let cue: SentenceCue
        let dictionary: String?
        let block: Int?
        let ordinal: Int?
        let outOf: Int?
        /// **The sense's own words, because the coordinates are not an identity.** A dictionary
        /// name with a block and an ordinal says *where* a sense sits, not which sense it is:
        /// across homographs, or across two revisions of one dictionary, the same coordinates can
        /// carry different meanings. Merging those would hand the reader one card for two senses
        /// and could apply an older confirmation to the wrong one.
        let gloss: String?
        let abstention: String?

        init(_ entry: ReadingEntry) {
            lemma = entry.lemma
            language = entry.language
            sentence = entry.sentence
            // **Both are drawn, so both separate cards.** A not-found reading carries the miss
            // badge and a reading with no captured context draws no sentence at all — collapsing
            // either into its neighbour makes one card stand for two visibly different states.
            result = entry.result
            cue = entry.cue
            dictionary = entry.sense?.dictionary
            block = entry.sense?.block
            ordinal = entry.sense?.ordinal
            outOf = entry.sense?.outOf
            gloss = entry.sense?.gloss
            abstention = entry.senseAbstention?.rawValue
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
