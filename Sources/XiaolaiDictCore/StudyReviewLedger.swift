import Foundation
import ReviewKit

/// **Grading, undo, and the queue.** WI-003's storage half; the arithmetic is `MemoryScheduler`.
///
/// Everything here exists because a review is a write the reader cannot see fail. The three rules that
/// follow from that:
///
/// - **One grade per event id**, so a retry returns the first answer rather than grading twice.
/// - **Compare-and-swap on the card's revision**, so a grade computed against one state cannot land on
///   another. The review window collects a grade seconds after it draws the card.
/// - **The whole thing in one savepoint**, so there is never an event without its card update or a card
///   update without its event. Half a review is worse than none: one of them is invisible.
extension Ledger {
    // MARK: - Cards

    /// The card for a note's question, creating it if the note has none yet.
    ///
    /// **Idempotent, and it does not schedule anything.** A new card is `new` with no memory state: a
    /// target the reader saved is not a review they sat, and inventing a first interval would be
    /// exactly the fabricated grade the specification forbids.
    @discardableResult
    public func card(of noteID: UUID, prompt: StudyCard.Prompt = .meaning,
                     at when: Date) throws -> StudyCard {
        // **Through the reading accessor**, which is the same query written once. Two spellings
        // of "does this note already have this card" is two chances for the creating one to stop
        // finding what the reading one does, and it would then insert a duplicate.
        if let existing = try existingCard(of: noteID, prompt: prompt) { return existing }
        let card = StudyCard(noteID: noteID, prompt: prompt, createdAt: when)
        try run(
            """
            INSERT INTO study_cards (id, note_id, prompt, phase, paused, revision, scheduler_version,
                                     created_at)
            VALUES (?, ?, ?, 'new', 0, 0, ?, ?)
            """,
            bind: [.text(card.id.uuidString), .text(noteID.uuidString), .text(prompt.rawValue),
                   .text(card.schedulerVersion), .real(when.timeIntervalSince1970)]) { _ in }
        return card
    }

    public func card(id: UUID) throws -> StudyCard? {
        try cards(where: "WHERE id = ?", bind: [.text(id.uuidString)]).first
    }

    /// The card for a note's question, or nil. **Reads and never writes** — unlike `card(of:at:)`,
    /// which creates one.
    ///
    /// The distinction is not stylistic. `library(_:)` reached for the creating accessor, so merely
    /// listing the library — or counting it, which lists everything — enrolled a schedule for every
    /// note that had none, which is every note enrolled before schema 10. A read with a side effect
    /// shows up only as rows appearing from nowhere.
    public func existingCard(of noteID: UUID, prompt: StudyCard.Prompt = .meaning) throws -> StudyCard? {
        try cards(where: "WHERE note_id = ? AND prompt = ?",
                  bind: [.text(noteID.uuidString), .text(prompt.rawValue)]).first
    }

    /// Stops a card being asked, or lets it be asked again. **Memory is untouched**: pausing does not
    /// stop elapsed time, and a paused card resumed after a month is a month overdue, honestly.
    /// **The revision moves too.** It is the compare-and-swap that stops a grade computed against
    /// one state landing on another — and pausing, resuming and postponing all change whether the
    /// card may be asked at all. Leaving the revision alone let a presentation drawn *before* the
    /// change pass the guard and grade a card the reader had just put away.
    public func setPaused(_ paused: Bool, ofCard id: UUID) throws {
        try run("UPDATE study_cards SET paused = ?, revision = revision + 1 WHERE id = ?",
                bind: [.integer(paused ? 1 : 0), .text(id.uuidString)]) { _ in }
    }

    /// Puts a card out of the way until a time, without touching its schedule. The reader saying "not
    /// now" is not the reader saying anything about their memory.
    ///
    /// **Not `hide`.** A window hides too, and a name two types share cannot be checked for a
    /// caller by reading the source — `self?.hide()` in the history drawer was enough to report
    /// this as wired when nothing in the app has ever called it (ADR-0038).
    public func postpone(cardID: UUID, until when: Date?) throws {
        try run("UPDATE study_cards SET hidden_until = ?, revision = revision + 1 WHERE id = ?",
                bind: [.optionalReal(when?.timeIntervalSince1970), .text(cardID.uuidString)]) { _ in }
    }

    /// **One projection and one decoder for a card, shared by every query that reads one.**
    /// Two copies of thirteen columns and their decoding meant every storage field had to be
    /// added twice, and a query that forgot would decode the wrong column silently.
    static func cardColumns(_ alias: String) -> String {
        ["id", "note_id", "prompt", "phase", "stability", "difficulty", "last_review",
         "due", "paused", "hidden_until", "revision", "scheduler_version", "created_at"]
            .map { alias.isEmpty ? $0 : "\(alias).\($0)" }
            .joined(separator: ", ")
    }

