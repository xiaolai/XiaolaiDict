import DictionaryModel
import Foundation

/// **WI-007: what the reader organises, and what the numbers are allowed to claim.**
///
/// Tags, suggestions, the repair queue, and retention. The last is the one with a rule in it: a
/// figure about memory is the easiest thing in this project to overstate, and a denominator nobody
/// states is a denominator nobody can check.
extension Ledger {
    // MARK: - Tags (M03)

    /// Adds a tag. Idempotent, and **changing a tag never touches memory** — an organisation is not
    /// a fact about what the reader knows.
    public func tag(noteID: UUID, _ tag: String) throws {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try run("INSERT OR IGNORE INTO study_tags (note_id, tag) VALUES (?, ?)",
                bind: [.text(noteID.uuidString), .text(trimmed)]) { _ in }
    }

    /// **Normalised the same way `tag` normalises.** Adding " law " stores `law`, so removing
    /// " law " matched nothing and the tag stayed attached — the reader typing what they typed
    /// before could not take it off.
    public func untag(noteID: UUID, _ tag: String) throws {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        try run("DELETE FROM study_tags WHERE note_id = ? AND tag = ?",
                bind: [.text(noteID.uuidString), .text(trimmed)]) { _ in }
    }

    public func tags(of noteID: UUID) throws -> [String] {
        var found: [String] = []
        try run("SELECT tag FROM study_tags WHERE note_id = ? ORDER BY tag",
                bind: [.text(noteID.uuidString)]) { found.append(try $0.text(0)) }
        return found
    }

    /// Every tag the reader has used, with how many notes carry it — the sidebar's own inventory.
    public func allTags() throws -> [(tag: String, count: Int)] {
        var found: [(String, Int)] = []
        try run("SELECT tag, COUNT(*) FROM study_tags GROUP BY tag ORDER BY tag", bind: []) { row in
            found.append((try row.text(0), row.integer(1)))
        }
        return found
    }

    // MARK: - Suggestions (C06)

    /// Words the reader keeps looking up and has not saved.
    ///
    /// **Ranked by distinct reading days, then by distinct sources, then by recency.** A word met on
    /// four days is better evidence of a gap than one met four times in an afternoon, which is one
    /// paragraph read twice.
    ///
    /// **A suggestion is not an enrollment.** Nothing here writes, nothing is graded, and an
    /// unopened suggestion costs the reader nothing — the feature ledger's C06, and the reason this
    /// returns a list rather than doing anything with it.
    public func suggestions(limit: Int, language: String?, studying: Set<ProbeScript>) throws
        -> [Suggestion] {
        guard limit > 0 else { return [] }
        var found: [Suggestion] = []
        try run("""
            SELECT l.lemma, COALESCE(l.language, '') AS lang,
                   -- **Study days, not calendar days.** Lookups at 23:50 and 00:10 are one
                   -- evening, and counting them as two made a single sitting look like the
                   -- repeated reading this ranking exists to find.
                   COUNT(DISTINCT \(Self.studyDayExpression(of: "l.looked_up_at"))) AS days,
                   -- **A lookup with no source is not a place.** COALESCE turned every
                   -- unattributed reading into one shared "source", so a word read twice in
                   -- nothing at all counted as diversity and outranked one read in two real apps.
                   COUNT(DISTINCT l.source_app) AS sources,
                   MAX(l.looked_up_at) AS last,
                   COUNT(*) AS lookups
            FROM lookups l
            WHERE l.result = 'found'
              AND (?1 IS NULL OR l.language = ?1)
              AND (l.script IS NULL OR l.script IN (SELECT value FROM json_each(?2)))
              -- Nothing the reader has already taken up, in any disposition: a word they ignored
              -- must not come back as a suggestion, which is the whole point of ignoring it.
              AND NOT EXISTS (
                  SELECT 1 FROM study_note_lookups nl
                  JOIN lookups other ON other.id = nl.lookup_id
                  -- **Lemma and language, the same key the ignored check below uses.** Matching
                  -- the lemma alone meant saving English *pain* silently suppressed French
                  -- *pain* — a word the reader has never taken up, never offered again, with
                  -- nothing anywhere saying why.
                  WHERE other.lemma = l.lemma
                    AND COALESCE(other.language, '') = COALESCE(l.language, '')
              )
              -- And nothing they have told us they already know.
              AND NOT EXISTS (
                  SELECT 1 FROM study_ignored_lemmas g
                  WHERE g.lemma = l.lemma AND g.language = COALESCE(l.language, '')
              )
            -- **By lemma and language.** `pain` in French and `pain` in English are different
            -- words, and a reader who says they know one has said nothing about the other. It also
            -- makes the key the same one `study_ignored_lemmas` holds, which is what makes
            -- "already know" actually stop offering it — grouped by lemma alone, the two never
            -- matched and the word came straight back.
            GROUP BY l.lemma, lang
            HAVING days >= 2
            ORDER BY days DESC, sources DESC, last DESC
            LIMIT ?3
            """, bind: [.optionalText(language),
                        .text(Self.jsonArray(of: studying.map(\.rawValue))), .integer(limit)]) { row in
            found.append(Suggestion(
                lemma: try row.text(0), language: try row.text(1),
                distinctDays: row.integer(2), distinctSources: row.integer(3),
                lastReadAt: Date(timeIntervalSince1970: row.real(4)), lookups: row.integer(5)))
        }
        return found
    }

