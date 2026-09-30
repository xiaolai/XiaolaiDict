import DictionaryModel
import Foundation

/// **The library: every card the reader has, findable months later.** WI-005's query half.
///
/// The drawer is a window on the last fortnight and caps at 400 rows; that is right for a surface you
/// glance at and wrong for the one place a reader goes to find something they saved in March. This is
/// paginated, searchable, and bounded only by what they ask for.
public struct LibraryQuery: Sendable, Equatable {
    /// Matches the word, the reader's own sentence, and the answer. Empty matches everything.
    public var text: String
    /// One study namespace, or every one. **Nil is the library's view** — study state belongs to one
    /// dictionary, so a reader who switched primaries still has the old collection and must be able
    /// to find it.
    public var dictionary: String?
    /// Which dispositions to show. Nil shows every one, including archived and ignored: this is the
    /// surface where a reader goes looking for something they put away.
    public var enrollment: Set<StudyEnrollment>?
    /// **Off by default, and that is the decision.** The reader's study-scripts setting filters their
    /// *reading* history; applying it unasked to their card collection hides scheduled work, and an
    /// empty library and a filtered one look exactly alike (M10).
    public var scripts: Set<ProbeScript>?
    /// One of the reader's own tags, or every note. **A tag is for finding things again**, so it
    /// belongs in the query rather than being applied to a page afterwards.
    public var tag: String?
    /// Which state the reader is looking at. **Each is its own predicate** — they were once all
    /// `enrollment = 'active'`, so Paused listed unpaused cards and the label lied about what a
    /// bulk action would reach.
    public var state: State?
    /// The instant "due" is judged against. Explicit, because a library opened at midnight and a
    /// test at a fixed date must both be able to say what "now" is.
    public var now: Date
    public var limit: Int
    /// Keyset pagination: the last row of the previous page. **Not an offset** — a card enrolled
    /// while the reader is paging would shift every offset after it and silently skip a row.
    public var after: Cursor?

    public init(text: String = "", dictionary: String? = nil,
                enrollment: Set<StudyEnrollment>? = nil, scripts: Set<ProbeScript>? = nil,
                tag: String? = nil, state: State? = nil, now: Date = .now,
                limit: Int = 50, after: Cursor? = nil) {
        self.text = text
        self.dictionary = dictionary
        self.enrollment = enrollment
        self.scripts = scripts
        self.tag = tag
        self.state = state
        self.now = now
        self.limit = limit
        self.after = after
    }

    /// The states the library can be narrowed to.
    public enum State: Sendable, Equatable, CaseIterable {
        /// Askable now: enrolled, ready, not paused, not hidden, and its due time has passed.
        case due
        /// Put aside by the reader. Says nothing about memory.
        case paused
        /// Enrolled and **not** askable — a proposal to confirm, an answer to write, a reading the
        /// reader deleted. The queue skips these silently; this is where they are visible.
        case needsAttention
        /// Failed on at least `Ledger.repeatedLapseDays` distinct days (R09). **The repair list's
        /// own rule**, not a second reading of it — `Ledger.lapseDaysExpression` is the one copy.
        case struggling
    }

    public struct Cursor: Sendable, Equatable {
        public let createdAt: Date
        public let noteID: UUID

        public init(createdAt: Date, noteID: UUID) {
            self.createdAt = createdAt
            self.noteID = noteID
        }
    }
}

/// One row of the library.
public struct LibraryRow: Sendable, Equatable, Identifiable {
    public let note: StudyNote
    public let card: StudyCard?
    /// The word as the reader met it, from the newest reading that evidences the note.
    public let word: String
    /// Their own sentence, for recognising the row. **Not the answer** — the library lists what the
    /// reader saved, and a list that prints the meanings is a list that teaches nothing.
    public let excerpt: String
    public let readAt: Date?
    /// The script the word is written in, so a row outside the reader's study scripts can be
    /// annotated rather than hidden.
    public let script: ProbeScript?
    public let readiness: StudyReadiness

    public var id: UUID { note.id }

    public init(note: StudyNote, card: StudyCard?, word: String, excerpt: String, readAt: Date?,
                script: ProbeScript?, readiness: StudyReadiness) {
        self.note = note
        self.card = card
        self.word = word
        self.excerpt = excerpt
        self.readAt = readAt
        self.script = script
        self.readiness = readiness
    }