    /// **A row this schema cannot read is corruption, not an absence.** Skipping it returned a
    /// shorter list that looked exactly like a reader with fewer cards — so a damaged file
    /// silently lost work, and a queue that should have refused went on handing out questions.
    static func card(from row: Ledger.Row) throws -> StudyCard {
        guard let id = UUID(uuidString: try row.text(0)),
              let noteID = UUID(uuidString: try row.text(1)),
              let prompt = StudyCard.Prompt(rawValue: try row.text(2)),
              let phase = SchedulePhase(rawValue: try row.text(3)) else {
            throw LedgerError.corruptRow("study_cards \(try row.text(0))")
        }
        let state = try memoryState(in: row, stability: 4, difficulty: 5, phase: phase,
                                    of: "study_cards \(try row.text(0))")
        return StudyCard(
            id: id, noteID: noteID, prompt: prompt,
            scheduled: ScheduledCard(
                state: state, phase: phase,
                lastReview: row.isNull(6) ? nil : ReviewInstant.decoded(row.real(6)),
                due: row.isNull(7) ? nil : ReviewInstant.decoded(row.real(7))),
            isPaused: row.integer(8) == 1,
            hiddenUntil: row.isNull(9) ? nil : Date(timeIntervalSince1970: row.real(9)),
            revision: row.integer(10), schedulerVersion: try row.text(11),
            createdAt: Date(timeIntervalSince1970: row.real(12)))
    }

    /// **A memory state is both of its numbers or neither, and there exactly when the phase is not
    /// `new`** — the pairing `study_cards`' two CHECKs hold, which nothing in `review_events` does. The
    /// one rule for every decoder that reads a state, cards and both halves of an event alike.
    ///
    /// A row that breaks it is corruption, and says so: reading the difficulty only when the stability
    /// was there let an event whose `before_difficulty` had been written over a `new` card's NULL decode
    /// exactly as the genuine one did, so the replay was handed the same inputs and called the history
    /// whole (WI-8). The other half invents a number: SQLite reads a NULL as 0.
    static func memoryState(in row: Ledger.Row, stability: Int32, difficulty: Int32, phase: SchedulePhase,
                            of record: @autoclosure () throws -> String) throws -> MemoryState? {
        let absent = row.isNull(stability)
        guard absent == row.isNull(difficulty), absent == (phase == .new) else {
            throw LedgerError.corruptRow(try record())
        }
        return absent ? nil : MemoryState(stability: row.real(stability), difficulty: row.real(difficulty))
    }

    private func cards(where clause: String, bind values: [SQLiteValue]) throws -> [StudyCard] {
        var found: [StudyCard] = []
        try run("SELECT \(Self.cardColumns("")) FROM study_cards \(clause)",
                bind: values) { found.append(try Self.card(from: $0)) }
        return found
    }

    /// Every note's card for one prompt, in **one** query.
    ///
    /// A library page ran `existingCard` per row, so drawing two hundred rows was two hundred
    /// statements — on every keystroke of the search field.
    func cards(ofNotes ids: [UUID], prompt: StudyCard.Prompt) throws -> [UUID: StudyCard] {
        guard !ids.isEmpty else { return [:] }
        var found: [UUID: StudyCard] = [:]
        try run("""
            SELECT \(Self.cardColumns("")) FROM study_cards
            WHERE prompt = ?1 AND note_id IN (SELECT value FROM json_each(?2))
            """, bind: [.text(prompt.rawValue),
                        .text(Self.jsonArray(of: ids.map(\.uuidString)))]) { row in
            let card = try Self.card(from: row)
            found[card.noteID] = card
        }
        return found
    }

    // MARK: - The queue

    /// **What a note must be for its card to be asked, in SQL: enrolled *and* ready.**
    ///
    /// Two dimensions, deliberately not one — `readiness(of:)` answers only the second, because active
    /// does not imply gradable and gradable does not imply wanted. Named for the conjunction, after a
    /// version called `readyNotePredicate` was compared against `readiness(of:)` and disagreed about
    /// every archived note. The name was the defect; the test that found it is kept.
    ///
    /// The readiness half is duplicated in Swift, and deliberately: the queue cannot filter after a
    /// `LIMIT`, because that hands back fewer cards than were asked for — a defect this ledger has had
    /// once already. `thequeueAndReadinessAgree` is what stops the two spellings drifting.
    ///
    /// The sense-hash check is **not** here and cannot be: it needs what the dictionary says today.
    /// That is why eligibility is rechecked at presentation, with a live hash, before a card is drawn.
    static let askableNotePredicate = """
        n.enrollment = 'active'
        AND \(Ledger.collectedNotePredicate)
        AND n.confirmed_at IS NOT NULL
        AND \(Ledger.evidencedNotePredicate)
        AND \(Ledger.gradableAnswerPredicate)
        """

    /// **A cue to ask it in.** A reading is required of a dictionary target and not of one the reader
    /// wrote: their own words are the cue, and demanding a lookup for it would make C07 unusable.
    /// One spelling, shared by the queue and by Review's count of what is in the way.
    static let evidencedNotePredicate = """
        (n.target_kind = 'custom'
         OR EXISTS (SELECT 1 FROM study_note_lookups l WHERE l.note_id = n.id))
        """

    /// **An answer that can be graded**: usable, and not the dictionary's whole entry for an entry rung,
    /// which is too broad for "what does this mean here?" (ADR-0030). One spelling, as above.
    static let gradableAnswerPredicate = """
        EXISTS (
            SELECT 1 FROM study_answers a
            WHERE a.note_id = n.id
              AND a.is_usable = 1
              AND NOT (n.target_kind = 'entry' AND a.origin = 'dictionary')
        )
        """

    /// When a card was last **attempted**: its latest unvoided event, graded or practised. Nil when
    /// it has none.
    ///
    /// **Not `last_review`**, which is the schedule's and which practice, being inert, never writes
    /// (ADR-0036). Ordering practice by it left every card of a practised batch exactly as old as
    /// before, so the next batch was the same cards in the same order. A voided event is an attempt
    /// the reader took back, and does not count as one.
    static func latestAttempt(of alias: String) -> String {
        """
        (SELECT MAX(e.reviewed_at) FROM review_events e
         WHERE e.card_id = \(alias).id AND e.voided_at IS NULL)
        """
    }