    /// A word worth offering, and the evidence for offering it. **The evidence travels**, so the
    /// surface can say *why* rather than presenting a ranking the reader has to trust.
    public struct Suggestion: Sendable, Equatable {
        public let lemma: String
        /// The language it was read in, empty where none was recorded. **Part of its identity**:
        /// it is what `ignoreSuggestion` must be told, or "already know" silences nothing.
        public let language: String
        public let distinctDays: Int
        public let distinctSources: Int
        public let lastReadAt: Date
        public let lookups: Int
    }

    /// The reader says they already know this word: stop offering it.
    ///
    /// **A declaration, not a measurement and not a card.** Inventing a study target for a word
    /// they just said they know would answer "I know this" with a question about it. Reversible,
    /// and it erases nothing — the lookups stay exactly where they were.
    public func ignoreSuggestion(lemma: String, language: String? = nil, at when: Date) throws {
        try run("""
            INSERT OR REPLACE INTO study_ignored_lemmas (lemma, language, ignored_at)
            VALUES (?, ?, ?)
            """, bind: [.text(lemma), .text(language ?? ""),
                        .real(when.timeIntervalSince1970)]) { _ in }
    }

    /// What the reader has set aside, newest first.
    ///
    /// **Setting a word aside enrols nothing** — there is no note, and so no library row to find
    /// it by. Without this list the declaration is invisible and therefore irreversible in
    /// practice, whatever `unignoreSuggestion` can do.
    public func ignoredSuggestions() throws -> [IgnoredLemma] {
        var found: [IgnoredLemma] = []
        try run("""
            SELECT lemma, language, ignored_at FROM study_ignored_lemmas
            ORDER BY ignored_at DESC, lemma
            """, bind: []) { row in
            found.append(IgnoredLemma(lemma: try row.text(0), language: try row.text(1),
                                      at: Date(timeIntervalSince1970: row.real(2))))
        }
        return found
    }

    /// Offers it again. The reader changing their mind is ordinary.
    public func unignoreSuggestion(lemma: String, language: String? = nil) throws {
        try run("DELETE FROM study_ignored_lemmas WHERE lemma = ? AND language = ?",
                bind: [.text(lemma), .text(language ?? "")]) { _ in }
    }

    // MARK: - The repair queue (R09)

    /// Cards the reader keeps failing.
    ///
    /// **Lapses on distinct days**, not lapses: four failures in one sitting is one bad evening,
    /// and four across four days is a card that is not working. The threshold is a parameter
    /// because it is a product guess, not a measurement.
    ///
    /// Nothing is deleted or rescheduled here. The answer is a list, and what to do about it — edit
    /// the cue, pause it, split the sense — is the reader's.
    public func repeatedlyLapsed(atLeast days: Int = Ledger.repeatedLapseDays,
                                 dictionary: String?) throws -> [UUID] {
        var found: [UUID] = []
        var bind: [SQLiteValue] = [.integer(days)]
        var scope = ""
        if let dictionary {
            scope = "AND n.dictionary = ?2"
            bind.append(.text(dictionary))
        }
        try run("""
            SELECT c.id FROM study_cards c
            JOIN study_notes n ON n.id = c.note_id
            WHERE \(Self.lapseDaysExpression(cardAlias: "c")) >= ?1
            \(scope)
            ORDER BY c.id
            """, bind: bind) { row in
            if let id = UUID(uuidString: try row.text(0)) { found.append(id) }
        }
        return found
    }

    /// Distinct days on which this card was failed. **One spelling, used twice** — by the repair
    /// list above and by the library's *Struggling* filter, which must select the same cards or the
    /// reader is shown a list that disagrees with itself.
    ///
    /// The day boundary is `StudyDay.defaultCutoffHour`, shifted before the date is taken, so a
    /// reader failing a card at 01:00 and again at 23:00 has had **one** bad day and not two. The
    /// timezone is SQLite's `localtime`, which is this machine's — a study day carried from another
    /// timezone is not represented here, and would need the offset passed in.
    static func lapseDaysExpression(cardAlias card: String) -> String {
        """
        (SELECT COUNT(DISTINCT \(Self.studyDayExpression(of: "e.reviewed_at")))
         FROM review_events e
         WHERE e.card_id = \(card).id AND e.grade = 1 AND e.voided_at IS NULL
           AND e.kind = 'graded')
        """
    }