    /// Where this row's cursor is, for asking for the page after it.
    public var cursor: LibraryQuery.Cursor {
        LibraryQuery.Cursor(createdAt: note.createdAt, noteID: note.id)
    }
}

extension Ledger {
    /// One page of the library, newest first.
    ///
    /// **Every filter is in SQL, including readiness's facts.** A page filtered in Swift after a
    /// `LIMIT` is a page short of what was asked for, and a reader paging through a library would see
    /// rows vanish between pages with no explanation.
    public func library(_ query: LibraryQuery) throws -> [LibraryRow] {
        guard query.limit > 0 else { return [] }
        let filter = try Self.libraryFilter(query)
        var bind = filter.bind
        bind.append(.integer(query.limit))

        var rows: [LibraryRow] = []
        try run("""
            SELECT n.id, n.target_kind, n.issuer, n.language, n.dictionary, n.entry_id, n.sense_key,
                   n.sense_key_kind, n.phrase_text, n.enrollment, n.confirmed_at, n.created_at,
                   -- The newest reading that evidences it: the word, the sentence, when, and its
                   -- script. **One subquery decides which reading that is**, and the columns come
                   -- off the join — four copies of the same correlated `ORDER BY … LIMIT 1` are
                   -- four places for the ordering rule to drift, and a row whose word and sentence
                   -- came from different readings would look perfectly ordinary.
                   -- Left joined, because a note whose readings were deleted is still the reader's
                   -- and must be findable in order to be repaired.
                   newest.surface, newest.context, newest.looked_up_at, newest.script,
                   -- Readiness's facts, not its verdict: the rule is decided once, in Swift.
                   EXISTS (SELECT 1 FROM study_note_lookups nl WHERE nl.note_id = n.id),
                   EXISTS (SELECT 1 FROM study_answers a WHERE a.note_id = n.id AND a.is_usable = 1),
                   (SELECT a.origin FROM study_answers a WHERE a.note_id = n.id)
            FROM study_notes n
            LEFT JOIN lookups newest ON newest.id = (
                SELECT l.id FROM study_note_lookups nl JOIN lookups l ON l.id = nl.lookup_id
                 WHERE nl.note_id = n.id ORDER BY l.looked_up_at DESC, l.id DESC LIMIT 1)
            \(filter.whereClause)
            ORDER BY n.created_at DESC, n.id DESC
            LIMIT ?\(bind.count)
            """, bind: bind) { row in
            guard let note = try Self.note(from: row) else { return }
            let facts = StudyReadiness.Facts(
                isConfirmed: note.confirmedAt != nil,
                hasUsableAnswer: row.integer(17) == 1,
                answerIsPublishers: row.optionalText(18) == StudyAnswer.Origin.dictionary.rawValue,
                isEntryRung: { if case .entry = note.target { return true } else { return false } }(),
                hasReading: row.integer(16) == 1,
                // The library cannot ask a dictionary anything, so it never claims a sense moved.
                senseMoved: false,
                needsReading: { if case .custom = note.target { return false } else { return true } }())
            rows.append(LibraryRow(
                note: note, card: try existingCard(of: note.id, prompt: Self.libraryPrompt),
                // **The reading's word, or the target's own.** A custom card needs no lookup
                // (C07), so this was empty for every one of them — a blank row in the library
                // and a blank label in the inspector, for a card the reader had written.
                word: row.optionalText(12) ?? note.target.ownText ?? "",
                excerpt: row.optionalText(13) ?? "",
                readAt: row.isNull(14) ? nil : Date(timeIntervalSince1970: row.real(14)),
                script: row.optionalText(15).flatMap(ProbeScript.init(rawValue:)),
                readiness: StudyReadiness.of(facts)))
        }
        return rows
    }

    /// How many notes the query matches, for a surface that counts its own inventory.
    ///
    /// **Exact, not "50+".** The library is where a reader takes stock; a count that stops at the page
    /// size answers a different question from the one they asked.
    public func libraryCount(_ query: LibraryQuery) throws -> Int {
        var counted = query
        counted.after = nil
        let filter = try Self.libraryFilter(counted)
        var total = 0
        try run("SELECT COUNT(*) FROM study_notes n\n\(filter.whereClause)",
                bind: filter.bind) { total = $0.integer(0) }
        return total
    }