    /// Cards the reader may practise: ones they have already reviewed at least once.
    ///
    /// **Not the due queue, and deliberately the opposite order** — the least recently attempted
    /// first, which is what someone choosing to practise is usually after, and a card with no live
    /// attempt before any. A card with no memory state is excluded: its first attempt is its first
    /// review, not practice of one.
    public func practisableCards(limit: Int, dictionary: String?) throws -> [StudyCard] {
        guard limit > 0 else { return [] }
        var bind: [SQLiteValue] = []
        var scope = ""
        if let dictionary {
            scope = "AND n.dictionary = ?1"
            bind.append(.text(dictionary))
        }
        bind.append(.integer(limit))
        // **Practice obeys the two rules the queue does.** It offered paused cards and cards the
        // reader had put off until tomorrow — both are answers to "do not ask me this now" — and
        // it could hand back both prompts of one note in a batch, which R08 forbids for the same
        // reason it forbids it of a review: asking the same thing twice with the answer fresh
        // measures the sitting, not the memory.
        //
        // **One ordering, written twice and kept the same**: the per-note pick is which of a
        // note's cards the batch may hold, and it must follow the rule the batch is ordered by.
        return try cardsFromJoin("""
            JOIN study_notes n ON n.id = c.note_id
            WHERE c.stability IS NOT NULL
              AND c.paused = 0
              AND (c.hidden_until IS NULL OR c.hidden_until <= ?\(bind.count + 1))
              AND c.id = (
                  SELECT s.id FROM study_cards s
                  WHERE s.note_id = c.note_id AND s.paused = 0 AND s.stability IS NOT NULL
                    AND (s.hidden_until IS NULL OR s.hidden_until <= ?\(bind.count + 1))
                  ORDER BY \(Self.latestAttempt(of: "s")) NULLS FIRST, s.id
                  LIMIT 1
              )
              AND \(Self.askableNotePredicate)
              \(scope)
            ORDER BY \(Self.latestAttempt(of: "c")) NULLS FIRST, c.id
            LIMIT ?\(bind.count)
            """, bind: bind + [.real(Date.now.timeIntervalSince1970)])
    }

    /// The cards that may be asked now, in the order the specification's §10 gives.
    ///
    /// **The SQL spelling of the queue, and the reference the window is held to — not what it draws
    /// from.** A Review sitting is planned by `SittingPlanner` over `sittingCandidates`, which keeps
    /// this order and replaces only its tie among cards due on one study day with a seeded shuffle
    /// (review-module-plan R6); `thePlannerReproducesTheSqlQueueOrder` holds the two together.
    ///
    /// **Learning and relearning first, then review, each by oldest due time, ties by card id.** A
    /// simple auditable baseline and nothing cleverer: an unverified priority score would be a claim
    /// about this reader's memory that nothing here has measured.
    ///
    /// `dictionary` scopes to one study namespace — switching the primary starts study over, so the
    /// queue must not mix them. Nil means every namespace, which is the library's view rather than a
    /// session's.
    ///
    /// **`newAllowance` rations first introductions, and nothing else** (C08, §10.4). Due work is
    /// work the reader already took on; only cards they have never seen are capped, and the cap is
    /// spent by the introductions already made since `dayStart`. Without it a first sitting is ten
    /// unseen cards, all of which come back tomorrow beside ten more.
    ///
    /// `dayStart` comes from a `StudyDay` frozen into the session, never recomputed here: a reader
    /// who crosses a timezone mid-sitting must not have the boundary move under them, and the
    /// allowance must not be replenished twice in one real day by travelling.
    public func dueCards(at when: Date, limit: Int, dictionary: String?,
                         newAllowance: Int, dayStart: Date) throws -> [StudyCard] {
        guard limit > 0 else { return [] }
        let spent = try introductions(since: dayStart, dictionary: dictionary)
        let remaining = max(0, newAllowance - spent)
        let now = when.timeIntervalSince1970
        var bind: [SQLiteValue] = [.real(now), .real(now)]
        var scope = ""
        if let dictionary {
            scope = "AND n.dictionary = ?"
            bind.append(.text(dictionary))
        }
        bind.append(.integer(limit))
        // **At most one card per note in a batch** (R08). A note can grow a second question —
        // recognise it, produce it — and asking both in one sitting is asking the reader the same
        // thing twice with the answer fresh in mind, which measures the sitting rather than their
        // memory. The sibling is not dropped: it is still due, and the next batch can have it.
        //
        // The winner is the one the ordering picks — a learning card ahead of its review sibling —
        // which is why it is a correlated `LIMIT 1` and not a `GROUP BY`, whose winner is arbitrary.
        let found = try cardsFromJoin("""
            JOIN study_notes n ON n.id = c.note_id
            WHERE c.paused = 0
              AND (c.hidden_until IS NULL OR c.hidden_until <= ?1)
              AND (c.due IS NULL OR c.due <= ?2)
              AND c.id = (
                  SELECT s.id FROM study_cards s
                  WHERE s.note_id = c.note_id AND s.paused = 0
                    AND (s.hidden_until IS NULL OR s.hidden_until <= ?1)
                    AND (s.due IS NULL OR s.due <= ?2)
                  ORDER BY
                      CASE s.phase WHEN 'learning' THEN 0 WHEN 'relearning' THEN 0
                                   WHEN 'new' THEN 2 ELSE 1 END,
                      s.due IS NULL, s.due, s.id
                  LIMIT 1
              )
              AND \(Self.askableNotePredicate)
              \(scope)
            ORDER BY
                CASE c.phase WHEN 'learning' THEN 0 WHEN 'relearning' THEN 0
                             WHEN 'new' THEN 2 ELSE 1 END,
                c.due IS NULL, c.due, c.id
            LIMIT ?\(bind.count)
            """, bind: bind)
        return Self.rationingIntroductions(in: found, to: remaining)
    }

