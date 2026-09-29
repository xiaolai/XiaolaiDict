import Foundation

/// **Taking cards out of XiaolaiDict.** WI-007's D03 and D04.
///
/// One rule dominates the design: **a publisher's gloss never leaves this Mac.** The index is not
/// distributed, the ledger's `gloss` is marked local-only, and an export is simply another way out
/// of the machine — the rule does not weaken because the transport changed.
///
/// What that leaves is still a card: the word, the reader's own sentence, their own answer, and
/// their tags. What it does not leave is a dictionary's definition, which is the one part they did
/// not write. A note whose answer is still the dictionary's is exported **labelled incomplete**
/// rather than silently dropped or silently emptied — the reader asked for their collection, and a
/// short file with no explanation is a worse answer than a complete one that says what is missing.
public struct StudyExport: Sendable, Equatable {
    public let rows: [Row]

    public init(rows: [Row]) { self.rows = rows }

    /// One card, as it leaves.
    public struct Row: Sendable, Equatable {
        /// **The note's own id, and the first field.** Anki's text import matches on the first
        /// field, so a second import of the same file updates the note it made last time instead
        /// of making another — which is what "repeatable" means. Anki's own GUIDs are Anki's; this
        /// is ours, and manufacturing one of theirs is how a collection acquires duplicates nobody
        /// can reconcile.
        public let externalID: String
        /// The word or phrase. A word is not a publisher's property; a definition is.
        public let front: String
        /// The reader's own sentence, where one was captured.
        public let sentence: String
        /// **The reader's own words only.** Nil where the card still carries the dictionary's,
        /// which is what makes the row incomplete.
        public let answer: String?
        public let tags: [String]

        /// Whether this row is missing the one thing that cannot be exported for it.
        public var isIncomplete: Bool { answer == nil }

        public init(externalID: String, front: String, sentence: String, answer: String?,
                    tags: [String]) {
            self.externalID = externalID
            self.front = front
            self.sentence = sentence
            self.answer = answer
            self.tags = tags
        }
    }

    /// What the reader is told before anything is written.
    ///
    /// **A preview, because an export is a decision.** How many cards go, how many go without their
    /// meaning, and the field names — so nobody discovers after the fact that half their collection
    /// arrived blank.
    public var preview: Preview {
        Preview(cards: rows.count, incomplete: rows.count { $0.isIncomplete }, fields: Self.fields)
    }

    public struct Preview: Sendable, Equatable {
        public let cards: Int
        /// Cards whose answer is still the dictionary's and so cannot travel.
        public let incomplete: Int
        public let fields: [String]
    }

    /// The columns, in order. The external id is first for the reason its own note gives.
    public static let fields = ["XiaolaiDictID", "Word", "Sentence", "Meaning", "Tags"]

    /// Tab-separated, for Anki's text import.
    ///
    /// **Deterministic**: the same collection exports to the same bytes, so a reader can tell a
    /// changed card from a reshuffled file. Tabs and newlines inside a field are flattened rather
    /// than escaped — the same rule the phrase inventory's own file follows, and for the same
    /// reason: an escape scheme for a case that does not arise is a parser nobody has tested.
    public func tabSeparated() -> String {
        var lines = ["#separator:tab", "#html:false", "#columns:" + Self.fields.joined(separator: "\t")]
        for row in rows.sorted(by: { $0.externalID < $1.externalID }) {
            lines.append([
                row.externalID, Self.flattened(row.front), Self.flattened(row.sentence),
                // **The label travels with the row**, so an incomplete card is visibly incomplete
                // in Anki rather than a card with a blank back that looks like a mistake.
                row.answer.map(Self.flattened) ?? Self.incompleteMarker,
                row.tags.map(Self.flattened).joined(separator: " "),
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    /// What a row says where its meaning could not travel. Not empty: a blank back reads as a
    /// defect, and this reads as what it is.
    public static let incompleteMarker = "(no meaning of your own yet — add one in XiaolaiDict)"

    static func flattened(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

extension Ledger {
    /// Everything exportable in one study namespace.
    ///
    /// **Built from what may leave, not filtered afterwards.** A row is assembled from the reader's
    /// own material; a dictionary's answer is never read into it and then removed, because a
    /// pipeline that carries the gloss as far as the last step is one step from shipping it.
    public func export(dictionary: String?) throws -> StudyExport {
        var bind: [SQLiteValue] = []
        var scope = ""
        if let dictionary {
            scope = "WHERE n.dictionary = ?1"
            bind.append(.text(dictionary))
        }
        var rows: [StudyExport.Row] = []
        try run("""
            SELECT n.id, n.target_kind, n.entry_id, n.phrase_text,
                   -- The reader's own answer, and **only** theirs: the origin is in the predicate,
                   -- not in a branch further down where it could be forgotten.
                   (SELECT a.text FROM study_answers a
                     WHERE a.note_id = n.id AND a.origin = 'reader' AND a.is_usable = 1),
                   (SELECT l.surface FROM study_note_lookups nl JOIN lookups l ON l.id = nl.lookup_id
                     WHERE nl.note_id = n.id ORDER BY l.looked_up_at DESC, l.id DESC LIMIT 1),
                   (SELECT l.context FROM study_note_lookups nl JOIN lookups l ON l.id = nl.lookup_id
                     WHERE nl.note_id = n.id ORDER BY l.looked_up_at DESC, l.id DESC LIMIT 1)
            FROM study_notes n
            \(scope)
            ORDER BY n.id
            """, bind: bind) { row in
            let kind = try row.text(1)
            // The word: the reader's own text for a phrase or a card they wrote, the word they
            // looked up otherwise. A word is not a publisher's property; a definition is.
            let front = (kind == StudyTarget.Kind.phrase.rawValue
                         || kind == StudyTarget.Kind.custom.rawValue)
                ? try row.text(3) : (row.optionalText(5) ?? "")
            guard !front.isEmpty else { return }
            var tags: [String] = []
            if let id = UUID(uuidString: try row.text(0)) { tags = try self.tags(of: id) }
            rows.append(StudyExport.Row(
                externalID: try row.text(0), front: front, sentence: row.optionalText(6) ?? "",
                answer: row.optionalText(4), tags: tags))
        }
        return StudyExport(rows: rows)
    }
}
