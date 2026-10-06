import AppleDictionaryFormat
import DictionaryModel

/// Builds the form table the lemmatiser consults, from the reader's own English dictionaries.
///
/// The other adapter this module is: `AppleDictionaryFormat` knows what a dictionary prints and links nothing
/// but Foundation; `DictionaryModel` holds the table the lemmatiser reads and may not link the container
/// reader, because the app links it and the app must not (ADR-0010). This turns the one into the other, and
/// the dictionary service — the one process that links both — is where it runs (ADR-0051).
///
/// **Nothing here is distributed.** The table is derived on this Mac from dictionaries Apple licensed to it.
public enum FormTableReader {
    /// What one pass found, returned rather than logged: a table over no dictionary judges nothing and looks
    /// exactly like a reader whose words all happen to be the tagger's, so the numbers are how the two are
    /// told apart afterwards.
    public struct Reading: Sendable, Equatable {
        /// The table in force after the pass, or nil where no dictionary could be read and none was stored.
        public let table: FormTable?
        /// Whether the stored table was current and nothing was read from a dictionary's body.
        public let wasCurrent: Bool
        public let read: [String]
        public let failed: [String]
    }

    /// The table for the dictionaries installed on this Mac. What the service calls; `table(for:…)` is the same
    /// with the dictionaries named, for a caller that has them already and for tests.
    @discardableResult
    public static func read(store: FormTableStore = FormTableStore(),
                            report: (String) -> Void = { _ in }) -> Reading {
        table(for: DictionaryLocator.installed(), store: store, report: report)
    }

    /// The table for `bundles`, from the store where it is current and from the bodies where it is not.
    ///
    /// **`sources` decides, never the file's presence or age**: each dictionary's identifier and
    /// `contentVersion`, then the extraction's own version. Apple re-masters these, and a table built from an
    /// older master — or by older extraction — is stale by definition.
    ///
    /// **A dictionary that cannot be read is named and skipped, and the table is built from the others.** Its
    /// absence is recorded in the sources, so the next launch finds the table stale and tries again; it is
    /// never stored as though it had been read. A failed write is not a failed read: the caller has the table
    /// either way and pays the walk again next launch.
    ///
    /// `inventory` is injected so the build can be tested without a licensed dictionary on disk.
    public static func table(
        for bundles: [DictionaryBundle],
        store: FormTableStore = FormTableStore(),
        inventory: (DictionaryBundle, String) throws -> InflectionInventory = { try InflectionInventory.read($0, contentVersion: $1) },
        report: (String) -> Void = { _ in }
    ) -> Reading {
        let authorities = bundles.filter(\.isEnglishMonolingual)
        guard !authorities.isEmpty else {
            report("no English dictionary to read inflections from")
            return Reading(table: store.read(), wasCurrent: false, read: [], failed: [])
        }
        // **Hashed once.** `contentVersion()` reads both of a dictionary's files, which for NOAD is 100 MB.
        let versioned = authorities.map { bundle -> (bundle: DictionaryBundle, version: String, source: String) in
            let version = bundle.contentVersion()
            return (bundle, version, "\(bundle.identifier)\t\(version)")
        }
        let wanted = versioned.map(\.source).sorted() + [InflectionInventory.formatVersion]
        if let stored = store.read(), stored.sources == wanted {
            return Reading(table: stored, wasCurrent: true, read: authorities.map(\.displayName), failed: [])
        }

        var forms: [String: Set<FormTable.Reading>] = [:]
        var own = Set<String>()
        var headwords = Set<String>()
        var read: [String] = [], failed: [String] = []
        var sources: [String] = []
        for (bundle, version, source) in versioned {
            do {
                let found = try inventory(bundle, version)
                for (form, readings) in found.forms {
                    forms[form, default: []].formUnion(readings.map {
                        FormTable.Reading(lemma: $0.lemma, partOfSpeech: $0.partOfSpeech)
                    })
                }
                own.formUnion(found.ownHeadwords)
                headwords.formUnion(found.headwords)
                sources.append(source)
                read.append(bundle.displayName)
            } catch {
                report("could not read inflections from \(bundle.displayName): \(error)")
                failed.append(bundle.displayName)
            }
        }
        guard !read.isEmpty else { return Reading(table: store.read(), wasCurrent: false, read: read, failed: failed) }
        // **A form is a headword if any dictionary says so**, not only the one that printed it: `found` printed by
        // NOAD and titled by the thesaurus alone is still a word of its own, and each inventory could only see its
        // own titles.
        own.formUnion(Set(forms.keys).intersection(headwords))
        let table = FormTable(sources: sources.sorted() + [InflectionInventory.formatVersion],
                              forms: forms, ownHeadwords: own, words: headwords)
        do {
            try store.write(table)
        } catch {
            report("could not store the form table: \(error)")
        }
        return Reading(table: table, wasCurrent: false, read: read, failed: failed)
    }
}