    /// **At most `remaining` cards the reader has never seen, and every other card untouched.**
    ///
    /// Trimmed after the query, and deliberately: expressing "at most N of the rows whose phase
    /// is new" in the same statement means a window function over a set the `LIMIT` has already
    /// cut. The filter-after-`LIMIT` rule is about dropping rows the reader asked for, which
    /// this does not — a new card over the allowance was never theirs to be offered today.
    static func rationingIntroductions(in cards: [StudyCard], to remaining: Int) -> [StudyCard] {
        var kept: [StudyCard] = []
        var introduced = 0
        for card in cards {
            if card.scheduled.phase == .new {
                guard introduced < remaining else { continue }
                introduced += 1
            }
            kept.append(card)
        }
        return kept
    }

    /// **What a Review sitting is planned from — one read: every card of every askable note, and the
    /// introductions made since `dayStart`.** `SittingPlanner` orders, rations and counts it; the
    /// reminder asks it what a later instant would hold (review-module-plan §5.1).
    ///
    /// **Readiness is judged here, in SQL, and nowhere else**: `askableNotePredicate` is enrolled and
    /// ready, and the planner takes it as given. Nothing about an instant is — not due, not hidden,
    /// not paused — because the planner asks those of more than one instant. And there is no `LIMIT`,
    /// so nothing the planner filters was cut before it saw it (ADR-0031's rejected Swift filter was
    /// one *after* a `LIMIT`).
    public func sittingCandidates(dictionary: String?, introducedSince dayStart: Date) throws -> SittingCandidates {
        var bind: [SQLiteValue] = []
        var scope = ""
        if let dictionary {
            scope = "AND n.dictionary = ?1"
            bind.append(.text(dictionary))
        }
        let cards = try cardsFromJoin("""
            JOIN study_notes n ON n.id = c.note_id
            WHERE \(Self.askableNotePredicate)
              \(scope)
            """, bind: bind)
        return SittingCandidates(cards: cards,
                                 introducedToday: try introductions(since: dayStart, dictionary: dictionary))
    }

    /// **What a Selected sitting is planned from: the reader's choice beside the read a Review sitting
    /// is planned from**, and which chosen notes belong to another study dictionary
    /// (review-module-plan §8.2, WI-3b).
    ///
    /// **The queue's read, not a second one scoped to the ids.** The chosen notes' cards are found in
    /// it, so readiness stays `askableNotePredicate` in SQL — one spelling, not a second id-scoped
    /// query that could come to disagree with the first — and the end of the sitting can count what
    /// of the queue is still due from the set its batch was drawn from (ADR-0032). It costs what a
    /// Review sitting's draw costs. The second query names a namespace and judges nothing: a note
    /// saved under another dictionary is left out for a reason with its own remedy.
    public func selectedCandidates(noteIDs: [UUID], dictionary: String?,
                                   introducedSince dayStart: Date) throws -> SelectedCandidates {
        let queue = try sittingCandidates(dictionary: dictionary, introducedSince: dayStart)
        var elsewhere = Set<UUID>()
        if let dictionary, !noteIDs.isEmpty {
            try run("""
                SELECT n.id FROM study_notes n
                WHERE n.id IN (SELECT value FROM json_each(?1)) AND n.dictionary <> ?2
                """, bind: [.text(Self.jsonArray(of: noteIDs.map(\.uuidString))), .text(dictionary)]) { row in
                guard let id = UUID(uuidString: try row.text(0)) else {
                    throw LedgerError.corruptRow("study_notes \(try row.text(0))")
                }
                elsewhere.insert(id)
            }
        }
        return SelectedCandidates(selection: noteIDs, queue: queue, elsewhere: elsewhere)
    }

    private func cardsFromJoin(_ clause: String, bind values: [SQLiteValue]) throws -> [StudyCard] {
        var found: [StudyCard] = []
        try run("SELECT \(Self.cardColumns("c")) FROM study_cards c \(clause)",
                bind: values) { found.append(try Self.card(from: $0)) }
        return found
    }

    /// The notes the queue would ask about, by the SQL rule. **For the agreement test and the commit
    /// check** — a surface wanting to explain *why* a card is not askable wants `readiness(of:)`, which
    /// names the reason.
    func askableNoteIDs() throws -> Set<UUID> {
        var found = Set<UUID>()
        try run("SELECT n.id FROM study_notes n WHERE \(Self.askableNotePredicate)", bind: []) { row in
            // Refused, as `note(from:)` refuses it: a note the check cannot name is not one it may drop.
            guard let id = UUID(uuidString: try row.text(0)) else {
                throw LedgerError.corruptRow("study_notes \(try row.text(0))")
            }
            found.insert(id)
        }
        return found
    }

