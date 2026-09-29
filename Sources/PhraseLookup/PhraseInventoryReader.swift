import AppleDictionaryFormat
import DictionaryModel
import Foundation

extension PhraseReader {
    /// A detector over the dictionaries **this reader** studies from, with every phrase's own meaning.
    ///
    /// **Scoped by `serves(reader:)`, which is the project's one predicate for this** — indexes English,
    /// explained in a language this reader reads (ADR-0027). An earlier version used a second, wider
    /// predicate of its own and admitted **34** dictionaries on this Mac, including a Korean pair that
    /// yields 1 English key out of 28,522. `serves(reader:)` admits 5 for a Simplified reader.
    ///
    /// **No index.** The phrase inventory is a 632 KB file per dictionary read in 7 s, so a reader who has
    /// never built an index — or whose index was written by a schema this build does not read — still gets
    /// every phrase *and* every meaning. That was not true of the version this replaces.
    ///
    /// `report` is how the caller hears about it without this target binding a logger.
    /// `language` has **no default**, so this module states no policy about whose reader it is. The service
    /// passes `ReaderLanguage.preferred`; a test passes the audience it is measuring.
    public static func forReader(
        _ language: String,
        store: PhraseInventoryStore = PhraseInventoryStore(),
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) -> PhraseReader {
        let serving = DictionaryLocator.installed().filter { $0.serves(reader: language) }
        report("\(serving.count) dictionaries serve \(language)")
        return PhraseReader(bundles: serving) { bundle in
            do {
                return try store.inventory(for: bundle).meanings
            } catch {
                // A dictionary whose body cannot be read contributes nothing and is named. The others still
                // read: a reader with four dictionaries and one bad file keeps four fifths of their phrases.
                report("could not read \(bundle.displayName): \(error)")
                return [:]
            }
        }
    }

}