    /// The answers for a page of notes, in **one** query.
    ///
    /// A read per row is two hundred round trips through an actor to draw one list — and the list is
    /// redrawn on every keystroke of the search field.
    public func answers(of noteIDs: [UUID]) throws -> [UUID: StudyAnswer] {
        guard !noteIDs.isEmpty else { return [:] }
        var found: [UUID: StudyAnswer] = [:]
        try run("""
            SELECT note_id, origin, text, dictionary_version, sense_hash FROM study_answers
            WHERE note_id IN (SELECT value FROM json_each(?))
            """, bind: [.text(Self.jsonArray(of: noteIDs.map(\.uuidString)))]) { row in
            guard let id = UUID(uuidString: try row.text(0)),
                  let origin = StudyAnswer.Origin(rawValue: try row.text(1)) else { return }
            found[id] = StudyAnswer(origin: origin, text: try row.text(2),
                                    dictionaryVersion: row.optionalText(3),
                                    senseHash: row.optionalText(4))
        }
        return found
    }

    /// `LIKE`'s own wildcards, escaped, so a reader searching for `100%` searches for `100%`.
    static func escapingWildcards(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

/// **What the library lets the reader change**, and the two deletions it must never confuse.
extension Ledger {
    /// The reader's own words, replacing whatever the card revealed.
    ///
    /// **A revision, not an overwrite of the evidence.** The dictionary's snapshot was what the
    /// publisher said; the reader's answer is theirs. The original stays reachable as the
    /// encounter's `gloss`, which is never edited — so a card can be improved without rewriting
    /// what was true when it was saved.
    public func setReaderAnswer(_ text: String, of noteID: UUID, at when: Date) throws {
        try setAnswer(StudyAnswer(origin: .reader, text: text), of: noteID, at: when)
    }

    /// Pause or resume every card of these notes, in one transaction.
    ///
    /// **Exactly the set given.** A bulk action that half-applied would leave the reader's library in
    /// a state they did not ask for and cannot see, so either all of it lands or none does.
    public func setPaused(_ paused: Bool, ofNotes ids: [UUID]) throws {
        try inOneTransaction("bulkPause") {
            for id in ids {
                try run("""
                    UPDATE study_cards SET paused = ? WHERE note_id = ?
                    """, bind: [.integer(paused ? 1 : 0), .text(id.uuidString)]) { _ in }
            }
        }
    }

    // MARK: - The audit trail (M05)

    /// Everything that happened to one note, **with the two kinds kept apart**.
    ///
    /// A reading is something the reader did with a text; a review is something they did with a
    /// card. One merged sequence invites reading a grade as evidence about the sentence beside it,
    /// so the two are never interleaved — M05's acceptance rule, in the type.
    public func timeline(of noteID: UUID) throws -> NoteTimeline {
        let lookups = try lookupIDs(evidencing: noteID)
        let readings: [ReadingEntry] = try lookups.compactMap { try reading(ofLookup: $0) }
        let ordered = readings.sorted { $0.at > $1.at }
        // **Every card of the note**, and only the ones that exist: `card(of:)` creates, and a
        // surface that reads a history must not bring one into being by looking at it.
        var reviews: [ReviewEvent] = []
        for prompt in StudyCard.Prompt.allCases {
            guard let card = try existingCard(of: noteID, prompt: prompt) else { continue }
            reviews.append(contentsOf: try self.reviews(ofCard: card.id))
        }
        return NoteTimeline(readings: ordered,
                            reviews: reviews.sorted { $0.reviewedAt > $1.reviewedAt })
    }

    // MARK: - Putting a bulk action back (M04)

    /// Which of these notes' cards are paused, **card by card**.
    ///
    /// Keyed by card, because pause is: a note with two prompts can have one of them resting. An
    /// undo that recorded the *note's* state would resume both and call itself faithful.
    /// Whether each card under these notes is paused, **keyed by card and not by note** — a note
    /// may carry several, so note-keying would silently drop all but one.
    ///
    /// The label used to say `ofNotes` while the key was a card's, and both are `UUID`, so the
    /// type system had nothing to say about it. Every caller happened to read only `.values`;
    /// the first one to subscript it got `nil` for an id that was certainly there.
    public func pauseStates(ofCardsUnder ids: [UUID]) throws -> [UUID: Bool] {
        guard !ids.isEmpty else { return [:] }
        var found: [UUID: Bool] = [:]
        try run("""
            SELECT c.id, c.paused FROM study_cards c
            WHERE c.note_id IN (SELECT value FROM json_each(?1))
            """, bind: [.text(Self.jsonArray(of: ids.map(\.uuidString)))]) { row in
            if let id = UUID(uuidString: try row.text(0)) { found[id] = row.integer(1) == 1 }
        }
        return found
    }

    /// Put each card back to the state it was recorded in, in one transaction. Keyed by card,
    /// as `pauseStates(ofCardsUnder:)` returns it.
    ///
    /// **A card that has since been deleted is skipped, not an error**: an undo of a bulk action is
    /// a convenience, and refusing the whole of it because one row is gone would leave the reader
    /// with neither the action nor its reversal.
    public func restorePauseStates(_ states: [UUID: Bool]) throws {
        guard !states.isEmpty else { return }
        try inOneTransaction("restorePause") {
            for (cardID, paused) in states {
                try run("UPDATE study_cards SET paused = ? WHERE id = ?",
                        bind: [.integer(paused ? 1 : 0), .text(cardID.uuidString)]) { _ in }
            }
        }
    }

    /// What each of these notes is enrolled as.
    public func enrollments(ofNotes ids: [UUID]) throws -> [UUID: StudyEnrollment] {
        guard !ids.isEmpty else { return [:] }
        var found: [UUID: StudyEnrollment] = [:]
        try run("""
            SELECT n.id, n.enrollment FROM study_notes n
            WHERE n.id IN (SELECT value FROM json_each(?1))
            """, bind: [.text(Self.jsonArray(of: ids.map(\.uuidString)))]) { row in
            if let id = UUID(uuidString: try row.text(0)),
               let enrollment = StudyEnrollment(rawValue: try row.text(1)) {
                found[id] = enrollment
            }
        }
        return found
    }

    /// Put each note back to the disposition it was recorded in.
    ///
    /// **Not to `.active`.** A candidate the reader never took up, archived by accident, goes back
    /// to being a candidate — an undo that promoted it would have enrolled them in something by
    /// way of undoing something else.
    public func restoreEnrollments(_ dispositions: [UUID: StudyEnrollment]) throws {
        guard !dispositions.isEmpty else { return }
        try inOneTransaction("restoreEnrollment") {
            for (noteID, enrollment) in dispositions {
                try setEnrollment(enrollment, of: noteID)
            }
        }
    }

    /// Set the disposition of several notes at once — archive a selection, put one back.
    public func setEnrollment(_ enrollment: StudyEnrollment, ofNotes ids: [UUID]) throws {
        try inOneTransaction("bulkEnrollment") {
            for id in ids { try setEnrollment(enrollment, of: id) }
        }
    }

    /// **Remove from study.** Takes the note, its answer, its locators and its schedule — and leaves
    /// every lookup exactly where it was.
    ///
    /// This is not "delete my reading". A reader tidying their card collection has said nothing about
    /// their history, and a command that took both would destroy months of it on a misread menu item.
    public func removeFromStudy(_ ids: [UUID]) throws {
        try inOneTransaction("removeFromStudy") {
            for id in ids { try remove(noteID: id) }
        }
    }

    /// **Delete reading data.** Takes the lookups and everything hung off them, and leaves the notes.
    ///
    /// The other half of the pair, and deliberately not its mirror: a note whose readings are gone
    /// keeps its answer and its schedule and becomes `needsRepair`, because the reader still wants
    /// the target — they wanted the *history* gone. Erasing the card too would make "clear my
    /// history" quietly mean "and my study progress".
    public func deleteReading(lookups ids: [Int]) throws {
        try inOneTransaction("deleteReading") {
            for id in ids { try delete(lookup: id) }
        }
    }

    /// What a source-wide deletion would take, counted before it is offered.
    ///
    /// **Previewed, because it cannot be undone.** A reader clearing everything they read in one app
    /// is owed the two numbers that differ: how much history goes, and how many cards it leaves
    /// without a cue.
    public func readingImpact(ofSource bundleID: String) throws -> (lookups: Int, notesLeftWithoutACue: Int) {
        var lookups = 0
        try run("SELECT COUNT(*) FROM lookups WHERE source_app = ?", bind: [.text(bundleID)]) {
            lookups = $0.integer(0)
        }
        var orphaned = 0
        try run("""
            SELECT COUNT(*) FROM study_notes n
            WHERE EXISTS (
                SELECT 1 FROM study_note_lookups nl JOIN lookups l ON l.id = nl.lookup_id
                WHERE nl.note_id = n.id AND l.source_app = ?
            )
            AND NOT EXISTS (
                SELECT 1 FROM study_note_lookups nl JOIN lookups l ON l.id = nl.lookup_id
                WHERE nl.note_id = n.id AND (l.source_app IS NULL OR l.source_app <> ?)
            )
            """, bind: [.text(bundleID), .text(bundleID)]) { orphaned = $0.integer(0) }
        return (lookups, orphaned)
    }

    /// Every lookup recorded in one app, for a reader clearing it out.
    public func lookupIDs(fromSource bundleID: String) throws -> [Int] {
        var found: [Int] = []
        try run("SELECT id FROM lookups WHERE source_app = ? ORDER BY id", bind: [.text(bundleID)]) {
            found.append($0.integer(0))
        }
        return found
    }

    /// A savepoint around a batch. **Named**, so a nested one is nested and not a silent no-op.
    func inOneTransaction(_ name: String, _ body: () throws -> Void) throws {
        try execute("SAVEPOINT \(name)")
        do {
            try body()
            try execute("RELEASE \(name)")
        } catch {
            try? execute("ROLLBACK TO \(name)")
            try? execute("RELEASE \(name)")
            throw error
        }
    }
}


/// One note's history, **in two lists that are never merged** (M05).
public struct NoteTimeline: Sendable, Equatable {
    /// Where the reader met it, newest first.
    public let readings: [ReadingEntry]
    /// What they did with the card, newest first. **Practice and voided attempts are present**:
    /// this is the audit trail, and a trail that hides what was taken back is not one.
    public let reviews: [ReviewEvent]

    public init(readings: [ReadingEntry], reviews: [ReviewEvent]) {
        self.readings = readings
        self.reviews = reviews
    }
}

extension Ledger {
    /// **The prompt the library draws.** A row loads the meaning card, so a state filter that
    /// judged any of a note's cards could admit a row whose own card is in another state
    /// entirely — paused production, unpaused meaning, and a Paused filter showing a row that
    /// says it is not. Named once so the two cannot drift.
    static let libraryPrompt = StudyCard.Prompt.meaning

    /// What narrows a library page, as SQL and its bindings — **the same conditions the count
    /// uses**, which is the whole reason it is not written inside the page query.
    ///
    /// Counting used to run the page query with `limit = Int.max` and take `.count`, so every
    /// keystroke of the search field decoded the entire matching library and ran one card query
    /// per note to produce a number.
    static func libraryFilter(_ query: LibraryQuery) throws -> (whereClause: String, bind: [SQLiteValue]) {
        var conditions: [String] = []
        var bind: [SQLiteValue] = []

        if !query.text.trimmingCharacters(in: .whitespaces).isEmpty {
            // Matched against the word, the reader's own sentence and the answer. The answer is the
            // publisher's text and **stays local** — searching it here is reading a file on this Mac.
            conditions.append("""
                (EXISTS (
                    SELECT 1 FROM study_note_lookups nl JOIN lookups l ON l.id = nl.lookup_id
                    WHERE nl.note_id = n.id
                      AND (l.surface LIKE ?1 ESCAPE '\\' OR l.lemma LIKE ?1 ESCAPE '\\'
                           OR l.context LIKE ?1 ESCAPE '\\')
                 )
                 OR EXISTS (
                    SELECT 1 FROM study_answers a
                    WHERE a.note_id = n.id AND a.text LIKE ?1 ESCAPE '\\'
                 )
                 OR n.phrase_text LIKE ?1 ESCAPE '\\')
                """)
            bind.append(.text("%\(Self.escapingWildcards(query.text))%"))
        }
        if let dictionary = query.dictionary {
            conditions.append("n.dictionary = ?\(bind.count + 1)")
            bind.append(.text(dictionary))
        }
        if let enrollment = query.enrollment {
            conditions.append(
                "n.enrollment IN (SELECT value FROM json_each(?\(bind.count + 1)))")
            bind.append(.text(Self.jsonArray(of: enrollment.map(\.rawValue))))
        }
        if let scripts = query.scripts, !scripts.isEmpty {
            // Offered, never applied unasked. A row written before schema 7 has no script and is
            // **drawn**, for the same reason the drawer draws it: unknown is not excluded.
            // **A note with no reading at all is not a note in a script the reader dropped.**
            // Requiring a lookup excluded every custom card, and every note whose readings were
            // deleted — both of which the rule above says must stay visible, since unknown is
            // not excluded.
            conditions.append("""
                (NOT EXISTS (SELECT 1 FROM study_note_lookups nl WHERE nl.note_id = n.id)
                 OR EXISTS (
                    SELECT 1 FROM study_note_lookups nl JOIN lookups l ON l.id = nl.lookup_id
                    WHERE nl.note_id = n.id
                      AND (l.script IS NULL
                           OR l.script IN (SELECT value FROM json_each(?\(bind.count + 1))))
                 ))
                """)
            bind.append(.text(Self.jsonArray(of: scripts.map(\.rawValue))))
        }
        if let tag = query.tag {
            conditions.append("""
                EXISTS (SELECT 1 FROM study_tags t
                        WHERE t.note_id = n.id AND t.tag = ?\(bind.count + 1))
                """)
            bind.append(.text(tag))
        }
        switch query.state {
        case .due:
            conditions.append("""
                EXISTS (
                    SELECT 1 FROM study_cards c WHERE c.note_id = n.id AND c.prompt = ?0P
                      AND c.paused = 0
                      AND (c.hidden_until IS NULL OR c.hidden_until <= ?\(bind.count + 1))
                      AND (c.due IS NULL OR c.due <= ?\(bind.count + 1))
                )
                AND \(Ledger.askableNotePredicate)
                """)
            bind.append(.real(query.now.timeIntervalSince1970))
        case .paused:
            conditions.append("""
                EXISTS (SELECT 1 FROM study_cards c
                         WHERE c.note_id = n.id AND c.prompt = ?0P AND c.paused = 1)
                """)
        case .needsAttention:
            // Enrolled and not askable. **The same predicate, negated** — not a second opinion
            // about what askable means, which is how two spellings of one rule start to disagree.
            conditions.append("n.enrollment = 'active' AND NOT (\(Ledger.askableNotePredicate))")
        case .struggling:
            // In SQL like every other filter, because a page narrowed in Swift after the `LIMIT`
            // is a short page — and `repeatedlyLapsed` answers card ids, which is a list and not a
            // predicate. The counting rule itself is shared rather than restated.
            conditions.append("""
                EXISTS (
                    SELECT 1 FROM study_cards c WHERE c.note_id = n.id AND c.prompt = ?0P
                      AND \(Ledger.lapseDaysExpression(cardAlias: "c")) >= ?\(bind.count + 1)
                )
                """)
            bind.append(.integer(Ledger.repeatedLapseDays))
        case nil:
            break
        }
        if let after = query.after {
            // Keyset: strictly older, or the same instant with a smaller id. The id breaks the tie so
            // two notes enrolled in the same second cannot both be skipped or both repeat.
            conditions.append(
                "(n.created_at < ?\(bind.count + 1) "
                + "OR (n.created_at = ?\(bind.count + 1) AND n.id < ?\(bind.count + 2)))")
            bind.append(.real(after.createdAt.timeIntervalSince1970))
            bind.append(.text(after.noteID.uuidString))
        }
        var whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: "\n AND ")
        // **Bound last, and only when a clause asked for it.** The state clauses above spell the
        // prompt `?0P` because they cannot know their own position; numbering it first shifted
        // every other placeholder by one — the search clause spells `?1` — and binding it when
        // no clause mentions it gave SQLite a parameter its statement does not declare.
        if whereClause.contains("?0P") {
            bind.append(.text(libraryPrompt.rawValue))
            whereClause = whereClause.replacingOccurrences(of: "?0P", with: "?\(bind.count)")
        }
        return (whereClause, bind)
    }
}