    /// **Why a card can no longer be asked at `when`, or nil where it can** — the eligibility `grade` and
    /// `practise` recheck at the commit, named (the final closing pass, finding 2). Nil exactly where neither
    /// would refuse it as `notEligible`, because it asks the same three things: the note askable by the
    /// queue's own predicate, the card not paused, the card not put off past the stored instant. Only the
    /// name is added, in the order of the remedy: a card out of study first, then paused, then put off.
    ///
    /// A card that is gone is no longer in study: removing a note takes its cards with it.
    public func departure(ofCard id: UUID, at when: Date) throws -> Departure? {
        let when = ReviewInstant.stored(when)
        guard let card = try card(id: id) else { return .noLongerInStudy }
        var askable = false
        try run("SELECT EXISTS (SELECT 1 FROM study_notes n WHERE n.id = ? AND \(Self.askableNotePredicate))",
                bind: [.text(card.noteID.uuidString)]) { askable = $0.integer(0) == 1 }
        if askable, !card.isPaused, !card.isHidden(at: when) { return nil }
        // Decoded, so a damaged note throws here rather than reading as one out of study.
        guard let note = try notes(where: "WHERE id = ?", bind: [.text(card.noteID.uuidString)]).first,
              note.enrollment == .active else { return .noLongerInStudy }
        if card.isPaused { return .paused }
        if card.isHidden(at: when) { return .putOff }
        return .notReady
    }

    // MARK: - Grading

    /// One deliberate grade, committed with its event or not at all.
    ///
    /// `eventID` is the caller's idempotency key. **A repeat returns the first result**: a review window
    /// that retried after a failure it could not see would otherwise double-grade the card, and the
    /// reader would have answered once.
    ///
    /// `expectedRevision` is what the caller drew. A card that has moved since — graded in another
    /// window, repaired, unpaused — throws rather than overwriting, because the grade it collected was
    /// about the card as it was.
    @discardableResult
    public func grade(cardID: UUID, _ grade: Grade, eventID: UUID, expectedRevision: Int,
                      at when: Date, using scheduler: MemoryScheduler) throws -> ReviewEvent {
        // **Scheduled with the instant that will be stored**, before anything else reads it. The
        // in-memory one can sit a day short of what a replay will see — `ReviewInstant`.
        let when = ReviewInstant.stored(when)
        try execute("SAVEPOINT grade")
        do {
            // Idempotency first, and **before eligibility**: a retry of a review that already
            // committed must return its result even if the card has since become ineligible.
            //
            // **A voided event is not a result to return.** The reader took it back; answering a
            // new attempt with it would report success for a review that never happened and let the
            // surface advance past the card. The id is spent, and a fresh attempt needs a fresh one.
            if let existing = try events(where: "WHERE id = ?", bind: [.text(eventID.uuidString)]).first {
                guard !existing.isVoid else { throw ReviewError.eventAlreadyVoided(eventID) }
                try execute("RELEASE grade")
                return existing
            }
            guard let card = try card(id: cardID) else { throw ReviewError.noSuchCard(cardID) }
            guard card.revision == expectedRevision else {
                throw ReviewError.staleRevision(expected: expectedRevision, found: card.revision)
            }
            // **Rechecked at commit, not only at presentation.** A card can stop being askable while
            // the reader is looking at it — they delete the reading, another window archives it — and
            // the grade would then be about a question that no longer exists.
            //
            // **Hidden too.** A card hidden *after* the draw is already stale, because postponing
            // moves the revision; this refuses one drawn *while* hidden, by a surface that skipped
            // the queue's filter and so holds the revision the card has now.
            guard try askableNoteIDs().contains(card.noteID), !card.isPaused,
                  !card.isHidden(at: when) else {
                throw ReviewError.notEligible(cardID)
            }

            let after = Self.asStored(try scheduler.review(card.scheduled, grade: grade, now: when))
            // **The configuration that scheduled it, not the build's default.** Retention has a
            // column of its own; the cap and the weights travel in the version, so a replay that can
            // rebuild only the default calls another configuration's grade unreplayable rather than a
            // forgery (WI-8).
            let event = ReviewEvent(
                id: eventID, cardID: cardID, grade: grade, reviewedAt: when,
                before: card.scheduled, after: after, schedulerVersion: scheduler.identity,
                retention: scheduler.retention, cardRevision: card.revision)
            try insert(event)
            try write(after, toCard: cardID, revision: card.revision + 1)
            try execute("RELEASE grade")
            return event
        } catch {
            try? execute("ROLLBACK TO grade")
            try? execute("RELEASE grade")
            throw error
        }
    }

    /// Takes back the most recent grade on a card, restoring exactly the state it was in.
    ///
    /// **Voids, never deletes.** The event stays, marked, so a replay still sees what happened and no
    /// count silently changes underneath a figure the reader has already been shown. Only the latest
    /// non-void event can go: undoing an older one would leave every later grade computed from a state
    /// that never existed.
    @discardableResult
    public func undoLatestReview(ofCard cardID: UUID, at when: Date) throws -> ReviewEvent {
        try execute("SAVEPOINT undo")
        do {
            let latest = try events(
                where: "WHERE card_id = ? AND voided_at IS NULL ORDER BY reviewed_at DESC, rowid DESC LIMIT 1",
                bind: [.text(cardID.uuidString)]).first
            guard let latest else { throw ReviewError.nothingToUndo(cardID) }
            guard let card = try card(id: cardID) else { throw ReviewError.noSuchCard(cardID) }
            // **The card must still be in the state this event produced.** Asserted on the state
            // itself rather than on revision arithmetic: an undo is a write and moves the revision
            // too, so `cardRevision + 1` stops holding the moment a second undo is asked for — which
            // is exactly when a reader is walking a mistake backwards. If anything else has written
            // since, restoring `before` would silently discard it.
            guard card.scheduled == latest.after else {
                throw ReviewError.staleRevision(expected: latest.cardRevision + 1, found: card.revision)
            }
            try write(latest.before, toCard: cardID, revision: card.revision + 1)
            try run("UPDATE review_events SET voided_at = ? WHERE id = ?",
                    bind: [.real(when.timeIntervalSince1970), .text(latest.id.uuidString)]) { _ in }
            try execute("RELEASE undo")
            return latest
        } catch {
            try? execute("ROLLBACK TO undo")
            try? execute("RELEASE undo")
            throw error
        }
    }

