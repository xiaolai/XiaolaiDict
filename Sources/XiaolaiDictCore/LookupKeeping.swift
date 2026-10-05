import DictionaryModel
import Foundation

public enum LookupKeepPolicy: String, Sendable, CaseIterable { case automatic, manual }
public enum LookupDisposition: String, Sendable, Codable { case kept, discarded }
public enum StudyKeepSource: String, Sendable { case legacy, automatic, manual }

public struct LookupKeepPolicyStore {
    public static let key = "lookupKeepPolicy"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> LookupKeepPolicy {
        defaults.string(forKey: Self.key).flatMap(LookupKeepPolicy.init(rawValue:)) ?? .automatic
    }
    public func save(_ policy: LookupKeepPolicy) { defaults.set(policy.rawValue, forKey: Self.key) }
}

public struct DispositionResult: Equatable, Sendable, Codable {
    public let operation: UUID
    public let affected: Int
    public let skipped: Int
}
public struct ReadingArchiveCursor: Equatable, Sendable {
    public let at: Date
    public let id: Int
    public init(at: Date, id: Int) { self.at = at; self.id = id }
}
public struct ReadingArchiveQuery: Sendable {
    public var text: String
    public var disposition: LookupDisposition
    public var scripts: Set<ProbeScript>?
    public var after: ReadingArchiveCursor?
    /// One lookup, asked under every other filter here: whether *it* belongs to this pane. Asked by
    /// id, not by placing a cursor beside it, because a cursor one id or one instant past a row
    /// overflows at the largest id and rounds back onto the row at some instants.
    public var only: Int?
    public var limit: Int
    public init(text: String = "", disposition: LookupDisposition = .kept,
                scripts: Set<ProbeScript>? = nil, after: ReadingArchiveCursor? = nil, limit: Int = 100) {
        self.text = text; self.disposition = disposition; self.scripts = scripts
        self.after = after; self.limit = limit
    }
}

/// **Which lookup a row id named when it was read**: the id, and the instant stored with the row.
///
/// Lookup ids are SQLite rowids, and a rowid is given again once the largest is deleted — so an id
/// alone, held across a deletion, names whichever reading SQLite recorded next (audit-fix round 2). The
/// instant is the lookup's own and is never rewritten; two readings that share both were recorded at
/// one instant under one id, which no deletion and no reuse can produce. Built only from a row — by
/// `Ledger.identity(ofLookup:)` or `ReadingEntry.identity` — through the one conversion every reading
/// uses, so an identity read twice from one row compares equal, bit for bit.
public struct LookupIdentity: Hashable, Sendable {
    public let id: Int
    public let lookedUpAt: Date

    /// `lookedUpAt` must be `Date(timeIntervalSince1970:)` of the stored column, as every reading builds it.
    init(id: Int, lookedUpAt: Date) {
        self.id = id
        self.lookedUpAt = lookedUpAt
    }
}

extension ReadingEntry {
    /// This reading's row, as it was read: `at` is the stored instant through the same conversion.
    public var identity: LookupIdentity { LookupIdentity(id: id, lookedUpAt: at) }
}

extension Ledger {
    /// The lookup `id` names now, or nil where no row has that id.
    public func identity(ofLookup id: Int) throws -> LookupIdentity? {
        var found: LookupIdentity?
        try run("SELECT looked_up_at FROM lookups WHERE id = ?", bind: [.integer(id)]) {
            found = LookupIdentity(id: id, lookedUpAt: Date(timeIntervalSince1970: $0.real(0)))
        }
        return found
    }

    /// Runs `body` **only while `identity` still names its row, in one transaction with the check** —
    /// so neither a read nor a write can land on a reading recorded under a reused id. A row that is
    /// gone, or is someone else's now, is `LedgerError.lookupGone`, and `body` does not run.
    public func holding<T>(_ identity: LookupIdentity, _ body: () throws -> T) throws -> T {
        var result: T?
        try inOneTransaction("holdingLookup") {
            guard try self.identity(ofLookup: identity.id) == identity else {
                throw LedgerError.lookupGone(identity.id)
            }
            result = try body()
        }
        guard let result else { throw LedgerError.lookupGone(identity.id) }
        return result
    }
}

