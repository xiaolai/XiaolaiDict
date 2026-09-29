import Foundation

/// Where a reader's phrase inventories are kept, and the reason a dictionary is read only once.
///
/// **JSON in one small file per dictionary, not SQLite.** The whole of NOAD's is 632 KB and it is read whole
/// and queried in memory; a database would buy indexes nothing asks for and bring back the schema-version
/// hazard the phrase path just shed. Beside the index rather than inside it, so a reader who rebuilds or
/// deletes one does not lose the other.
public struct PhraseInventoryStore: Sendable {
    /// Alongside `index.sqlite`, in Application Support. Derived data that can always be rebuilt — but
    /// rebuilding is seconds, so unlike the index it would be no disaster to lose. It lives here anyway,
    /// because Caches is swept while a reader is mid-sentence.
    public static let defaultDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/XiaolaiDict/phrases")

    let directory: URL

    public init(directory: URL = PhraseInventoryStore.defaultDirectory) {
        self.directory = directory
    }

    /// One dictionary's inventory, read from disk where it is current and re-read from the body where it is
    /// not.
    ///
    /// **`contentVersion` decides, never the file's presence or its age.** Apple re-masters these — a stored
    /// inventory whose version does not match the bundle's is stale by definition, and a stale phrase list
    /// silently stops finding phrases the new build added.
    ///
    /// A write that fails is not a read that fails: the caller gets the inventory either way, and pays the
    /// seven seconds again next time.
    @discardableResult
    public func inventory(for bundle: DictionaryBundle) throws -> PhraseInventory {
        let wanted = bundle.contentVersion()
        if let stored = try? read(bundle.identifier), stored.contentVersion == wanted { return stored }
        let fresh = try PhraseInventory.read(bundle)
        try? write(fresh, for: bundle.identifier)
        return fresh
    }

    /// What is on disk for `identifier`, whatever version it is. Nil where there is nothing, or where the
    /// file cannot be read as one — a truncated write is not a valid inventory.
    public func read(_ identifier: String) throws -> PhraseInventory? {
        let url = file(for: identifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(PhraseInventory.self, from: Data(contentsOf: url))
    }

    func write(_ inventory: PhraseInventory, for identifier: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // **Written whole, then moved into place.** A reader who quits mid-write would otherwise leave a
        // half-file that decodes as nothing and is re-read every launch — the failure would be a feature
        // that silently costs seven seconds for ever rather than one that is noticed.
        let staged = file(for: identifier).appendingPathExtension("staging")
        try JSONEncoder().encode(inventory).write(to: staged, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(file(for: identifier), withItemAt: staged)
    }

    /// One file per dictionary, named by identifier rather than by display name — a name is localized, and a
    /// Chinese interface would file the same dictionary under a different one.
    func file(for identifier: String) -> URL {
        directory.appending(path: "\(identifier).json")
    }
}