    /// **An attempt the reader asked for, outside the schedule.** Recorded and inert: no card is
    /// written, no interval moves, and it enters no retention figure.
    ///
    /// It is recorded rather than dropped because it *happened* — it affects the reader's real
    /// memory, and a scheduler that cannot see it has incomplete information. Saying so is better
    /// than inventing a grade to fill the gap, which is what would make the model confidently wrong.
    @discardableResult
    public func practise(cardID: UUID, _ grade: Grade, eventID: UUID, at when: Date) throws -> ReviewEvent {
        // The instant that will be stored, so the attempt returned is the attempt a retry reads.
        let when = ReviewInstant.stored(when)
        // **Idempotency first, and before eligibility**, as `grade` has it. The attempt committed;
        // refusing its retry because the card has since been paused, put off or archived tells the
        // surface the reader's answer was lost when it was not. A voided id is spent, not returned.
        if let existing = try events(where: "WHERE id = ?", bind: [.text(eventID.uuidString)]).first {
            guard !existing.isVoid else { throw ReviewError.eventAlreadyVoided(eventID) }
            return existing
        }
        guard let card = try card(id: cardID) else { throw ReviewError.noSuchCard(cardID) }
        // **A card with no memory state cannot be practised**, because there is nothing to leave
        // unchanged and storing a zero stability beside it would be a claim about the reader's
        // memory. Its first attempt is its first review.
        guard card.scheduled.state != nil else { throw ReviewError.notYetReviewed(cardID) }
        // **Rechecked here, as a grade is.** A note archived, unconfirmed or stripped of its
        // answer while the sitting was on screen still accepted a practice attempt, so an
        // inert-but-recorded event landed against a card nothing should be asking. Hidden is
        // checked directly: practice takes no revision, so nothing else would notice a put-off.
        guard try askableNoteIDs().contains(card.noteID), !card.isPaused,
              !card.isHidden(at: when) else {
            throw ReviewError.notEligible(cardID)
        }
        // `before` and `after` are the same state, which is the record that nothing moved.
        let event = ReviewEvent(
            id: eventID, cardID: cardID, grade: grade, reviewedAt: when,
            before: card.scheduled, after: card.scheduled, retention: 0,
            cardRevision: card.revision, kind: .practice)
        try insert(event)
        return event
    }

    /// Every grade a card has taken, oldest first, **including the voided ones** — a caller that wants
    /// only the live ones says so, and one that is computing retention must exclude them explicitly
    /// rather than by hoping this filtered.
    public func reviews(ofCard cardID: UUID) throws -> [ReviewEvent] {
        try events(where: "WHERE card_id = ? ORDER BY reviewed_at, rowid", bind: [.text(cardID.uuidString)])
    }

    /// **A schedule as the ledger will read it back.** `lastReview` is the graded instant, already
    /// canonical. The due is that instant plus whole days, which is storable until it passes
    /// 2038-01-19 — 2^31 seconds since 1970, where the column's resolution halves again and a due
    /// computed exactly reads back an ulp away. Canonicalised here, at the call site, so the
    /// scheduler and its parity fixture never see it; the value stored is unchanged by it.
    private static func asStored(_ scheduled: ScheduledCard) -> ScheduledCard {
        ScheduledCard(state: scheduled.state, phase: scheduled.phase,
                      lastReview: scheduled.lastReview.map(ReviewInstant.stored),
                      due: scheduled.due.map(ReviewInstant.stored))
    }

    private func write(_ scheduled: ScheduledCard, toCard id: UUID, revision: Int) throws {
        try run(
            """
            UPDATE study_cards SET phase = ?, stability = ?, difficulty = ?, last_review = ?, due = ?,
                                   revision = ?
            WHERE id = ?
            """,
            bind: [.text(scheduled.phase.rawValue),
                   .optionalReal(scheduled.state?.stability), .optionalReal(scheduled.state?.difficulty),
                   .optionalReal(scheduled.lastReview.map(ReviewInstant.encoded)),
                   .optionalReal(scheduled.due.map(ReviewInstant.encoded)),
                   .integer(revision), .text(id.uuidString)]) { _ in }
    }