extension Ledger {
    static let keepingSchema = """
        ALTER TABLE lookups ADD COLUMN disposition TEXT NOT NULL DEFAULT 'kept'
            CHECK (disposition IN ('kept', 'discarded'));
        ALTER TABLE lookups ADD COLUMN primary_dictionary TEXT;
        ALTER TABLE lookups ADD COLUMN keep_policy TEXT NOT NULL DEFAULT 'manual' CHECK (keep_policy IN ('automatic','manual'));
        ALTER TABLE lookups ADD COLUMN disposition_revision INTEGER NOT NULL DEFAULT 0 CHECK (disposition_revision >= 0);
        CREATE INDEX lookups_archive ON lookups(disposition, looked_up_at DESC, id DESC);
        CREATE TABLE lookup_disposition_operations (
            id TEXT PRIMARY KEY, affected INTEGER NOT NULL, skipped INTEGER NOT NULL,
            undo_affected INTEGER, undo_skipped INTEGER
        );
        CREATE TABLE lookup_disposition_receipts (
            operation TEXT NOT NULL REFERENCES lookup_disposition_operations(id) ON DELETE CASCADE,
            lookup_id INTEGER NOT NULL REFERENCES lookups(id) ON DELETE CASCADE,
            previous TEXT NOT NULL CHECK (previous IN ('kept','discarded')),
            previous_revision INTEGER NOT NULL, committed_revision INTEGER NOT NULL,
            PRIMARY KEY (operation,lookup_id)
        );
        CREATE TABLE keep_backfill (version INTEGER PRIMARY KEY, cursor INTEGER NOT NULL, upper_id INTEGER NOT NULL);
        INSERT INTO keep_backfill SELECT 1, 0, COALESCE(MAX(id),0) FROM lookups;
        """

    /// **The half of schema 13 that is study's**, applied only where the study tables exist. It reads
    /// `study_notes` and hangs triggers on it, so run unconditionally it made a ledger whose study tables
    /// were gone fail its whole upgrade — and a broken study system took the lookup path with it
    /// (ADR-0034, ADR-0044).
    static let studyKeepingSchema = """
        CREATE TABLE study_keep_metadata (
            note_id TEXT PRIMARY KEY REFERENCES study_notes(id) ON DELETE CASCADE,
            source TEXT NOT NULL CHECK (source IN ('legacy','automatic','manual')),
            explicit_keep INTEGER NOT NULL CHECK (explicit_keep IN (0,1)),
            creation_lookup INTEGER REFERENCES lookups(id) ON DELETE SET NULL
        );
        INSERT INTO study_keep_metadata SELECT id, 'legacy', 1, NULL FROM study_notes;
        CREATE TRIGGER study_keep_new_note AFTER INSERT ON study_notes BEGIN
            INSERT INTO study_keep_metadata VALUES (NEW.id, 'manual', 1, NULL);
        END;
        CREATE TABLE removed_keep_targets AS SELECT target_kind,issuer,language,dictionary,entry_id,sense_key,sense_key_kind,phrase_text FROM study_notes WHERE 0;
        CREATE TRIGGER remember_removed_target BEFORE DELETE ON study_notes BEGIN
            INSERT INTO removed_keep_targets VALUES (OLD.target_kind,OLD.issuer,OLD.language,OLD.dictionary,OLD.entry_id,OLD.sense_key,OLD.sense_key_kind,OLD.phrase_text);
        END;
        """

    /// Explicit/reviewed work survives encounter discard; untouched automatic drafts need kept support.
    static let collectedNotePredicate = """
        (EXISTS (SELECT 1 FROM study_keep_metadata km WHERE km.note_id = n.id AND km.explicit_keep = 1)
         OR EXISTS (SELECT 1 FROM review_events re JOIN study_cards rc ON rc.id = re.card_id WHERE rc.note_id = n.id)
         OR EXISTS (SELECT 1 FROM study_note_lookups kl JOIN lookups k ON k.id = kl.lookup_id
                    WHERE kl.note_id = n.id AND k.disposition = 'kept'))
        """

    public func disposition(ofLookup id: Int) throws -> LookupDisposition? {
        var value: LookupDisposition?
        try run("SELECT disposition FROM lookups WHERE id = ?", bind: [.integer(id)]) {
            guard let parsed = LookupDisposition(rawValue: try $0.text(0)) else { throw LedgerError.corruptRow("disposition") }
            value = parsed
        }
        return value
    }

