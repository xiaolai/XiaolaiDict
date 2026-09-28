import Foundation
import SQLite3

/// One sense a lookup found, with enough context to show it and to know where it came from.
public struct IndexCandidate: Sendable, Equatable {
    public let dictionary: String
    public let entryID: String
    public let headword: String
    public let senseKey: String
    public let definition: String
    /// The sub-entry this sense belongs to — a phrasal verb or idiom — or nil for a main sense.
    public let subEntry: String?
    public let partOfSpeech: String?
    public let senseNumber: String?
    /// The sense this one is a subsense of, or nil.
    public let parentKey: String?
}

/// One way of finding an entry, as the publisher's key index wrote it.
public struct SearchAlias: Sendable, Equatable {
    /// The folded form a lookup matches against.
    public let search: String
    /// The publisher's own spelling, for showing a reader.
    public let display: String
    /// **The sub-entry this alias names, when it names one.**
    ///
    /// nil means the alias names the whole entry. This field is the difference between `give up` returning
    /// its own two senses and returning all 76 of `give`'s — and recovering phrasal-verb senses without it
    /// would not make them reachable, which defeats the point of recovering them.
    public let subEntry: String?

    public init(search: String, display: String, subEntry: String? = nil) {
        self.search = search
        self.display = display
        self.subEntry = subEntry
    }
}

/// The on-disk index, and the constraints that make a wrong row impossible rather than unlikely.
///
/// **Four things the first schema draft got wrong, each demonstrated failing in SQLite before being
/// fixed:**
///
/// 1. **`search_key` had no foreign key.** Deleting a dictionary left its aliases behind, and recreating
///    the entry made those aliases resolve to an unrelated word. Now every alias and every sense references
///    its entry `ON DELETE CASCADE`, and an alias for an entry that does not exist is rejected outright.
/// 2. **`parent_key` pointing at a nonexistent sense was accepted.** A subsense could name a parent that
///    was never written. Now it is a composite self-reference, so a dangling parent is rejected and a NULL
///    one — a sense that is nobody's child — still passes.
/// 3. **No alias → sub-entry association.** `give up` and `give in` both returned `give`'s entire
///    candidate set. `SearchAlias.subEntry` scopes an alias, and `candidates(for:)` honours it.
/// 4. **`content_ver` alone cannot express an extractor generation.** Improving the reader would not
///    trigger a rebuild of an unchanged asset, so every dictionary would keep rows produced by code that no
///    longer exists. `extractor_gen` is stored beside it and `needsRebuild` reads both.
///
/// **`PRAGMA foreign_keys` is off by default and per connection, which is the trap under all of this.**
/// Every constraint above is decoration without it, and SQLite does not complain if it is never set. It is
/// therefore set on open and **read back**, and a connection that will not enable it fails rather than
/// quietly accepting orphans.
public final class IndexStore {
    /// **What built the rows, bumped whenever the reader's output changes.**
    ///
    /// Not a schema version: the schema can be identical while the extractor produces different senses from
    /// the same bytes, which is exactly what steps 2 and 3 of the plan did — NOAD went from 147,569
    /// definitions to 203,253 with no change to any table. A dictionary whose stored generation is behind
    /// this number is rebuilt even though its own `content_ver` has not moved.
    public static let extractorGeneration = 1

    /// The shape of the tables. Separate from `extractorGeneration` because a migration and a re-extraction
    /// are different jobs.
    public static let schemaVersion = 3

    public enum Failure: Error, CustomStringConvertible {
        case open(String)
        case sql(String)
        /// The connection would not enforce foreign keys, so every constraint in the schema is decoration.
        case foreignKeysUnavailable
        /// A read-only open found an index written under a different schema. **Refused rather than
        /// migrated or discarded**: the reader owns this file, and only a rebuild may throw it away.
        case unsupportedSchema(found: Int, expected: Int)
        public var description: String {
            switch self {
            case .open(let s): return "could not open the index: \(s)"
            case .sql(let s): return s
            case .foreignKeysUnavailable:
                return "SQLite would not enable foreign keys; the schema's constraints would not hold"
            case .unsupportedSchema(let found, let expected):
                return "the index was written under schema \(found); this build reads \(expected). "
                    + "Rebuild it with XiaolaiDictIndex"
            }
        }
    }

    /// Where the reader's index lives, when nobody says otherwise.
    ///
    /// **One spelling of the path.** The tool that writes it and the service that reads it are different
    /// processes, and two copies of this string would drift the day one of them moved — leaving a service
    /// that reports an empty inventory while a 319 MB index sits beside it.
    ///
    /// Application Support rather than Caches. The index *is* derived data, which argues for Caches — but
    /// rebuilding the catalogue is minutes of work, and a reader who loses it to a routine cache purge has
    /// lost their study history's names with it.
    public static let defaultURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/XiaolaiDict/index.sqlite")

    private let handle: OpaquePointer