    private func insert(_ event: ReviewEvent) throws {
        try run(
            """
            INSERT INTO review_events
                (id, card_id, grade, reviewed_at, before_phase, before_stability, before_difficulty,
                 before_last_review, before_due, after_phase, after_stability, after_difficulty,
                 after_due, scheduler_version, retention, card_revision, kind, voided_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """,
            bind: [.text(event.id.uuidString), .text(event.cardID.uuidString),
                   .integer(event.grade.rawValue), .real(ReviewInstant.encoded(event.reviewedAt)),
                   .text(event.before.phase.rawValue),
                   .optionalReal(event.before.state?.stability),
                   .optionalReal(event.before.state?.difficulty),
                   .optionalReal(event.before.lastReview.map(ReviewInstant.encoded)),
                   .optionalReal(event.before.due.map(ReviewInstant.encoded)),
                   .text(event.after.phase.rawValue),
                   .real(event.after.state?.stability ?? 0), .real(event.after.state?.difficulty ?? 0),
                   .real(event.after.due.map(ReviewInstant.encoded) ?? 0),
                   .text(event.schedulerVersion), .real(event.retention),
                   .integer(event.cardRevision), .text(event.kind.rawValue)]) { _ in }
    }

    /// **The one decoder for an event**, shared by the replay (`StudyReplay.swift`), so the two
    /// cannot disagree about a row.
    func events(where clause: String, bind values: [SQLiteValue]) throws -> [ReviewEvent] {
        var found: [ReviewEvent] = []
        try run(
            """
            SELECT id, card_id, grade, reviewed_at, before_phase, before_stability, before_difficulty,
                   before_last_review, before_due, after_phase, after_stability, after_difficulty,
                   after_due, scheduler_version, retention, card_revision, voided_at, kind
            FROM review_events \(clause)
            """,
            bind: values
        ) { row in
            // **A row this schema cannot read is corruption, not an absence**, as for a card. This
            // returned early, so a damaged history read back one review shorter, and an unknown kind
            // read as `graded` — a practice attempt as a schedule change. A ledger migrated by
            // `ALTER TABLE` has no CHECK on `kind`, so nothing upstream rules that out.
            guard let id = UUID(uuidString: try row.text(0)),
                  let cardID = UUID(uuidString: try row.text(1)),
                  let grade = Grade(rawValue: row.integer(2)),
                  let beforePhase = SchedulePhase(rawValue: try row.text(4)),
                  let afterPhase = SchedulePhase(rawValue: try row.text(9)),
                  let kind = ReviewEvent.Kind(rawValue: try row.text(17)) else {
                throw LedgerError.corruptRow("review_events \(try row.text(0))")
            }
            let reviewedAt = ReviewInstant.decoded(row.real(3))
            let record = "review_events \(id.uuidString)"
            // **Both halves by the card's own pairing.** Every event's `after` is a card the
            // scheduler, or practice, left reviewed, so it has a state; its columns are NOT NULL, and
            // an `after_phase` of `new` beside them is the pairing broken.
            guard let afterState = try Self.memoryState(in: row, stability: 10, difficulty: 11,
                                                        phase: afterPhase, of: record) else {
                throw LedgerError.corruptRow(record)
            }
            let before = ScheduledCard(
                state: try Self.memoryState(in: row, stability: 5, difficulty: 6, phase: beforePhase, of: record),
                phase: beforePhase,
                lastReview: row.isNull(7) ? nil : ReviewInstant.decoded(row.real(7)),
                due: row.isNull(8) ? nil : ReviewInstant.decoded(row.real(8)))
            // **`after.lastReview` is derived, not stored — and the derivation is per kind.**
            // `reviewed_at` is the card's new last review for a *grade*, by definition. For
            // practice it is not: practice moves nothing, so the card's last review is still
            // whenever it was last graded. Reconstructing it as the practice timestamp made the
            // stored event disagree with the one `practise` returned — a retry of the same
            // attempt answered differently — and it broke undo, whose guard is that the card is
            // still in the state the latest event produced: a practice attempt reported a stale
            // revision to a reader whose card nothing had touched.
            let after = ScheduledCard(
                state: afterState,
                phase: afterPhase,
                lastReview: kind == .practice ? before.lastReview : reviewedAt,
                due: ReviewInstant.decoded(row.real(12)))
            found.append(ReviewEvent(
                id: id, cardID: cardID, grade: grade, reviewedAt: reviewedAt, before: before,
                after: after, schedulerVersion: try row.text(13), retention: row.real(14),
                cardRevision: row.integer(15), kind: kind,
                voidedAt: row.isNull(16) ? nil : Date(timeIntervalSince1970: row.real(16))))
        }
        return found
    }
}

/// **What a review surface is given, in two halves that cannot be confused.**
///
/// The front and the back are separate types, and the ledger hands them over separately, because
/// "never answer the question unasked" is a rule a view has to keep on every draw. A single value
/// holding both is one `if` away from showing the answer, and that `if` is written by whoever adds the
/// next feature. Here the surface physically does not have the answer until it asks.
public struct ReviewCue: Sendable, Equatable {
    public let card: StudyCard
    /// The word as it was on screen, which is not always its dictionary form — **and for a phrase, the
    /// phrase as the dictionary spells it**: the card asks about *take something into account*, not about
    /// the *took* the reader hovered inside it (ADR-0049).
    public let word: String
    /// What the word's colour is hashed from everywhere else: the lemma. **Not the surface** —
    /// *ran* and *run* are one word, and hashing the captured form gave them different colours
    /// on different surfaces.
    public let lemma: String
    /// The reader's own sentence. **Theirs, not a publisher's** — which is what makes it a cue and
    /// not an answer.
    /// Nil where there is no reading behind the card — a custom one the reader wrote (C07).
    public let sentence: String?
    /// Where the word sits in it, so the card can mark the occurrence the reader actually met.
    public let range: NSRange?
    public let place: ReadingPlace
    /// Nil for the same reason as `sentence`.
    public let readAt: Date?
    /// How the capture went. A card with no usable sentence shows none rather than the word echoed
    /// back into the column and dressed as context.
    public let quality: CaptureQuality?
    /// How precisely the target is known — a keyed sense, an entry, a phrase — so the card can say
    /// what it is asking about without saying what it means.
    public let target: StudyTarget