    public func changeDisposition(_ value: LookupDisposition, lookups ids: [Int], operation: UUID) throws -> DispositionResult {
        if let previous = try dispositionResult(operation: operation, undo: false) { return previous }
        var affected = 0
        let unique = Set(ids)
        try inOneTransaction("lookupDisposition") {
            // The operation row precedes its FK receipts, inside the same savepoint.
            try run("INSERT INTO lookup_disposition_operations(id,affected,skipped) VALUES (?,0,0)", bind: [.text(operation.uuidString)]) { _ in }
            for id in unique.sorted() {
                var before: (String,Int)?
                try run("SELECT disposition, disposition_revision FROM lookups WHERE id = ?", bind: [.integer(id)]) { before = (try $0.text(0), $0.integer(1)) }
                guard let before, before.0 != value.rawValue else { continue }
                try run("UPDATE lookups SET disposition = ?, disposition_revision = disposition_revision + 1 WHERE id = ?",
                        bind: [.text(value.rawValue), .integer(id)]) { _ in }
                try run("INSERT INTO lookup_disposition_receipts VALUES (?,?,?,?,?)",
                        bind: [.text(operation.uuidString),.integer(id),.text(before.0),.integer(before.1),.integer(before.1+1)]) { _ in }
                affected += 1
            }
            try run("UPDATE lookup_disposition_operations SET affected = ?, skipped = ? WHERE id = ?",
                    bind: [.integer(affected),.integer(unique.count-affected),.text(operation.uuidString)]) { _ in }
        }
        return DispositionResult(operation: operation, affected: affected, skipped: unique.count-affected)
    }

    public func undoDisposition(operation: UUID) throws -> DispositionResult {
        if let prior = try dispositionResult(operation: operation, undo: true) { return prior }
        var affected = 0, skipped = 0
        try inOneTransaction("undoLookupDisposition") {
            var receipts: [(Int,String,Int)] = []
            try run("SELECT lookup_id,previous,committed_revision FROM lookup_disposition_receipts WHERE operation = ?",
                    bind: [.text(operation.uuidString)]) { receipts.append(($0.integer(0),try $0.text(1),$0.integer(2))) }
            let original = try dispositionResult(operation: operation, undo: false)?.affected ?? 0
            skipped = max(0, original - receipts.count)
            for (id, previous, revision) in receipts {
                var current: Int?
                try run("SELECT disposition_revision FROM lookups WHERE id = ?", bind: [.integer(id)]) { current = $0.integer(0) }
                guard current == revision else { skipped += 1; continue }
                try run("UPDATE lookups SET disposition = ?, disposition_revision = disposition_revision + 1 WHERE id = ? AND disposition_revision = ?",
                        bind: [.text(previous),.integer(id),.integer(revision)]) { _ in }
                affected += 1
            }
            try run("UPDATE lookup_disposition_operations SET undo_affected = ?, undo_skipped = ? WHERE id = ?",
                    bind: [.integer(affected),.integer(skipped),.text(operation.uuidString)]) { _ in }
        }
        return DispositionResult(operation: operation, affected: affected, skipped: skipped)
    }
    private func dispositionResult(operation: UUID, undo: Bool) throws -> DispositionResult? {
        var result: DispositionResult?
        let columns = undo ? "undo_affected, undo_skipped" : "affected, skipped"
        try run("SELECT \(columns) FROM lookup_disposition_operations WHERE id = ? AND \(undo ? "undo_affected" : "affected") IS NOT NULL", bind: [.text(operation.uuidString)]) {
            result = DispositionResult(operation: operation, affected: $0.integer(0), skipped: $0.integer(1))
        }
        return result
    }

    public func explicitlyKeep(noteID: UUID) throws {
        try run("UPDATE study_keep_metadata SET explicit_keep = 1 WHERE note_id = ?", bind: [.text(noteID.uuidString)]) { _ in }
    }

