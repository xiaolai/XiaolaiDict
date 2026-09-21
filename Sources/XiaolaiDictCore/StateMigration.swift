import Foundation

/// Moving the reader's state from the paths the app used under its legacy name.
///
/// Renaming an app is free; changing its bundle identifier is not. macOS keys a defaults domain on
/// the identifier and this app keyed its support directory on the name, so `com.xiaolaidict` starts
/// life looking at two empty places — and **an empty ledger is indistinguishable from a working
/// one**. That is the failure this type exists to make impossible rather than unlikely: every
/// operation here reports what arrived, and the caller is expected to act on a count, not on the
/// absence of a thrown error.
///
/// Both operations are idempotent. They run on every launch and do nothing on all but the first.
public enum StateMigration {
    /// What a directory migration did. `moved` carries the evidence: rows readable at the new path.
    public enum DirectoryResult: Equatable, Sendable {
        /// No legacy directory. The ordinary case on every launch after the first.
        case nothingToMove
        /// Both directories exist, so neither was touched. Two ledgers are never merged.
        case bothExist
        /// The directory was moved, and this many lookups were read back from the new path.
        case moved(lookups: Int)
    }

    public enum MigrationError: Error, Equatable {
        /// The move reported success and the rows are not there. Never seen; if it is, the reader's
        /// history is in the legacy directory, which is deliberately still present when this throws.
        case rowsLost(expected: Int, arrived: Int)
    }

    /// Moves `legacy` to `current` whole, and proves the ledger's rows arrived.
    ///
    /// The whole directory moves, not the database file alone. A ledger separated from its
    /// write-ahead log loses every write SQLite has not yet folded into the main file — measured
    /// on this developer's Mac as a 449 KB log against a 40 KB database — and moving the directory
    /// also carries anything added beside it later without this code changing.
    ///
    /// Refuses when both exist: the reader has used the new app, and there is no correct way to
    /// merge two ledgers that does not silently lose one side.
    @discardableResult
    public static func migrateLedgerDirectory(
        from legacy: URL, to current: URL, fileManager: FileManager = .default
    ) throws -> DirectoryResult {
        guard fileManager.fileExists(atPath: legacy.path) else { return .nothingToMove }
        guard !fileManager.fileExists(atPath: current.path) else { return .bothExist }

        // Counted before the move, because after it there is nothing left to count against.
        // A directory with no ledger in it is a legitimate thing to move, and reports zero.
        let expected = try lookupCount(inLedgerUnder: legacy, fileManager: fileManager)

        try fileManager.createDirectory(
            at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: legacy, to: current)

        let arrived = try lookupCount(inLedgerUnder: current, fileManager: fileManager)
        guard arrived == expected else {
            throw MigrationError.rowsLost(expected: expected, arrived: arrived)
        }
        return .moved(lookups: arrived)
    }

    private static func lookupCount(inLedgerUnder directory: URL, fileManager: FileManager) throws -> Int {
        let ledger = directory.appendingPathComponent(Self.ledgerFileName)
        guard fileManager.fileExists(atPath: ledger.path) else { return 0 }
        return try Ledger(path: ledger.path).lookupCount()
    }

    /// The database file inside the support directory, named here so the migration and the store
    /// cannot drift apart on it.
    public static let ledgerFileName = "ledger.sqlite"

    /// The name of the support directory the app used under its legacy name.
    public static let legacyDirectoryName = "Legacy"

    /// The support directory the app uses now.
    public static let directoryName = "XiaolaiDict"

    /// The defaults domain the app used under its legacy bundle identifier.
    public static let legacyDefaultsDomain = "com.xiaolaidict.legacy"

    /// Copies every key the `legacy` defaults domain holds into `current`, and returns how many
    /// were copied.
    ///
    /// Only keys that domain holds *itself*. `dictionaryRepresentation()` returns the merged view —
    /// the global domain, the argument domain and the registered defaults included — so copying it
    /// would pour every system-wide preference the process can see into the app's own domain.
    /// `CFPreferencesCopyKeyList` asks the narrower question, which is the one meant here.
    ///
    /// A key already present under `current` is left alone: the reader has set it since, and the
    /// legacy value is the stale one.
    @discardableResult
    public static func migrateDefaults(from legacy: String, to current: String) -> Int {
        guard let keys = keyList(of: legacy), !keys.isEmpty else { return 0 }
        let existing = Set(keyList(of: current) ?? [])

        var copied = 0
        for key in keys where !existing.contains(key) {
            guard let value = CFPreferencesCopyValue(
                key as CFString, legacy as CFString,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { continue }
            CFPreferencesSetValue(
                key as CFString, value, current as CFString,
                kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            copied += 1
        }
        if copied > 0 { CFPreferencesSynchronize(current as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) }
        return copied
    }

    /// The keys a domain holds itself, or nil where it holds none.
    ///
    /// Read and written through the same CoreFoundation pair on purpose. `UserDefaults(suiteName:)`
    /// is documented not to accept the running app's own bundle identifier, which is exactly what
    /// the destination is in the shipped app — so writing through it would work in every test and
    /// nowhere else.
    private static func keyList(of domain: String) -> [String]? {
        CFPreferencesCopyKeyList(
            domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
    }
}