    /// **The study day a timestamp falls in, as SQL** — one spelling, for every query that counts
    /// days.
    ///
    /// **Converted to local time first, then shifted.** Subtracting the cutoff in *seconds* before
    /// converting is real-time arithmetic across a local-time boundary, and it is wrong on exactly
    /// the two days a year that are not 24 hours long. Measured in `America/New_York`, 2026:
    /// 04:30 on 8 March came back as the 7th, and 03:30 on 1 November as the 1st — a day early and
    /// a day late. Shifting the wall clock after conversion is right on both, and on ordinary days.
    ///
    /// The same defect, in Swift, was ADR-0037's; this is its second instance and the reason the
    /// expression is shared rather than written out at each call site.
    static func studyDayExpression(of column: String) -> String {
        "date(datetime(\(column), 'unixepoch', 'localtime'), '-\(StudyDay.defaultCutoffHour) hours')"
    }

    /// Distinct days of failure that make a card one the reader is **struggling** with. A product
    /// guess, not a measurement, and named here so the repair list and the library filter cannot
    /// drift apart by one.
    public static let repeatedLapseDays = 4

    // MARK: - What the numbers may claim (U03)

    /// Delayed retention, **with its denominator**.
    ///
    /// The one figure in this product that is easy to overstate and impossible to check afterwards.
    /// What it counts, and what it refuses to:
    ///
    /// - **Only graded events.** Practice is recorded and excluded — it changed no schedule and is
    ///   not a scheduled recall.
    /// - **Only live events.** A review the reader took back did not happen.
    /// - **Only delayed ones.** At least 24 hours since the previous review, so a short-term repeat
    ///   is not counted as remembering something. A first review has no previous one and is an
    ///   introduction, not a recall.
    ///
    /// Everything excluded is *counted* and returned, so a surface can state the denominator rather
    /// than a bare percentage. A percentage with no denominator is not a measurement.
    public func retention(since: Date? = nil, dictionary: String?) throws -> RetentionReport {
        var report = RetentionReport()
        var bind: [SQLiteValue] = [.real(since?.timeIntervalSince1970 ?? 0)]
        var scope = ""
        if let dictionary {
            scope = "AND n.dictionary = ?2"
            bind.append(.text(dictionary))
        }
        try run("""
            SELECT e.kind, e.voided_at, e.before_last_review, e.reviewed_at, e.grade, e.card_id
            FROM review_events e
            JOIN study_cards c ON c.id = e.card_id
            JOIN study_notes n ON n.id = c.note_id
            WHERE e.reviewed_at >= ?1 \(scope)
            """, bind: bind) { row in
            let kind = try row.text(0)
            let voided = !row.isNull(1)
            let hasPrevious = !row.isNull(2)
            let elapsed = hasPrevious ? row.real(3) - row.real(2) : 0
            if kind == ReviewEvent.Kind.practice.rawValue { report.practice += 1; return }
            if voided { report.voided += 1; return }
            guard hasPrevious else { report.introductions += 1; return }
            guard elapsed >= 86_400 else { report.shortTerm += 1; return }
            report.attempts += 1
            if row.integer(4) >= Grade.hard.rawValue { report.successes += 1 }
            if let id = UUID(uuidString: try row.text(5)) { report.cardIDs.insert(id) }
        }
        return report
    }

    /// What a retention figure is allowed to say, and everything it left out.
    public struct RetentionReport: Sendable, Equatable {
        /// Eligible graded attempts — **the denominator**.
        public var attempts = 0
        public var successes = 0
        /// Distinct cards behind those attempts. Ten attempts on one card is not ten cards.
        public var cardIDs: Set<UUID> = []
        /// Excluded, and counted so the exclusion is visible.
        public var practice = 0
        public var voided = 0
        /// A first review: an introduction, not a recall.
        public var introductions = 0
        /// Answered again within a day: a short-term repeat, which is a different metric.
        public var shortTerm = 0

        /// **Nil when there is nothing to divide by.** A rate over zero attempts is not 0% and not
        /// 100%; it is a number nobody has, and returning one would be the whole defect this type
        /// exists to prevent.
        public var rate: Double? {
            attempts > 0 ? Double(successes) / Double(attempts) : nil
        }

        public var cards: Int { cardIDs.count }
    }
}


/// A word the reader said they already know. **Not a card and not a note** — a declaration about
/// a word, which is why it is its own small type and not a `StudyNote` wearing an enrolment.
public struct IgnoredLemma: Sendable, Equatable, Identifiable {
    public let lemma: String
    /// The empty string where no language was recorded, matching how it is stored: SQLite NULL
    /// never equals NULL, so a nullable key column admits duplicates that all look distinct.
    public let language: String
    public let at: Date

    public var id: String { "\(lemma)\u{1F}\(language)" }

    public init(lemma: String, language: String, at: Date) {
        self.lemma = lemma
        self.language = language
        self.at = at
    }
}