    /// A deferred automatic operation never changes the disposition or an existing card's standing.
    @discardableResult
    public func keep(_ target: StudyTarget, issuer: KeyIssuer, language: String,
                     chosenBy: SenseChoice?, answer: StudyAnswer?, lookupID: Int, at when: Date,
                     source: StudyKeepSource, draft: Bool = false) throws -> StudyNote? {
        guard try disposition(ofLookup: lookupID) == .kept else { return nil }
        if source == .legacy {
            let fields = Self.columns(of: target); var removed = false
            try run("SELECT EXISTS (SELECT 1 FROM removed_keep_targets WHERE target_kind = ? AND issuer = ? AND language = ? AND dictionary = ? AND entry_id = ? AND sense_key = ? AND sense_key_kind = ? AND phrase_text = ?)",
                    bind: [.text(target.kind.rawValue),.text(issuer.rawValue),.text(language),.text(target.dictionary),.text(fields.entryID),.text(fields.senseKey),.text(fields.senseKeyKind),.text(fields.phraseText)]) { removed = $0.integer(0) == 1 }
            if removed { return nil }
        }
        if source == .automatic {
            var primary: String?
            try run("SELECT primary_dictionary FROM lookups WHERE id = ?",bind:[.integer(lookupID)]) { primary = $0.optionalText(0) }
            if let primary, primary != target.dictionary { return nil }
        }
        let old = try note(for: target, issuer: issuer, language: language)
        var result: StudyNote?
        try inOneTransaction("keepLookupTarget") {
            let note = try enroll(target, issuer: issuer, language: language, chosenBy: draft ? .model : chosenBy,
                                  answer: answer, lookupID: lookupID, at: when, explicitly: source == .manual)
            if old == nil {
                try run("UPDATE study_keep_metadata SET source = ?, explicit_keep = ?, creation_lookup = ? WHERE note_id = ?",
                        bind: [.text(source.rawValue),.integer(source == .manual ? 1 : 0),.integer(lookupID),.text(note.id.uuidString)]) { _ in }
            }
            if source != .legacy {
                // Correction changes this encounter's association only. Previous notes/progress remain.
                // A backfilled draft is `legacy` and as untouched as an automatic one; a note that
                // predates schema 13 is `legacy` too, but explicit, so the first condition keeps it.
                try run("DELETE FROM study_note_lookups WHERE lookup_id = ? AND note_id <> ? AND note_id IN (SELECT note_id FROM study_keep_metadata WHERE explicit_keep = 0 AND source IN ('automatic','legacy') AND NOT EXISTS (SELECT 1 FROM review_events r JOIN study_cards c ON c.id = r.card_id WHERE c.note_id = study_keep_metadata.note_id) AND note_id IN (SELECT id FROM study_notes WHERE dictionary = ?))",
                        bind: [.integer(lookupID),.text(note.id.uuidString),.text(target.dictionary)]) { _ in }
            }
            if chosenBy == .reader, !draft { try confirm(noteID: note.id, at: when) }
            result = try self.note(for: target, issuer: issuer, language: language)
        }
        return result
    }

    static func archiveFilter(_ query: ReadingArchiveQuery, paging: Bool) -> (String,[SQLiteValue]) {
        var terms = ["l.disposition = ?1"]
        var bind: [SQLiteValue] = [.text(query.disposition.rawValue)]
        if !query.text.isEmpty {
            let escaped = query.text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            bind.append(.text("%"+escaped+"%"))
            terms.append("(l.lemma LIKE ?\(bind.count) ESCAPE '\\' OR l.surface LIKE ?\(bind.count) ESCAPE '\\' OR l.context LIKE ?\(bind.count) ESCAPE '\\')")
        }
        if let scripts = query.scripts {
            bind.append(.text(jsonArray(of: scripts.map(\.rawValue))))
            terms.append("(l.script IS NULL OR l.script IN (SELECT value FROM json_each(?\(bind.count))))")
        }
        if let only = query.only {
            bind.append(.integer(only))
            terms.append("l.id = ?\(bind.count)")
        }
        if paging, let cursor = query.after {
            bind.append(.real(cursor.at.timeIntervalSince1970)); let time = bind.count
            bind.append(.integer(cursor.id))
            terms.append("(l.looked_up_at < ?\(time) OR (l.looked_up_at = ?\(time) AND l.id < ?\(bind.count)))")
        }
        return ("WHERE " + terms.joined(separator: " AND "),bind)
    }
    public func readingArchive(_ query: ReadingArchiveQuery) throws -> [ReadingEntry] {
        guard query.limit >= 0 else { throw LedgerError.negativeLimit(query.limit) }
        var (filter,bind) = Self.archiveFilter(query,paging:true)
        bind.append(.integer(query.limit)); filter += " ORDER BY l.looked_up_at DESC,l.id DESC LIMIT ?\(bind.count)"
        var rows: [ReadingEntry] = []; let tagging = Lemmatizer.Pass()
        try run("\(try availableReadingProjection()) \(filter)",bind:bind) { rows.append(try Self.reading(from:$0,tagging:tagging)) }
        return rows
    }
    public func readingArchiveCount(_ query: ReadingArchiveQuery) throws -> Int {
        let (filter,bind) = Self.archiveFilter(query,paging:false); var count = 0
        try run("SELECT COUNT(*) FROM lookups l \(filter)",bind:bind) { count = $0.integer(0) }
        return count
    }

