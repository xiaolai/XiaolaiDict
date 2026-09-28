import Foundation
import Testing
@testable import AppleDictionaryFormat

/// **How many of a dictionary's senses the publisher itself names, and by which attribute.**
///
/// This is the number a cross-dictionary alignment rests on. A pair anchored on a publisher id survives the
/// publisher reworking the wording; a pair anchored on a content key does not — rewording changes the key,
/// which is correct for the key and fatal for a stored pair. So "what share of each side can be anchored
/// durably" has to be known *before* a table is designed, not discovered after it is full.
///
/// **Measured through `EntryIndexer`, which is the point.** The same question asked of a Python probe once
/// answered 100.00% where the shipping path answered 98.45%, because the probe's own sense selection differed
/// from the reader's. Two indexers run over one body pass here — the default profile, which accepts either
/// attribute, and one pinned to `lexid` — so the union and the split come from the code that will do the
/// extraction.
///
/// Gated on `XIAOLAIDICT_BUNDLES`; prints "not measured" and returns when unset.
@Suite struct SenseIdentityCoverageTests {
    struct Coverage {
        var identifier = ""
        var entries = 0
        var senses = 0
        /// Senses the publisher names by either attribute.
        var named = 0
        /// Of those, the ones a `lexid`-pinned reader finds.
        var byLexid = 0
        /// Senses in a sub-entry — a phrasal verb or idiom — counted because they are the ones a phrase
        /// lookup needs and the ones most likely to lack an id of their own.
        var inSubEntry = 0
        var namedInSubEntry = 0

        var share: Double { senses > 0 ? Double(named) / Double(senses) : 0 }
        var subEntryShare: Double {
            inSubEntry > 0 ? Double(namedInSubEntry) / Double(inSubEntry) : 0
        }
    }

    @Test func everyDictionaryReportsHowManySensesThePublisherNames() throws {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else {
            print("SenseIdentityCoverageTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        var rows: [Coverage] = []
        for bundle in DictionaryLocator.installed(in: [URL(fileURLWithPath: root)]) {
            let profile = bundle.profile
            // The default accepts either attribute, so this is the union.
            let either = EntryIndexer(dictionary: bundle.identifier, profile: profile)
            // Pinned, to split the union rather than infer the split from two totals.
            let lexid = EntryIndexer(dictionary: bundle.identifier, profile: DictionaryProfile(
                identifier: profile.identifier, senseDepth: profile.senseDepth,
                senseIDAttributes: ["lexid"]))
            var row = Coverage(identifier: bundle.identifier)
            guard (try? ContainerReader.forEachEntry(in: bundle.url) { xhtml in
                guard let entry = either.index(xhtml) else { return }
                row.entries += 1
                row.senses += entry.senses.count
                row.named += entry.senses.count { $0.key.origin == .publisher }
                let sub = entry.senses.filter { $0.position.subEntry != nil }
                row.inSubEntry += sub.count
                row.namedInSubEntry += sub.count { $0.key.origin == .publisher }
                row.byLexid += lexid.index(xhtml)?.senses
                    .count { $0.key.origin == .publisher } ?? 0
            }) != nil else { continue }
            guard row.senses > 0 else { continue }
            rows.append(row)
        }
        guard !rows.isEmpty else {
            print("SenseIdentityCoverageTests: no dictionary yielded a sense, not measured"); return
        }
        print("SenseIdentityCoverageTests: \(rows.count) dictionaries")
        for row in rows.sorted(by: { $0.identifier < $1.identifier }) {
            print(String(format: """
                          %-24@ %7d senses  publisher-named %7d  %6.2f%%  \
                         (lexid %7d, id %7d)  sub-entry %6d named %6d  %6.2f%%
                         """,
                         row.identifier.replacingOccurrences(of: "com.apple.dictionary.", with: ""),
                         row.senses, row.named, row.share * 100,
                         row.byLexid, row.named - row.byLexid,
                         row.inSubEntry, row.namedInSubEntry, row.subEntryShare * 100))
        }
        // A publisher cannot name more senses than exist, and the pinned reader cannot find more than the
        // reader that accepts either attribute. Both would mean the two passes disagree about the senses.
        #expect(rows.allSatisfy { $0.named <= $0.senses },
                "a dictionary named more senses than it has")
        #expect(rows.allSatisfy { $0.byLexid <= $0.named },
                "a `lexid`-pinned reader found more ids than one accepting either attribute")
        #expect(rows.allSatisfy { $0.namedInSubEntry <= $0.inSubEntry })
        // The measurement must have happened: a dictionary with senses and no coverage figure at all would
        // otherwise read as 0% rather than as unmeasured.
        #expect(rows.contains { $0.named > 0 },
                "not one dictionary named a single sense, which no catalogue would do")
    }

    /// **What a thesaurus sense actually stores** — printed, because the answer decides whether an alignment
    /// has anything to match on.
    @Test func aThesaurusSenseShowsWhatWasExtracted() throws {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else {
            print("SenseIdentityCoverageTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        guard let oawt = DictionaryLocator.installed(in: [URL(fileURLWithPath: root)])
            .first(where: { $0.identifier.hasSuffix("OAWT") }) else {
            print("SenseIdentityCoverageTests: OAWT not installed, not measured"); return
        }
        let indexer = EntryIndexer(bundle: oawt)
        var shown = 0, words = 0, senses = 0
        _ = try? ContainerReader.forEachEntry(in: oawt.url, limit: 400) { xhtml in
            guard let entry = indexer.index(xhtml) else { return }
            for sense in entry.senses {
                senses += 1
                // How many words the stored definition holds. A gloss is a phrase; a synonym is a word.
                if sense.definition.split(separator: " ").count == 1 { words += 1 }
                if shown < 6 {
                    shown += 1
                    print("""
                          OAWT \(entry.headword) / \(sense.key.origin) \(sense.key.value) \
                          pos=\(sense.partOfSpeech ?? "-") → "\(sense.definition)"
                          """)
                }
            }
        }
        print("SenseIdentityCoverageTests: OAWT \(senses) senses sampled, "
              + "\(words) hold a single word (\(senses > 0 ? 100 * words / senses : 0)%)")
    }
}