    /// Opens or creates the index at `path`, or `":memory:"` for a store that outlives nothing.
    ///
    /// **This door may destroy the file**, and that is deliberate: `applySchema` discards an index written
    /// under an older schema rather than migrating it. Only a rebuild should come through here. Anything
    /// that merely wants to read uses `init(readingAt:)`.
    public convenience init(path: String) throws { try self.init(path: path, forWriting: true) }

    /// Opens an existing index **without creating, migrating or discarding anything.**
    ///
    /// Three refusals, each of which the read-write door would instead have answered by changing the file:
    /// a missing index is not created, an index from another schema is not dropped, and the connection
    /// itself cannot write. For a caller like the phrase detector, which opens the reader's index on a
    /// lookup to fetch sub-entry labels, every one of those is the difference between reading 319 MB of
    /// derived data and deleting it.
    public convenience init(readingAt path: String) throws { try self.init(path: path, forWriting: false) }

    private init(path: String, forWriting: Bool) throws {
        var handle: OpaquePointer?
        let flags = forWriting
            ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw Failure.open(message)
        }
        self.handle = handle
        // **Set, then verified.** An unknown or refused pragma is silent, and every constraint below
        // depends on this one being on. A connection setting, so it holds on a read-only handle too.
        try execute("PRAGMA foreign_keys = ON")
        guard try scalar("PRAGMA foreign_keys") == 1 else { throw Failure.foreignKeysUnavailable }
        guard forWriting else {
            // **Asked, and then refused — never repaired.** `applySchema` would drop every table here.
            let found = try scalar("PRAGMA user_version")
            guard found == Int64(Self.schemaVersion) else {
                throw Failure.unsupportedSchema(found: Int(found), expected: Self.schemaVersion)
            }
            return
        }
        try applySchema()
    }

    /// Creates the tables, **discarding an index built under an older schema.**
    ///
    /// `CREATE TABLE IF NOT EXISTS` alone is not enough: it leaves an existing table exactly as it was, so a
    /// file written before a column was added keeps the old shape and every later insert fails — or worse,
    /// succeeds against a column that no longer means what it did. The whole index is derived from the
    /// dictionaries on this Mac and can always be rebuilt, so the honest move for a version mismatch is to
    /// throw it away rather than migrate it.
    ///
    /// `user_version` is SQLite's own slot for this and costs nothing to read.
    private func applySchema() throws {
        // **Any version but this one is discarded, `0` included.** Treating `0` as "a fresh database" was
        // wrong in exactly the case this exists for: a file written before versioning was added has
        // `user_version == 0` *and* the old table shapes, so skipping the teardown left it in place. On a
        // genuinely new database the teardown drops nothing, so there is no cost to being unconditional.
        if try scalar("PRAGMA user_version") != Int64(Self.schemaVersion) {
            try execute(Self.teardown)
        }
        try execute(Self.schema)
        try execute("PRAGMA user_version = \(Self.schemaVersion)")
    }

    /// Drops everything this store owns, for a schema change. Order matters: children before parents, so
    /// the foreign keys are satisfied at every step.
    static let teardown = """
        DROP TABLE IF EXISTS alignment;
        DROP TABLE IF EXISTS entry_anchor;
        DROP TABLE IF EXISTS search_key;
        DROP TABLE IF EXISTS sense;
        DROP TABLE IF EXISTS entry;
        DROP TABLE IF EXISTS dictionary;
        """

    deinit { sqlite3_close(handle) }

    /// The tables, written once and applied on every open. `IF NOT EXISTS` throughout, so opening an
    /// existing index is the same code path as creating one.
    static let schema = """
        CREATE TABLE IF NOT EXISTS dictionary (
            identifier      TEXT PRIMARY KEY,
            display_name    TEXT NOT NULL,
            -- What the bundle says about itself. `CFBundleShortVersionString` and the body's byte length,
            -- because a re-master that forgot to bump the string still changes the bytes.
            content_ver     TEXT NOT NULL,
            -- What built the rows. See `IndexStore.extractorGeneration`.
            extractor_gen   INTEGER NOT NULL,
            -- The key mapping's confidence at build time. A rebuild refuses anything but `verified`, and
            -- storing it means a later reader can see why a dictionary has no aliases.
            key_confidence  TEXT NOT NULL,
            built_at        TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS entry (
            dictionary  TEXT NOT NULL REFERENCES dictionary(identifier) ON DELETE CASCADE,
            entry_id    TEXT NOT NULL,
            headword    TEXT NOT NULL,
            homograph   TEXT,
            PRIMARY KEY (dictionary, entry_id)
        );

        CREATE TABLE IF NOT EXISTS sense (
            dictionary      TEXT NOT NULL,
            entry_id        TEXT NOT NULL,
            sense_key       TEXT NOT NULL,
            origin          TEXT NOT NULL CHECK (origin IN ('publisher', 'content')),
            part_of_speech  TEXT,
            sense_number    TEXT,
            -- The sub-entry label this sense belongs to, as the publisher spells it, or NULL for a main
            -- sense. Shown to a reader; never matched against.
            sub_entry       TEXT,
            -- **The canonical form of that label, which is what matching uses.** `scope` normalised the
            -- alias before comparing but the query then compared raw spellings, so an entry carrying both
            -- `give up` and `Give Up` had one of the two groups unreachable — and which one depended on
            -- sense order.
            sub_entry_key   TEXT,
            definition      TEXT NOT NULL,
            -- The example phrases printed against this sense, joined by U+001F. One column rather than a
            -- table because an example is never looked up on its own — it is always read with its sense —
            -- and U+001F is a control character no dictionary prints. `examples(of:)` splits it back.
            examples        TEXT NOT NULL DEFAULT '',
            -- A subsense's parent. **Composite and self-referencing on purpose**: a parent in another entry
            -- is meaningless, and a dangling one used to be accepted. NULL is still fine — SQLite treats a
            -- composite reference with any NULL column as satisfied, which is exactly the rule wanted here.
            parent_key      TEXT,
            -- The parent's origin, because the reference below has to name a whole identity.
            parent_origin   TEXT,
            -- **`origin` is part of a sense's identity.** `SenseKey` distinguishes a publisher id from a
            -- content digest, and leaving it out of the key meant a publisher id that reads like a digest
            -- and the content key with that digest were one row — `INSERT OR REPLACE` kept whichever came
            -- second.
            -- **Both parent columns or neither.** A composite foreign key is satisfied when *any* of its
            -- columns is NULL, so a `parent_key` paired with a NULL `parent_origin` bypassed the reference
            -- entirely — and a caller that simply forgot the origin got no check at all. This makes the
            -- pairing a constraint rather than something a call site has to remember.
            CHECK ((parent_key IS NULL) = (parent_origin IS NULL)),
            PRIMARY KEY (dictionary, entry_id, sense_key, origin),
            FOREIGN KEY (dictionary, entry_id)
                REFERENCES entry(dictionary, entry_id) ON DELETE CASCADE,
            FOREIGN KEY (dictionary, entry_id, parent_key, parent_origin)
                REFERENCES sense(dictionary, entry_id, sense_key, origin) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS search_key (
            dictionary  TEXT NOT NULL,
            entry_id    TEXT NOT NULL,
            search      TEXT NOT NULL,
            display     TEXT NOT NULL,
            -- Canonical, for the same reason as `sense.sub_entry_key`.
            sub_entry   TEXT,
            PRIMARY KEY (dictionary, entry_id, search, display),
            -- The foreign key the first draft did not have. Without it, deleting a dictionary left the
            -- alias behind and recreating the entry made it resolve to an unrelated word.
            FOREIGN KEY (dictionary, entry_id)
                REFERENCES entry(dictionary, entry_id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS entry_anchor (
            dictionary  TEXT NOT NULL,
            entry_id    TEXT NOT NULL,
            -- An identifier this entry shares with another dictionary from the same publisher. See
            -- `IndexedEntry.anchors`: Oxford's `prlexid` is the same value in NOAD and 牛津英汉汉英, which
            -- makes the entry-to-entry join exact including homographs.
            anchor      TEXT NOT NULL,
            PRIMARY KEY (dictionary, entry_id, anchor),
            FOREIGN KEY (dictionary, entry_id)
                REFERENCES entry(dictionary, entry_id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS alignment (
            hub_dictionary   TEXT NOT NULL,
            hub_entry        TEXT NOT NULL,
            hub_sense        TEXT NOT NULL,
            hub_origin       TEXT NOT NULL,
            spoke_dictionary TEXT NOT NULL,
            spoke_entry      TEXT NOT NULL,
            spoke_sense      TEXT NOT NULL,
            spoke_origin     TEXT NOT NULL,
            -- What the matcher thought of this pair. Stored because an alignment without one is a claim:
            -- the method that produced these can only settle about half of them, and a reader is entitled
            -- to know which half a pair came from.
            confidence       REAL NOT NULL,
            -- Which matcher produced it, so a better one later is distinguishable from this one rather
            -- than silently mixed with it.
            method           TEXT NOT NULL,
            PRIMARY KEY (hub_dictionary, hub_entry, hub_sense, hub_origin,
                         spoke_dictionary, spoke_entry, spoke_sense, spoke_origin),
            -- **Both sides reference a real sense, and a pair dies with either.** The first schema draft let
            -- an alias outlive its entry and then resolve to an unrelated word; a stored alignment whose
            -- sense has been rebuilt away is the same defect pointing at two dictionaries instead of one.
            FOREIGN KEY (hub_dictionary, hub_entry, hub_sense, hub_origin)
                REFERENCES sense(dictionary, entry_id, sense_key, origin) ON DELETE CASCADE,
            FOREIGN KEY (spoke_dictionary, spoke_entry, spoke_sense, spoke_origin)
                REFERENCES sense(dictionary, entry_id, sense_key, origin) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS entry_anchor_by_anchor ON entry_anchor(anchor);
        CREATE INDEX IF NOT EXISTS alignment_by_hub
            ON alignment(hub_dictionary, hub_entry, hub_sense);
        CREATE INDEX IF NOT EXISTS search_key_by_search ON search_key(search);
        CREATE INDEX IF NOT EXISTS sense_by_entry ON sense(dictionary, entry_id);
        """

    // MARK: - Rebuild decisions

    /// Whether this dictionary has to be rebuilt: never built, its content changed, or the extractor that
    /// built it has been superseded.
    ///
    /// **Both halves, because either alone is wrong.** Watching only `content_ver` leaves rows from an
    /// extractor that no longer exists; watching only the generation rebuilds nothing when Apple ships new
    /// content.
    public func needsRebuild(_ identifier: String, contentVersion: String,
                             extractorGeneration: Int = IndexStore.extractorGeneration) throws -> Bool {
        var stored: (ver: String, gen: Int)?
        try query("SELECT content_ver, extractor_gen FROM dictionary WHERE identifier = ?",
                  bind: [identifier]) { row in
            stored = (row.text(0) ?? "", Int(row.int(1)))
        }
        guard let stored else { return true }
        return stored.ver != contentVersion || stored.gen != extractorGeneration
    }

    /// Records a dictionary and **removes everything previously built from it**, so a rebuild replaces
    /// rather than accumulates. The cascade is what makes that one statement instead of four.
    public func beginRebuild(identifier: String, displayName: String, contentVersion: String,
                             keyConfidence: String,
                             extractorGeneration: Int = IndexStore.extractorGeneration) throws {
        try execute("DELETE FROM dictionary WHERE identifier = ?", bind: [identifier])
        try execute("""
            INSERT INTO dictionary (identifier, display_name, content_ver, extractor_gen,
                                    key_confidence, built_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            bind: [identifier, displayName, contentVersion, extractorGeneration, keyConfidence,
                   ISO8601DateFormatter().string(from: Date())])
    }

    /// Drops a dictionary and everything derived from it.
    public func forget(_ identifier: String) throws {
        try execute("DELETE FROM dictionary WHERE identifier = ?", bind: [identifier])
    }

    public func dictionaries() throws -> [(identifier: String, contentVersion: String,
                                           extractorGeneration: Int, keyConfidence: String)] {
        var out: [(String, String, Int, String)] = []
        try query("""
            SELECT identifier, content_ver, extractor_gen, key_confidence FROM dictionary
            ORDER BY identifier
            """, bind: []) { row in
            out.append((row.text(0) ?? "", row.text(1) ?? "", Int(row.int(2)), row.text(3) ?? ""))
        }
        return out
    }

    // MARK: - Writing

    /// Writes one entry, its senses, its subsenses and its aliases.
    ///
    /// **Senses before subsenses, deliberately.** `parent_key` is enforced, so a subsense written before its
    /// parent is rejected — which is the constraint working, not a problem to route around with a deferred
    /// check.
    public func insert(_ entry: IndexedEntry, dictionary: String, aliases: [SearchAlias] = []) throws {
        try execute("""
            INSERT OR REPLACE INTO entry (dictionary, entry_id, headword, homograph) VALUES (?, ?, ?, ?)
            """,
            bind: [dictionary, entry.entryID, entry.headword, entry.homograph])
        for sense in entry.senses {
            try insertSense(dictionary: dictionary, entryID: entry.entryID, key: sense.key.value,
                            origin: sense.key.origin.rawValue, position: sense.position,
                            definition: sense.definition, examples: sense.examples, parentKey: nil)
        }
        for sense in entry.senses {
            for subsense in sense.subsenses {
                try insertSense(dictionary: dictionary, entryID: entry.entryID, key: subsense.key.value,
                                origin: subsense.key.origin.rawValue,
                                position: SensePosition(subEntry: sense.position.subEntry,
                                                        partOfSpeech: sense.position.partOfSpeech,
                                                        senseNumber: subsense.label),
                                definition: subsense.definition, parentKey: sense.key.value,
                                parentOrigin: sense.key.origin.rawValue)
            }
        }
        for anchor in entry.anchors {
            try execute("""
                INSERT OR REPLACE INTO entry_anchor (dictionary, entry_id, anchor) VALUES (?, ?, ?)
                """,
                bind: [dictionary, entry.entryID, anchor])
        }
        for alias in aliases {
            try insertAlias(dictionary: dictionary, entryID: entry.entryID, alias: alias)
        }
    }

    /// One alias. Internal rather than private so the orphan-alias constraint can be exercised directly:
    /// `insert(_:dictionary:aliases:)` always writes the entry row first, so it cannot produce the orphan
    /// the first schema draft accepted.
    func insertAlias(dictionary: String, entryID: String, alias: SearchAlias) throws {
        try execute("""
            INSERT OR REPLACE INTO search_key (dictionary, entry_id, search, display, sub_entry)
            VALUES (?, ?, ?, ?, ?)
            """,
            // **Canonical, because the query compares it against `sense.sub_entry_key`.** `scope` returns
            // the publisher's own spelling — that is what a reader is shown — so storing it unchanged here
            // made a label like `Give Up` match nothing at all. An earlier version of this line did
            // normalise it and the call was then refactored out from under the fix.
            bind: [dictionary, entryID, alias.search, alias.display,
                   alias.subEntry.map(Self.canonical)])
    }

    /// One sense. Internal for the same reason: a dangling `parent_key` cannot be reached through the
    /// public writer, which always writes parents before children.
    /// U+001F, the unit separator: a control character no dictionary prints, so it cannot occur in the text
    /// it separates.
    static let exampleSeparator = "\u{1F}"

    /// Splits what `examples` stores back into phrases.
    public static func examples(of stored: String) -> [String] {
        stored.isEmpty ? [] : stored.components(separatedBy: exampleSeparator)
    }

    func insertSense(dictionary: String, entryID: String, key: String, origin: String = "content",
                     position: SensePosition = .unplaced, definition: String, examples: [String] = [],
                     parentKey: String?, parentOrigin: String? = nil) throws {
        try execute("""
            INSERT OR REPLACE INTO sense (dictionary, entry_id, sense_key, origin, part_of_speech,
                                          sense_number, sub_entry, sub_entry_key, definition, examples,
                                          parent_key, parent_origin)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: [dictionary, entryID, key, origin, position.partOfSpeech, position.senseNumber,
                   position.subEntry, position.subEntry.map(Self.canonical), definition,
                   examples.joined(separator: Self.exampleSeparator), parentKey, parentOrigin])
    }

    /// Which sub-entry of `entry`, if any, an alias names.
    ///
    /// **This is the join that makes a recovered phrasal-verb sense reachable.** Pure and separately
    /// testable: the alias's display form is compared against the entry's own sub-entry labels under the
    /// same normalisation a content key uses, so `give up ` and `Give Up` both find `give up`.
    public static func scope(alias display: String, within entry: IndexedEntry) -> String? {
        scope(aliasForms: [display], within: entry)
    }

    /// The sub-entry a key group names, tried against **every** form the group carries.
    ///
    /// **One form is not enough.** A group is a folded search key followed by display forms, and installed
    /// NOAD carries `["give or take", "give or take —", "give"]` — so `keys.last` is `give`, the base word,
    /// and a group for `give me` ends in an `xpointer(...)` fragment. Scoping on that one form matched the
    /// wrong sub-entry or none at all. Every form is tried, and the first that names one wins.
    public static func scope(aliasForms: [String], within entry: IndexedEntry) -> String? {
        let labels = entry.senses.compactMap(\.position.subEntry)
        guard !labels.isEmpty else { return nil }
        for form in aliasForms {
            let wanted = canonical(form)
            guard !wanted.isEmpty else { continue }
            if let label = labels.first(where: { canonical($0) == wanted }) { return label }
        }
        return nil
    }

    /// The form a sub-entry label is *matched* by. The label a reader sees is stored unchanged beside it.
    static func canonical(_ label: String) -> String { SenseKey.normalise(label) }

    // MARK: - Reading

    /// The one statement behind `candidates(for:)`, named so `candidateQueryPlan` checks the same text the
    /// reader runs. Two copies would drift, and the plan assertion would then be guarding nothing.
    static let candidateQuery = """
            SELECT sense.dictionary, sense.entry_id, entry.headword, sense.sense_key, sense.definition,
                   sense.sub_entry, sense.part_of_speech, sense.sense_number, sense.parent_key
            FROM search_key
            JOIN entry ON entry.dictionary = search_key.dictionary
                      AND entry.entry_id = search_key.entry_id
            JOIN sense ON sense.dictionary = search_key.dictionary
                      AND sense.entry_id = search_key.entry_id
            -- An unscoped alias names the whole entry; a scoped one names its sub-entry and nothing else.
            WHERE search_key.search = ?
              AND (search_key.sub_entry IS NULL OR search_key.sub_entry IS sense.sub_entry_key)
            -- **`GROUP BY`, because an entry can carry several aliases with the same folded `search`.**
            -- `give` and `Give` share one, so the join returned each sense twice. An `EXISTS` predicate
            -- also de-duplicates, but it starts from `sense` and so cannot use `search_key_by_search`:
            -- measured at 45.75 ms for a missing word over 200,000 senses, against an index-driven lookup.
            -- Entering through the alias index and collapsing the duplicates keeps both properties.
            -- **Grouped by the whole identity, `origin` included.** Three of the four columns collapsed a
            -- publisher key and a content key that share a value into one row — the same omission that had
            -- just been fixed in the primary key, one statement away.
            GROUP BY sense.dictionary, sense.entry_id, sense.sense_key, sense.origin
            ORDER BY sense.dictionary, sense.entry_id, sense.sense_key, sense.origin
        """

    /// Every sense a search form can reach, narrowed to the sub-entry the alias names when it names one.
    public func candidates(for search: String) throws -> [IndexCandidate] {
        var out: [IndexCandidate] = []
        try query(Self.candidateQuery, bind: [search]) { row in
            out.append(IndexCandidate(
                dictionary: row.text(0) ?? "", entryID: row.text(1) ?? "", headword: row.text(2) ?? "",
                senseKey: row.text(3) ?? "", definition: row.text(4) ?? "", subEntry: row.text(5),
                partOfSpeech: row.text(6), senseNumber: row.text(7), parentKey: row.text(8)))
        }
        return out
    }

    /// Rows inserted, updated or deleted on this connection since it was opened — SQLite's own counter.
    ///
    /// **Exposed because "writes nothing" is otherwise unobservable.** A driver that decides a dictionary is
    /// up to date and then rewrites it anyway looks exactly like one that skipped it, and a `built_at` that
    /// happens not to change is weak evidence. This is the number the second-run check reads.
    public var totalRowChanges: Int { Int(sqlite3_total_changes(handle)) }

    // MARK: - Alignment

    /// One sense of one dictionary, as a matcher needs to see it.
    public struct AlignableSense: Sendable, Equatable {
        public let entryID: String
        public let senseKey: String
        public let origin: String
        public let headword: String
        public let partOfSpeech: String?
        public let definition: String
        public let examples: [String]
        /// The sub-entry this sense belongs to — a phrasal verb or idiom — or nil for a main sense.
        ///
        /// **A main sense and an idiom must not compete.** NOAD's `hold` carries both, and with the idioms in
        /// the candidate set the matcher put 使保持不动 against "squeeze one's nostrils with one's fingers"
        /// (*hold one's nose*) and 抓地 against "approve of something" (*hold with*) — five of five wrong for
        /// that headword, while the aggregate moved by two points and hid it. 牛津英汉汉英 files no sub-entry
        /// senses at all, so every one of its senses must be matched against a main sense.
        public let subEntry: String?
        /// Whether another sense of this entry names this one as its parent.
        ///
        /// **A parent is never a candidate while its children are.** A numbered sense's text is the join of
        /// its subsenses' — `hold` reads "grasp, carry, or support with one's hands; keep or sustain in a
        /// specified position; embrace (someone); …" — so its term overlap with anything is a *superset* of
        /// every child's, and a score built on overlap makes the parent win every time. Two different
        /// Chinese senses, 拥抱 and 使保持不动, both landed on that one English sense at the same confidence,
        /// which is the coarse answer rather than the right one.
        public let hasSubsenses: Bool

        /// Everything about this sense that could be in the other dictionary's language — its definition
        /// wording and its examples. `SenseAligner` scores against exactly this.
        public var matchableText: String { ([definition] + examples).joined(separator: " ") }
    }

    /// Entry pairs the publisher's own anchors join, deduplicated.
    ///
    /// **Pairs of entries, not of anchors.** One entry commonly carries several: 牛津英汉汉英 stamps a
    /// `prlexid` on each pronunciation, so 43,247 of its entries have more than one — the British and the
    /// American form of the same word. Iterating anchors assessed those senses once per pronunciation, which
    /// inflated every count and left `INSERT OR REPLACE` to quietly collapse the duplicates afterwards.
    /// Pairing entries also gives the matcher every candidate at once instead of one anchor's worth.
    public func entryPairs(hub: String, spoke: String) throws -> [(hub: String, spoke: String)] {
        var seen = Set<String>()
        var out: [(hub: String, spoke: String)] = []
        try query("""
            SELECT DISTINCT h.entry_id, s.entry_id
              FROM entry_anchor h
              JOIN entry_anchor s ON s.anchor = h.anchor AND s.dictionary = ?
             WHERE h.dictionary = ?
             ORDER BY h.entry_id, s.entry_id
            """, bind: [spoke, hub]) { row in
            let pair = (row.text(0) ?? "", row.text(1) ?? "")
            guard seen.insert("\(pair.0)\u{1F}\(pair.1)").inserted else { return }
            out.append((hub: pair.0, spoke: pair.1))
        }
        return out
    }

    /// The single-word search forms of each entry, grouped by entry.
    ///
    /// **The publisher's own inflection list, and it is already indexed.** Excluding a headword from the
    /// matchable text is not enough, because a dictionary writes the inflections: dropping `hold` left *held*
    /// behind, and "a meeting was held at the church" shares it with "she held me by the sleeve", "it held the
    /// worm in its beak" and "we held the thief" — one shared verb form deciding four pairs that had nothing
    /// else in common, all of them wrong. Apple's key index already carries `held`, `holding`, `holds` and
    /// `holdable` as ways of finding that entry, so the forms to exclude need neither a lemmatiser nor a
    /// guess. Phrases are left out: `hold water` is a sub-entry's name, not an inflection.
    public func inflectionsByEntry(in dictionary: String) throws -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        try query("""
            SELECT entry_id, search FROM search_key
             WHERE dictionary = ? AND search NOT LIKE '% %'
            """, bind: [dictionary]) { row in
            guard let entry = row.text(0), let form = row.text(1) else { return }
            out[entry, default: []].insert(form)
        }
        return out
    }

    /// Every sub-entry label `dictionary` prints — the names of its phrasal verbs and idioms.
    ///
    /// **The half of the phrase inventory Apple's key index does not hold**, and the concrete thing the
    /// body walk buys. Measured on NOAD, 2026-09-29: 9,755 labels, of which 935 appear in no key of any
    /// group in `KeyText.data` — and those 935 include `take something into account`,
    /// `beat around the bush`, `once in a blue moon` and `cost an arm and a leg`. Reading them from here
    /// costs a query; finding them without an index costs a 60-second body walk per dictionary.
    ///
    /// Multi-word only, because a one-word sub-entry label is a derived form rather than a phrase, and
    /// `PhraseSpans` would discard it anyway.
    public func subEntryLabels(in dictionary: String) throws -> Set<String> {
        var out = Set<String>()
        try query("""
            SELECT DISTINCT sub_entry FROM sense
             WHERE dictionary = ? AND sub_entry IS NOT NULL AND sub_entry LIKE '% %'
            """, bind: [dictionary]) { row in
            guard let label = row.text(0) else { return }
            out.insert(label)
        }
        return out
    }

    /// Every sense of `dictionary`, grouped by the entry it belongs to.
    public func sensesByEntry(in dictionary: String) throws -> [String: [AlignableSense]] {
        var out: [String: [AlignableSense]] = [:]
        try query("""
            SELECT sense.entry_id, sense.sense_key, sense.origin, entry.headword,
                   sense.part_of_speech, sense.definition, sense.examples, sense.sub_entry_key,
                   EXISTS (SELECT 1 FROM sense child
                            WHERE child.dictionary = sense.dictionary
                              AND child.entry_id = sense.entry_id
                              AND child.parent_key = sense.sense_key
                              AND child.parent_origin = sense.origin)
              FROM sense
              JOIN entry ON entry.dictionary = sense.dictionary AND entry.entry_id = sense.entry_id
             WHERE sense.dictionary = ?
             ORDER BY sense.entry_id, sense.sense_key
            """, bind: [dictionary]) { row in
            let entry = row.text(0) ?? ""
            out[entry, default: []].append(AlignableSense(
                entryID: entry, senseKey: row.text(1) ?? "", origin: row.text(2) ?? "",
                headword: row.text(3) ?? "", partOfSpeech: row.text(4), definition: row.text(5) ?? "",
                examples: Self.examples(of: row.text(6) ?? ""), subEntry: row.text(7),
                hasSubsenses: row.int(8) != 0))
        }
        return out
    }

    /// Records one aligned pair.
    public func insertAlignment(hub: (dictionary: String, sense: AlignableSense),
                                spoke: (dictionary: String, sense: AlignableSense),
                                confidence: Double, method: String) throws {
        try execute("""
            INSERT OR REPLACE INTO alignment
                (hub_dictionary, hub_entry, hub_sense, hub_origin,
                 spoke_dictionary, spoke_entry, spoke_sense, spoke_origin, confidence, method)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bind: [hub.dictionary, hub.sense.entryID, hub.sense.senseKey, hub.sense.origin,
                   spoke.dictionary, spoke.sense.entryID, spoke.sense.senseKey, spoke.sense.origin,
                   confidence, method])
    }

    /// Drops every pair between two dictionaries, so a re-run replaces rather than accumulates.
    public func forgetAlignment(hub: String, spoke: String) throws {
        try execute("""
            DELETE FROM alignment WHERE hub_dictionary = ? AND spoke_dictionary = ?
            """, bind: [hub, spoke])
    }

    public func alignmentCount(hub: String, spoke: String) throws -> Int {
        var n = 0
        try query("SELECT count(*) FROM alignment WHERE hub_dictionary = ? AND spoke_dictionary = ?",
                  bind: [hub, spoke]) { n = Int($0.int(0)) }
        return n
    }

    public func anchorCount(in dictionary: String) throws -> Int {
        var n = 0
        try query("SELECT count(*) FROM entry_anchor WHERE dictionary = ?", bind: [dictionary]) {
            n = Int($0.int(0))
        }
        return n
    }

    public func senseCount(in dictionary: String) throws -> Int {
        var n = 0
        try query("SELECT count(*) FROM sense WHERE dictionary = ?", bind: [dictionary]) { n = Int($0.int(0)) }
        return n
    }

    public func aliasCount(in dictionary: String) throws -> Int {
        var n = 0
        try query("SELECT count(*) FROM search_key WHERE dictionary = ?", bind: [dictionary]) {
            n = Int($0.int(0))
        }
        return n
    }

    /// Runs the whole of `body` in one transaction, rolling back if it throws. A rebuild that fails
    /// half-way must leave the previous index in place rather than a partial one.
    public func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - SQLite plumbing

    /// One row of a result set, read by column index.
    public struct Row {
        let statement: OpaquePointer
        /// Read by byte count rather than to the first NUL, so a stored U+0000 round-trips instead of
        /// truncating what comes back.
        public func text(_ column: Int32) -> String? {
            guard let bytes = sqlite3_column_text(statement, column) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, column))
            return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        }
        public func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    }

    /// Binds the parameters of one statement. Takes `[Any?]` and **rejects an unsupported type at
    /// runtime** — a thrown error rather than a row that silently stores NULL.
    private func bind(_ values: [Any?], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case nil:
                status = sqlite3_bind_null(statement, index)
            case let s as String:
                // **Bound by byte length, never `-1`.** `-1` means "to the first NUL", so a string holding
                // U+0000 stored only its prefix — two distinct identifiers could collapse into one row.
                let bytes = Array(s.utf8)
                status = bytes.withUnsafeBufferPointer { buffer in
                    sqlite3_bind_text(statement, index,
                                      buffer.baseAddress.map { UnsafeRawPointer($0)
                                          .assumingMemoryBound(to: CChar.self) },
                                      Int32(bytes.count), SQLITE_TRANSIENT)
                }
            case let i as Int:
                status = sqlite3_bind_int64(statement, index, Int64(i))
            case let d as Double:
                status = sqlite3_bind_double(statement, index, d)
            default:
                throw Failure.sql("cannot bind \(type(of: value!)) at parameter \(index)")
            }
            guard status == SQLITE_OK else { throw error() }
        }
    }

    private func execute(_ sql: String, bind values: [Any?] = []) throws {
        // Several statements at once, for the schema.
        if values.isEmpty, sql.contains(";") {
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
                let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
                sqlite3_free(message)
                throw Failure.sql(text)
            }
            return
        }
        let statement = try prepareOne(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else { throw error() }
    }

    /// Prepares `sql` and **refuses it if it holds more than one statement**.
    ///
    /// `sqlite3_prepare_v2` compiles the first statement of its input and ignores the rest without a word,
    /// so a two-statement call would run a prefix of what it was given and report success — the defect shape
    /// every other constraint in this file exists to remove.
    ///
    /// **Asked of SQLite rather than of the string.** A first attempt scanned for `;` and rejected four of
    /// this file's own queries, because one has a semicolon *inside a SQL comment* — the same
    /// substring-versus-token mistake `DictionaryProfile` records for `class` attributes. `pzTail` is the
    /// parser's own answer to "what did you not consume", so it cannot be fooled by a comment or a literal.
    /// Read inside `withCString`, because the pointer aims into that buffer and not into the Swift string.
    private func prepareOne(_ sql: String) throws -> OpaquePointer {
        try sql.withCString { cString -> OpaquePointer in
            var statement: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            guard sqlite3_prepare_v2(handle, cString, -1, &statement, &tail) == SQLITE_OK,
                  let statement else {
                throw error()
            }
            if let tail {
                let rest = String(cString: tail).trimmingCharacters(
                    in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";")))
                if !rest.isEmpty {
                    sqlite3_finalize(statement)
                    throw Failure.sql("a prepared call must be a single statement; SQLite left "
                                      + "\(rest.prefix(60)) unconsumed")
                }
            }
            return statement
        }
    }

    private func query(_ sql: String, bind values: [Any?], _ row: (Row) -> Void) throws {
        let statement = try prepareOne(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW { row(Row(statement: statement)); continue }
            guard status == SQLITE_DONE else { throw error() }
            break
        }
    }

    /// Two statements in one prepared call, so the refusal above can be exercised. Internal: no caller
    /// should be able to reach it, which is why nothing public does.
    /// SQLite's own plan for the candidate lookup, so "it uses the alias index" is an assertion rather than
    /// a claim. Internal: a caller has no use for it.
    func candidateQueryPlan() throws -> [String] {
        var rows: [String] = []
        try query("EXPLAIN QUERY PLAN " + Self.candidateQuery, bind: [""]) { row in
            rows.append(row.text(3) ?? "")
        }
        return rows
    }

    /// Stamps a different schema version, so the discard-on-mismatch path can be exercised.
    func setSchemaVersionForTesting(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    func prepareTwoForTesting() throws {
        // A bind is what routes this through `prepareOne`; without one it would take the `sqlite3_exec`
        // path, which runs both statements legitimately and is how the schema is applied.
        try execute("SELECT ? ; SELECT 2", bind: [1])
    }

    private func scalar(_ sql: String) throws -> Int64 {
        var value: Int64 = 0
        try query(sql, bind: []) { value = $0.int(0) }
        return value
    }

    private func error() -> Failure {
        .sql(String(cString: sqlite3_errmsg(handle)))
    }
}

/// `SQLITE_TRANSIENT` is a function pointer cast that Swift does not import, so it is rebuilt here. Without
/// it `sqlite3_bind_text` keeps a pointer to a Swift string that has already been released.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