    /// Bounded import of recorded evidence only: no dictionary/model reads and no newly confirmed cards.
    @discardableResult
    public func backfillKeptDrafts(limit: Int = 50) throws -> Int {
        guard limit > 0 else { return 0 }
        var cursor = 0, upper = 0
        try run("SELECT cursor,upper_id FROM keep_backfill WHERE version = 1",bind:[]) { cursor = $0.integer(0); upper = $0.integer(1) }
        var ids: [Int] = []
        try run("SELECT id FROM lookups WHERE id > ? AND id <= ? ORDER BY id LIMIT ?",bind:[.integer(cursor),.integer(upper),.integer(limit)]) { ids.append($0.integer(0)) }
        try inOneTransaction("keepLegacyDrafts") {
            for id in ids {
                guard try disposition(ofLookup:id) == .kept, let reading = try reading(ofLookup:id),
                      let evidence = try preferredEvidence(ofLookup:id), !evidence.entryID.isEmpty else { continue }
                let target: StudyTarget = if let key = evidence.senseKey, evidence.senseKeyKind != .none {
                    .sense(dictionary:evidence.dictionary.key,entryID:evidence.entryID,senseKey:key,senseKeyKind:evidence.senseKeyKind)
                } else { .entry(dictionary:evidence.dictionary.key,entryID:evidence.entryID) }
                let answer = evidence.gloss.map { StudyAnswer(origin:.dictionary,text:$0,dictionaryVersion:evidence.dictionary.version,senseHash:evidence.senseHash) }
                _ = try keep(target,issuer:.live,language:reading.language ?? StudyNote.unknownLanguage,chosenBy:evidence.chosenBy,answer:answer,lookupID:id,at:reading.at,source:.legacy,draft:true)
            }
            if let last = ids.last { try run("UPDATE keep_backfill SET cursor = ? WHERE version = 1",bind:[.integer(last)]) { _ in } }
        }
        return ids.count
    }
}

extension Ledger {
    public func resolvePrimary(ofLookup id: Int, dictionary: String?) throws {
        guard let dictionary else { return }
        try run("UPDATE lookups SET primary_dictionary = COALESCE(primary_dictionary, ?) WHERE id = ?", bind:[.text(dictionary),.integer(id)]) { _ in }
    }
    public func enrichLookup(_ id: Int, result: LookupResult, answeredBy: AnswerSource?, abstention: Abstention?) throws {
        try run("UPDATE lookups SET result = ?, answered_by = ?, sense_abstention = ? WHERE id = ?",
                bind: [.text(result.rawValue), .optionalText(answeredBy?.rawValue), .optionalText(abstention?.rawValue), .integer(id)]) { _ in }
    }
}

extension LookupRecord {
    public func pending() -> LookupRecord {
        LookupRecord(surface: surface, lemma: lemma, context: context, lemmaBasis: lemmaBasis,
            language: language, contextRange: contextRange, partOfSpeech: partOfSpeech, place: place,
            lookedUpAt: lookedUpAt, result: .pending, answeredBy: nil, quality: quality,
            legacySourceURL: legacySourceURL, senseAbstention: nil, script: script)
    }
}

