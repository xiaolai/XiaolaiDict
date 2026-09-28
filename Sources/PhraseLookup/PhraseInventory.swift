import AppleDictionaryFormat
import Foundation

extension PhraseReader {
    /// A detector over every installed dictionary that indexes English, with the sub-entry labels the
    /// reader's index already holds.
    ///
    /// **Here rather than in the service**, because both decisions it makes belong to the inventory: which
    /// dictionaries are read, and that the reader's index is opened through the door that cannot destroy it.
    /// It also keeps the service from importing a dictionary-format reader to do it.
    ///
    /// **Read-only, and having no index is not a failure to detect.** The read-write door drops every table
    /// when `user_version` differs and creates a file where none exists — measured in
    /// `IndexStoreReadOnlyTests`, where it drops the rows — so a lookup coming through it would silently
    /// delete the reader's index or leave an empty one behind. A reader who has never built one still gets
    /// the 104,009 phrases the keys hold; they lose the 935 that live only in `Body.data`, among them
    /// `take something into account` and `beat around the bush`.
    ///
    /// `report` is how the caller hears about it without this target binding a logger. Called at most once.
    public static func overInstalledDictionaries(
        indexPath: String = IndexStore.defaultURL.path,
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) -> PhraseReader {
        // Probed once, here, so a reader with no index is told once rather than once per dictionary. The
        // store is not kept: `IndexStore` is not `Sendable`, and `read()` runs on another queue.
        var hasIndex = false
        do {
            _ = try IndexStore(readingAt: indexPath)
            hasIndex = true
        } catch {
            report("no sub-entry labels — \(error)")
        }
        let available = hasIndex
        return PhraseReader(bundles: installed()) { bundle in
            guard available, let index = try? IndexStore(readingAt: indexPath) else { return [] }
            return (try? index.subEntryLabels(in: bundle.identifier)) ?? []
        }
    }
}
