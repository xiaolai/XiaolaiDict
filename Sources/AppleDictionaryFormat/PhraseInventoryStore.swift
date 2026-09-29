import Foundation

/// Where a reader's phrase inventories are kept, and the reason a dictionary is read only once.
///
/// **One flat tab-separated file per dictionary, not SQLite and not JSON.** It is read whole and queried in
/// memory: 1.7 MB of strings parse in 0.08 s where the key indexes they replace cost 2.24 s to decompress. A
/// database would buy indexes nothing asks for and bring back the schema-version hazard the phrase path just
/// shed. Beside the index rather than inside it, so a reader who rebuilds or deletes one does not lose the
/// other.
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
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return PhraseInventory(decoding: text)
    }

    func write(_ inventory: PhraseInventory, for identifier: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // **Written whole, then moved into place.** A reader who quits mid-write would otherwise leave a
        // half-file that decodes as nothing and is re-read every launch — the failure would be a feature
        // that silently costs seven seconds for ever rather than one that is noticed.
        let staged = file(for: identifier).appendingPathExtension("staging")
        try Data(inventory.encoded().utf8).write(to: staged, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(file(for: identifier), withItemAt: staged)
    }

    /// One file per dictionary, named by identifier rather than by display name — a name is localized, and a
    /// Chinese interface would file the same dictionary under a different one.
    func file(for identifier: String) -> URL {
        directory.appending(path: "\(identifier).phrases")
    }
}