extension Ledger {
    /// Original primary namespace, then latest reader choice within it; auxiliary taps do not redefine it.
    public func preferredEvidence(ofLookup id: Int) throws -> SenseEncounter? {
        let all = try encounters(ofLookup: id)
        var frozen: String?
        try run("SELECT primary_dictionary FROM lookups WHERE id = ?",bind:[.integer(id)]) { frozen = $0.optionalText(0) }
        let dictionaries = Set(all.map { $0.dictionary.key })
        guard let dictionary = frozen ?? (dictionaries.count == 1 ? dictionaries.first : nil) else { return nil }
        let scoped = all.filter { $0.dictionary.key == dictionary }
        return scoped.last(where: { $0.chosenBy == .reader }) ?? scoped.last(where: { $0.chosenBy == .onlySense }) ?? scoped.last
    }
    public func collectedCount(dictionary: String?, needingAttention: Bool = false) throws -> Int {
        var total = 0
        let scope = dictionary == nil ? "" : " AND n.dictionary = ?"
        let attention = needingAttention ? " AND NOT (\(Self.askableNotePredicate)) AND n.enrollment = 'active'" : ""
        try run("SELECT COUNT(*) FROM study_notes n WHERE \(Self.collectedNotePredicate)\(scope)\(attention)",bind:dictionary.map { [.text($0)] } ?? []) { total = $0.integer(0) }
        return total
    }

    /// The meanings that need the reader before they can be asked — `collectedCount(needingAttention:)`'s
    /// notes — **counted by what is in the way**, in one pass.
    ///
    /// One number used to say all of them "cannot be reviewed until you choose or confirm", and Confirm
    /// is not the remedy for most: on the measured ledger 22 of 65 had no answer at all. Each note is
    /// counted once, under `StudyReadiness.obstacle`'s order — no reading, then no answer that can be
    /// graded, then only the confirmation — and `theAttentionCountsAgreeWithEachRowsObstacle` holds this
    /// spelling to that one. The sense-hash check needs a dictionary and is not here, as it is not in
    /// the queue's predicate.
    public func attentionCounts(dictionary: String?) throws -> StudyAttention {
        var counts = StudyAttention(toConfirm: 0, toAnswer: 0, readingDeleted: 0)
        let scope = dictionary == nil ? "" : " AND n.dictionary = ?"
        try run("""
            SELECT
                COALESCE(SUM(CASE WHEN NOT (\(Self.evidencedNotePredicate)) THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN (\(Self.evidencedNotePredicate)) AND NOT (\(Self.gradableAnswerPredicate))
                                  THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN (\(Self.evidencedNotePredicate)) AND (\(Self.gradableAnswerPredicate))
                                       AND n.confirmed_at IS NULL THEN 1 ELSE 0 END), 0)
            FROM study_notes n
            WHERE \(Self.collectedNotePredicate)\(scope)
              AND n.enrollment = 'active' AND NOT (\(Self.askableNotePredicate))
            """, bind: dictionary.map { [.text($0)] } ?? []) { row in
            counts = StudyAttention(toConfirm: row.integer(2), toAnswer: row.integer(1), readingDeleted: row.integer(0))
        }
        return counts
    }
}

/// **What Review's empty state says is in the way, by reason** — one count per remedy, so a sentence
/// that names a remedy counts only what that remedy fixes.
public struct StudyAttention: Sendable, Equatable {
    /// Only the reader's agreement is missing; Confirm is the remedy.
    public let toConfirm: Int
    /// No answer that can be graded. Writing one is the remedy; **confirming is not**.
    public let toAnswer: Int
    /// The reading it was saved from is gone, so there is no sentence to ask it in.
    public let readingDeleted: Int

    public var total: Int { toConfirm + toAnswer + readingDeleted }

    public init(toConfirm: Int, toAnswer: Int, readingDeleted: Int) {
        self.toConfirm = toConfirm
        self.toAnswer = toAnswer
        self.readingDeleted = readingDeleted
    }
}

extension Ledger {
    public func recordForLearning(_ record: LookupRecord, with encounter: SenseEncounter?, policy: LookupKeepPolicy, primary: String?) throws -> Int {
        var id = 0
        try inOneTransaction("recordLearningLookup") {
            id = try self.record(record, with: encounter)
            try run("UPDATE lookups SET keep_policy = ?, primary_dictionary = ? WHERE id = ?",
                    bind:[.text(policy.rawValue),.optionalText(primary),.integer(id)]) { _ in }
        }
        return id
    }
}
