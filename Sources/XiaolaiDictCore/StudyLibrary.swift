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
                state: State? = nil, now: Date = .now,
                limit: Int = 50, after: Cursor? = nil) {
        self.text = text
        self.dictionary = dictionary
        self.enrollment = enrollment
        self.scripts = scripts
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
        if let enrollment = query.enrollment, !enrollment.isEmpty {
            conditions.append(
                "n.enrollment IN (SELECT value FROM json_each(?\(bind.count + 1)))")
            bind.append(.text(Self.jsonArray(of: enrollment.map(\.rawValue))))
        }
        if let scripts = query.scripts, !scripts.isEmpty {
            // Offered, never applied unasked. A row written before schema 7 has no script and is
            // **drawn**, for the same reason the drawer draws it: unknown is not excluded.
            conditions.append("""
                EXISTS (
                    SELECT 1 FROM study_note_lookups nl JOIN lookups l ON l.id = nl.lookup_id
                    WHERE nl.note_id = n.id
                      AND (l.script IS NULL
                           OR l.script IN (SELECT value FROM json_each(?\(bind.count + 1))))
                )
                """)
            bind.append(.text(Self.jsonArray(of: scripts.map(\.rawValue))))
        }
        switch query.state {
        case .due:
            conditions.append("""
                EXISTS (
                    SELECT 1 FROM study_cards c WHERE c.note_id = n.id AND c.paused = 0
                      AND (c.hidden_until IS NULL OR c.hidden_until <= ?\(bind.count + 1))
                      AND (c.due IS NULL OR c.due <= ?\(bind.count + 1))
                )
                AND \(Ledger.askableNotePredicate)
                """)
            bind.append(.real(query.now.timeIntervalSince1970))
        case .paused:
            conditions.append("EXISTS (SELECT 1 FROM study_cards c WHERE c.note_id = n.id AND c.paused = 1)")
        case .needsAttention:
            // Enrolled and not askable. **The same predicate, negated** — not a second opinion
            // about what askable means, which is how two spellings of one rule start to disagree.
            conditions.append("n.enrollment = 'active' AND NOT (\(Ledger.askableNotePredicate))")
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
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: "\n AND ")
        bind.append(.integer(query.limit))

        var rows: [LibraryRow] = []
        try run("""
            SELECT n.id, n.target_kind, n.issuer, n.language, n.dictionary, n.entry_id, n.sense_key,
                   n.sense_key_kind, n.phrase_text, n.enrollment, n.confirmed_at, n.created_at,
                   -- The newest reading that evidences it: the word, the sentence, when, and its
                   -- script. Left joined, because a note whose readings were deleted is still the
                   -- reader's and must be findable in order to be repaired.
                   (SELECT l.surface FROM study_note_lookups nl JOIN lookups l ON l.id = nl.lookup_id
                     WHERE nl.note_id = n.id ORDER BY l.looked_up_at DESC, l.id DESC LIMIT 1),
                   (SELECT l.context FROM study_note_lookups nl JOIN lookups l ON l.id = nl.lookup_id
                     WHERE nl.note_id = n.id ORDER BY l.looked_up_at DESC, l.id DESC LIMIT 1),
                   (SELECT l.looked_up_at FROM study_note_lookups nl JOIN lookups l ON l.id = nl.lookup_id
                     WHERE nl.note_id = n.id ORDER BY l.looked_up_at DESC, l.id DESC LIMIT 1),
                   (SELECT l.script FROM study_note_lookups nl JOIN lookups l ON l.id = nl.lookup_id
                     WHERE nl.note_id = n.id ORDER BY l.looked_up_at DESC, l.id DESC LIMIT 1),
                   -- Readiness's facts, not its verdict: the rule is decided once, in Swift.
                   EXISTS (SELECT 1 FROM study_note_lookups nl WHERE nl.note_id = n.id),
                   EXISTS (SELECT 1 FROM study_answers a WHERE a.note_id = n.id AND a.is_usable = 1),
                   (SELECT a.origin FROM study_answers a WHERE a.note_id = n.id)
            FROM study_notes n
            \(whereClause)
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
                senseMoved: false)
            rows.append(LibraryRow(
                note: note, card: try existingCard(of: note.id),
                word: row.optionalText(12) ?? "", excerpt: row.optionalText(13) ?? "",
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
        counted.limit = Int.max
        return try library(counted).count
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
