import Foundation

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
        if let existing = try cards(where: "WHERE note_id = ? AND prompt = ?",
                                    bind: [.text(noteID.uuidString), .text(prompt.rawValue)]).first {
            return existing
        }
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

    private func cards(where clause: String, bind values: [SQLiteValue]) throws -> [StudyCard] {
        var found: [StudyCard] = []
        try run(
            """
            SELECT id, note_id, prompt, phase, stability, difficulty, last_review, due, paused,
                   hidden_until, revision, scheduler_version, created_at
            FROM study_cards \(clause)
            """,
            bind: values
        ) { row in
            guard let id = UUID(uuidString: try row.text(0)),
                  let noteID = UUID(uuidString: try row.text(1)),
                  let prompt = StudyCard.Prompt(rawValue: try row.text(2)),
                  let phase = SchedulePhase(rawValue: try row.text(3)) else { return }
            let state: MemoryState? = row.isNull(4)
                ? nil : MemoryState(stability: row.real(4), difficulty: row.real(5))
            found.append(StudyCard(
                id: id, noteID: noteID, prompt: prompt,
                scheduled: ScheduledCard(
                    state: state, phase: phase,
                    lastReview: row.isNull(6) ? nil : Date(timeIntervalSince1970: row.real(6)),
                    due: row.isNull(7) ? nil : Date(timeIntervalSince1970: row.real(7))),
                isPaused: row.integer(8) == 1,
                hiddenUntil: row.isNull(9) ? nil : Date(timeIntervalSince1970: row.real(9)),
                revision: row.integer(10), schedulerVersion: try row.text(11),
                createdAt: Date(timeIntervalSince1970: row.real(12))))
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
        AND n.confirmed_at IS NOT NULL
        -- A reading is required of a dictionary target and not of one the reader wrote: their own
        -- words are the cue, and demanding a lookup for it would make C07 unusable.
        AND (n.target_kind = 'custom'
             OR EXISTS (SELECT 1 FROM study_note_lookups l WHERE l.note_id = n.id))
        AND EXISTS (
            SELECT 1 FROM study_answers a
            WHERE a.note_id = n.id
              AND a.is_usable = 1
              AND NOT (n.target_kind = 'entry' AND a.origin = 'dictionary')
        )
        """

    /// Cards the reader may practise: ones they have already reviewed at least once.
    ///
    /// **Not the due queue, and deliberately the opposite order** — the longest since last seen
    /// first, which is what someone choosing to practise is usually after. A card with no memory
    /// state is excluded: its first attempt is its first review, not practice of one.
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
        return try cardsFromJoin("""
            JOIN study_notes n ON n.id = c.note_id
            WHERE c.stability IS NOT NULL
              AND c.paused = 0
              AND (c.hidden_until IS NULL OR c.hidden_until <= ?\(bind.count + 1))
              AND c.id = (
                  SELECT s.id FROM study_cards s
                  WHERE s.note_id = c.note_id AND s.paused = 0 AND s.stability IS NOT NULL
                    AND (s.hidden_until IS NULL OR s.hidden_until <= ?\(bind.count + 1))
                  ORDER BY s.last_review, s.id
                  LIMIT 1
              )
              AND \(Self.askableNotePredicate)
              \(scope)
            ORDER BY c.last_review, c.id
            LIMIT ?\(bind.count)
            """, bind: bind + [.real(Date.now.timeIntervalSince1970)])
    }

    /// The cards that may be asked now, in the order the specification's §10 gives.
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
        // **Trimmed here, after the query, and only the new ones.** Expressing "at most N of the
        // rows whose phase is new" in the same statement means a window function over a set the
        // `LIMIT` has already cut — and the filter-after-`LIMIT` rule is about dropping rows the
        // reader asked for, which this does not: a new card over the allowance was never theirs to
        // be offered today.
        var kept: [StudyCard] = []
        var introduced = 0
        for card in found {
            if card.scheduled.phase == .new {
                guard introduced < remaining else { continue }
                introduced += 1
            }
            kept.append(card)
        }
        return kept
    }

    private func cardsFromJoin(_ clause: String, bind values: [SQLiteValue]) throws -> [StudyCard] {
        var found: [StudyCard] = []
        try run(
            """
            SELECT c.id, c.note_id, c.prompt, c.phase, c.stability, c.difficulty, c.last_review,
                   c.due, c.paused, c.hidden_until, c.revision, c.scheduler_version, c.created_at
            FROM study_cards c \(clause)
            """,
            bind: values
        ) { row in
            guard let id = UUID(uuidString: try row.text(0)),
                  let noteID = UUID(uuidString: try row.text(1)),
                  let prompt = StudyCard.Prompt(rawValue: try row.text(2)),
                  let phase = SchedulePhase(rawValue: try row.text(3)) else { return }
            let state: MemoryState? = row.isNull(4)
                ? nil : MemoryState(stability: row.real(4), difficulty: row.real(5))
            found.append(StudyCard(
                id: id, noteID: noteID, prompt: prompt,
                scheduled: ScheduledCard(
                    state: state, phase: phase,
                    lastReview: row.isNull(6) ? nil : Date(timeIntervalSince1970: row.real(6)),
                    due: row.isNull(7) ? nil : Date(timeIntervalSince1970: row.real(7))),
                isPaused: row.integer(8) == 1,
                hiddenUntil: row.isNull(9) ? nil : Date(timeIntervalSince1970: row.real(9)),
                revision: row.integer(10), schedulerVersion: try row.text(11),
                createdAt: Date(timeIntervalSince1970: row.real(12))))
        }
        return found
    }

    /// The notes the queue would ask about, by the SQL rule. **For the agreement test and the commit
    /// check** — a surface wanting to explain *why* a card is not askable wants `readiness(of:)`, which
    /// names the reason.
    func askableNoteIDs() throws -> Set<UUID> {
        var found = Set<UUID>()
        try run("SELECT n.id FROM study_notes n WHERE \(Self.askableNotePredicate)", bind: []) { row in
            if let id = UUID(uuidString: try row.text(0)) { found.insert(id) }
        }
        return found
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
            guard try askableNoteIDs().contains(card.noteID), !card.isPaused else {
                throw ReviewError.notEligible(cardID)
            }

            let after = try scheduler.review(card.scheduled, grade: grade, now: when)
            let event = ReviewEvent(
                id: eventID, cardID: cardID, grade: grade, reviewedAt: when,
                before: card.scheduled, after: after, retention: scheduler.retention,
                cardRevision: card.revision)
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
        guard let card = try card(id: cardID) else { throw ReviewError.noSuchCard(cardID) }
        // **A card with no memory state cannot be practised**, because there is nothing to leave
        // unchanged and storing a zero stability beside it would be a claim about the reader's
        // memory. Its first attempt is its first review.
        guard card.scheduled.state != nil else { throw ReviewError.notYetReviewed(cardID) }
        // **Rechecked here, as a grade is.** A note archived, unconfirmed or stripped of its
        // answer while the sitting was on screen still accepted a practice attempt, so an
        // inert-but-recorded event landed against a card nothing should be asking.
        guard try askableNoteIDs().contains(card.noteID), !card.isPaused else {
            throw ReviewError.notEligible(cardID)
        }
        if let existing = try events(where: "WHERE id = ?", bind: [.text(eventID.uuidString)]).first {
            guard !existing.isVoid else { throw ReviewError.eventAlreadyVoided(eventID) }
            return existing
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

    private func write(_ scheduled: ScheduledCard, toCard id: UUID, revision: Int) throws {
        try run(
            """
            UPDATE study_cards SET phase = ?, stability = ?, difficulty = ?, last_review = ?, due = ?,
                                   revision = ?
            WHERE id = ?
            """,
            bind: [.text(scheduled.phase.rawValue),
                   .optionalReal(scheduled.state?.stability), .optionalReal(scheduled.state?.difficulty),
                   .optionalReal(scheduled.lastReview?.timeIntervalSince1970),
                   .optionalReal(scheduled.due?.timeIntervalSince1970),
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
                   .integer(event.grade.rawValue), .real(event.reviewedAt.timeIntervalSince1970),
                   .text(event.before.phase.rawValue),
                   .optionalReal(event.before.state?.stability),
                   .optionalReal(event.before.state?.difficulty),
                   .optionalReal(event.before.lastReview?.timeIntervalSince1970),
                   .optionalReal(event.before.due?.timeIntervalSince1970),
                   .text(event.after.phase.rawValue),
                   .real(event.after.state?.stability ?? 0), .real(event.after.state?.difficulty ?? 0),
                   .real(event.after.due?.timeIntervalSince1970 ?? 0),
                   .text(event.schedulerVersion), .real(event.retention),
                   .integer(event.cardRevision), .text(event.kind.rawValue)]) { _ in }
    }

    private func events(where clause: String, bind values: [SQLiteValue]) throws -> [ReviewEvent] {
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
            guard let id = UUID(uuidString: try row.text(0)),
                  let cardID = UUID(uuidString: try row.text(1)),
                  let grade = Grade(rawValue: row.integer(2)),
                  let beforePhase = SchedulePhase(rawValue: try row.text(4)),
                  let afterPhase = SchedulePhase(rawValue: try row.text(9)) else { return }
            let reviewedAt = Date(timeIntervalSince1970: row.real(3))
            let before = ScheduledCard(
                state: row.isNull(5) ? nil : MemoryState(stability: row.real(5), difficulty: row.real(6)),
                phase: beforePhase,
                lastReview: row.isNull(7) ? nil : Date(timeIntervalSince1970: row.real(7)),
                due: row.isNull(8) ? nil : Date(timeIntervalSince1970: row.real(8)))
            let kind = ReviewEvent.Kind(rawValue: try row.text(17)) ?? .graded
            // **`after.lastReview` is derived, not stored — and the derivation is per kind.**
            // `reviewed_at` is the card's new last review for a *grade*, by definition. For
            // practice it is not: practice moves nothing, so the card's last review is still
            // whenever it was last graded. Reconstructing it as the practice timestamp made the
            // stored event disagree with the one `practise` returned — a retry of the same
            // attempt answered differently — and it broke undo, whose guard is that the card is
            // still in the state the latest event produced: a practice attempt reported a stale
            // revision to a reader whose card nothing had touched.
            let after = ScheduledCard(
                state: MemoryState(stability: row.real(10), difficulty: row.real(11)),
                phase: afterPhase,
                lastReview: kind == .practice ? before.lastReview : reviewedAt,
                due: Date(timeIntervalSince1970: row.real(12)))
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
    /// The word as it was on screen, which is not always its dictionary form.
    public let word: String
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

    public init(card: StudyCard, word: String, sentence: String?, range: NSRange?,
                place: ReadingPlace, readAt: Date?, quality: CaptureQuality?, target: StudyTarget) {
        self.card = card
        self.word = word
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
              let note = try notes(where: "WHERE id = ?", bind: [.text(card.noteID.uuidString)]).first
        else { return nil }
        // **The newest reading, by when it was read.** `lookupIDs` is ordered by when the link
        // was *recorded*, so linking an older reading later put a stale sentence on the card.
        let readings = try lookupIDs(evidencing: card.noteID)
            .compactMap { try reading(ofLookup: $0) }
            .sorted { $0.at > $1.at }
        if let reading = readings.first {
            return ReviewCue(
                card: card, word: reading.surface, sentence: reading.sentence,
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

    /// The back of a card. **A separate call on purpose** — see `ReviewCue`.
    public func revealed(cardID: UUID) throws -> ReviewAnswer? {
        guard let card = try card(id: cardID), let answer = try answer(of: card.noteID),
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
    public func queueCounts(at when: Date, dictionary: String?,
                            newAllowance: Int, dayStart: Date) throws -> QueueCounts {
        let now = when.timeIntervalSince1970
        var bind: [SQLiteValue] = [.real(now), .real(now)]
        var scope = ""
        if let dictionary {
            scope = "AND n.dictionary = ?3"
            bind.append(.text(dictionary))
        }
        // **Counted the same way the queue offers them**, or the end of a batch says "18 more due"
        // over work it will never hand out. New cards beyond today's allowance are not due; they
        // are tomorrow's.
        var due = 0, fresh = 0
        try run("""
            SELECT SUM(CASE WHEN c.phase = 'new' THEN 0 ELSE 1 END),
                   SUM(CASE WHEN c.phase = 'new' THEN 1 ELSE 0 END)
            FROM study_cards c
            JOIN study_notes n ON n.id = c.note_id
            WHERE c.paused = 0
              AND (c.hidden_until IS NULL OR c.hidden_until <= ?1)
              AND (c.due IS NULL OR c.due <= ?2)
              AND \(Self.askableNotePredicate)
              \(scope)
            """, bind: bind) { row in
            due = row.isNull(0) ? 0 : row.integer(0)
            fresh = row.isNull(1) ? 0 : row.integer(1)
        }
        let spent = try introductions(since: dayStart, dictionary: dictionary)
        let allowed = min(fresh, max(0, newAllowance - spent))
        return QueueCounts(due: due + allowed, heldBack: fresh - allowed)
    }
}

/// What the queue has, split by whether the reader may be asked it today.
public struct QueueCounts: Sendable, Equatable {
    /// Askable now, with the allowance already applied.
    public let due: Int
    /// New cards the daily allowance is holding for a later day. **Not a backlog** — nothing is late
    /// — but not nothing either, and a surface that reports zero over eight of them is why a reader
    /// would conclude their saved words went missing.
    public let heldBack: Int

    public init(due: Int, heldBack: Int) {
        self.due = due
        self.heldBack = heldBack
    }
}