    public init(card: StudyCard, word: String, lemma: String? = nil, sentence: String?, range: NSRange?,
                place: ReadingPlace, readAt: Date?, quality: CaptureQuality?, target: StudyTarget) {
        self.card = card
        self.word = word
        self.lemma = lemma ?? word
        self.sentence = sentence
        self.range = range
        self.place = place
        self.readAt = readAt
        self.quality = quality
        self.target = target
    }
}

/// The back of the card. Fetched only when the reader asks for it.
public struct ReviewAnswer: Sendable, Equatable {
    public let text: String
    /// Which dictionary said so, where one did. **A card attributes its answer**; the reader's own
    /// words are attributed to nobody, which is the difference `origin` records.
    public let dictionary: String?
    public let origin: StudyAnswer.Origin

    public init(text: String, dictionary: String?, origin: StudyAnswer.Origin) {
        self.text = text
        self.dictionary = dictionary
        self.origin = origin
    }
}

extension Ledger {
    /// The front of a card: everything needed to ask, and nothing that answers.
    ///
    /// Built from the **most recent** reading that evidences the note. A reader who met the word three
    /// times is asked with the sentence they met it in last, which is the one they are likeliest to
    /// recognise; the others stay in the timeline.
    public func cue(forCard id: UUID) throws -> ReviewCue? {
        guard let card = try card(id: id),
              try Self.asking(card),
              let note = try notes(where: "WHERE id = ?", bind: [.text(card.noteID.uuidString)]).first
        else { return nil }
        // **The newest reading, by when it was read.** `lookupIDs` is ordered by when the link
        // was *recorded*, so linking an older reading later put a stale sentence on the card.
        let readings = try lookupIDs(evidencing: card.noteID)
            .compactMap { try reading(ofLookup: $0) }
            .sorted { $0.at > $1.at }
        if let reading = readings.first {
            return ReviewCue(
                card: card, word: Self.word(of: note.target, readAs: reading.surface), lemma: reading.lemma,
                sentence: reading.sentence,
                range: reading.sentenceRange, place: reading.place, readAt: reading.at,
                quality: reading.quality, target: note.target)
        }
        // **A card the reader wrote needs no reading** (C07), and returning nil for one meant the
        // review surface skipped it — every sitting, for ever, with the card still counted as
        // eligible. Its cue is its own words, with no sentence and no place, because there is no
        // reading behind it and inventing one would dress the reader's own note as a citation.
        guard let own = note.target.ownText else { return nil }
        return ReviewCue(
            card: card, word: own, sentence: nil, range: nil,
            place: ReadingPlace(bundleID: nil, name: nil), readAt: nil,
            quality: nil, target: note.target)
    }

    /// **Both halves of a card are written for `.meaning`, and say so.** The front is the word
    /// and the reader's sentence; the back is what it meant there. A production card asks the
    /// opposite question, and serving it these two would have shown the reader a card labelled
    /// one thing and asking another — silently, because the prompt is never read.
    ///
    /// Nothing creates a production card: every caller passes `.meaning`, and `StudyCards` is
    /// where the second prompt is declared ahead of the surface that will ask it. So this
    /// refuses rather than guesses, and the day that surface arrives the refusal is what tells
    /// whoever builds it that these two need their own answers.
    private static func asking(_ card: StudyCard) throws -> Bool {
        guard card.prompt == .meaning else {
            throw LedgerError.unaskablePrompt(card.prompt.rawValue)
        }
        return true
    }

    /// The back of a card. **A separate call on purpose** — see `ReviewCue`.
    public func revealed(cardID: UUID) throws -> ReviewAnswer? {
        guard let card = try card(id: cardID), try Self.asking(card),
              let answer = try answer(of: card.noteID),
              answer.isUsable else { return nil }
        guard let note = try notes(where: "WHERE id = ?",
                                   bind: [.text(card.noteID.uuidString)]).first else { return nil }
        return ReviewAnswer(
            text: answer.text,
            dictionary: answer.origin == .dictionary ? note.target.dictionary : nil,
            origin: answer.origin)
    }

    /// What a surface must say about work it is not showing: how much is askable now, and how much
    /// is only waiting for tomorrow.
    ///
    /// **Counted, not estimated.** "All done today" over a backlog is the one claim a review surface
    /// may never make — and a cap the reader cannot see is the same lie told the other way, since a
    /// reader who saved thirty words and is offered five has no way to tell rationing from loss.
    ///
    /// **Counted by `SittingPlanner`, from the read a sitting is planned from** (WI-2), so the
    /// Library's count, the instrument's and the sitting's are one rule and cannot drift: a second
    /// spelling in SQL is how the end of a batch comes to say "18 more due" over work no batch will
    /// hand out. New cards beyond today's allowance are not due; they are held back.
    public func queueCounts(at when: Date, dictionary: String?,
                            newAllowance: Int, dayStart: Date) throws -> QueueCounts {
        let candidates = try sittingCandidates(dictionary: dictionary, introducedSince: dayStart)
        return SittingPlanner.counts(
            of: candidates.cards, at: when,
            newCardsLeft: SittingPlanner.newCardsLeft(allowance: newAllowance,
                                                      introduced: candidates.introducedToday))
    }
}
