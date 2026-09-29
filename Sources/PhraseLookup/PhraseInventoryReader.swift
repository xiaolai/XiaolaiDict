import AppleDictionaryFormat

extension PhraseReader {
    /// A detector over the dictionaries **this reader** studies from, with every phrase's own meaning.
    ///
    /// **Scoped by `serves(reader:)`, which is the project's one predicate for this** — indexes English,
    /// explained in a language this reader reads (ADR-0027). An earlier version used a second, wider
    /// predicate of its own and admitted **34** dictionaries on this Mac, including a Korean pair that
    /// yields 1 English key out of 28,522. `serves(reader:)` admits 5 for a Simplified reader.
    ///
    /// **No index.** The inventory is a file per dictionary that a launch reads in a fraction of a second, so
    /// a reader who has never built an index — or whose index was written by a schema this build does not read
    /// — still gets the phrases. The first read walks each body once; the figures are in
    /// `dev-docs/wiring-phrase-lookup.md` rather than here, because they are per dictionary and NOAD is the
    /// largest.
    ///
    /// **A meaning is not promised for every phrase.** The key index contributes spellings without
    /// definitions — 9,740 of 103,517 phrases are explained — so `PhraseReader.filings(of:)` is empty for most
    /// of them, and that is the ordinary case rather than a gap.
    ///
    /// `report` is how the caller hears about it without this target binding a logger.
    /// `language` has **no default**, so this module states no policy about whose reader it is. The service
    /// passes `ReaderLanguage.preferred`; a test passes the audience it is measuring.
    ///
    /// **The order is `DictionaryLocator.installed()`'s, which is by identifier — not the reader's own.** Where
    /// two dictionaries explain the same phrase differently, the first identifier wins, and that is arbitrary.
    /// Said plainly rather than described as a preference it is not: honouring the reader's order needs the
    /// order, which lives in Dictionary.app's settings and does not reach this module.
    public static func forReader(
        _ language: String,
        store: PhraseInventoryStore = PhraseInventoryStore(),
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) -> PhraseReader {
        let serving = DictionaryLocator.installed().filter { $0.serves(reader: language) }
        report("\(serving.count) dictionaries serve \(language)")
        return PhraseReader(bundles: serving) { bundle in
            do {
                return try store.inventory(for: bundle)
            } catch {
                // A dictionary whose body cannot be read contributes nothing and is named. The others still
                // read: a reader with four dictionaries and one bad file keeps three quarters of the phrases.
                report("could not read \(bundle.displayName): \(error)")
                return nil
            }
        }
    }

}
