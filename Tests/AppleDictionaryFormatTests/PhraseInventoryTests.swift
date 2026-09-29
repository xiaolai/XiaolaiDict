import Foundation
import Testing
@testable import AppleDictionaryFormat

/// **Where the phrase inventory comes from, measured against the dictionaries on this machine.**
///
/// `PhraseSpanTests` covers the matcher against a fixture. This covers the claim the matcher rests on:
/// that a real dictionary spells its slots, that its key index is not the whole list, and that a
/// separable phrasal verb is *not* marked — so the two classes of gap are real and not a story.
///
/// Gated on `XIAOLAIDICT_BUNDLES`, and prints "not measured" when unset: a green suite is not a suite
/// that ran. No fixture is committed — the figures are about a licensed dictionary's structure, and the
/// text stays on the reader's own Mac.
@Suite struct PhraseInventoryTests {
    static var noad: URL? {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else { return nil }
        return FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { $0.pathExtension == "dictionary"
                && $0.lastPathComponent.contains("New Oxford American") }
    }

    /// **The publisher writes the slot down.** This is the whole basis for matching a split phrase, so if
    /// a future dictionary version stopped marking slots the feature would silently degrade to contiguous
    /// matching — which is exactly the failure this asserts against.
    @Test func theKeyIndexCarriesSlottedTemplates() throws {
        guard let noad = Self.noad else {
            print("PhraseInventoryTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        let spans = try PhraseSpans(bundle: noad)
        // Templates are built on demand now, so the slotted ones are counted from the phrases.
        let slotted = spans.phrases.compactMap(PhraseSpans.Template.init(phrase:)).filter { $0.runs.count > 1 }
        print("PhraseInventoryTests: \(spans.phrases.count) multi-word keys, \(slotted.count) slotted")
        #expect(spans.phrases.count > 90_000, "measured 104,009 on 2026-09-29")
        #expect(slotted.count > 1_000, "measured 1,572 — the templates a split phrase is matched against")
    }

    /// **The key index is not the whole inventory**, which is the concrete thing the body walk buys.
    /// Measured 2026-09-29: 9,755 sub-entry labels, 935 of them in no key of any group.
    @Test func thePhrasesAReaderMeetsLiveOnlyInTheSubEntryLabels() throws {
        guard let url = Self.noad, let bundle = try? DictionaryLocator.describe(url) else {
            print("PhraseInventoryTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        let keys = try PhraseSpans(bundle: url).phrases
        let indexer = EntryIndexer(bundle: bundle)
        var labels = Set<String>()
        try ContainerReader.forEachEntry(in: url) { xhtml in
            guard let entry = indexer.outcome(for: xhtml).entry else { return }
            for sense in entry.senses {
                if let sub = sense.position.subEntry { labels.insert(sub.lowercased()) }
            }
        }
        let onlyInLabels = labels.subtracting(keys)
        print("PhraseInventoryTests: \(labels.count) labels, \(onlyInLabels.count) in no key")
        #expect(labels.count > 8_000, "measured 9,755")
        #expect(onlyInLabels.count > 500, "measured 935")
        // Each of these is a phrase a reader meets and would not think to look up, and each is absent
        // from `KeyText.data` in every form. They are the case for the body walk, named individually so
        // the claim cannot quietly become untrue.
        for phrase in ["take something into account", "beat around the bush",
                       "once in a blue moon", "cost an arm and a leg"] {
            #expect(!keys.contains(phrase), "\(phrase) unexpectedly became a key")
            #expect(labels.contains(phrase), "\(phrase) is no longer a sub-entry label either")
        }
    }

    /// **And a plain phrasal verb is not marked**, which is why `Separation.inferred` exists at all. If
    /// NOAD ever started filing `turn something down`, the inference would become unnecessary for it —
    /// and this test is how that would be noticed rather than assumed.
    @Test func aBarePhrasalVerbCarriesNoSlot() throws {
        guard let url = Self.noad, let bundle = try? DictionaryLocator.describe(url) else {
            print("PhraseInventoryTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        let indexer = EntryIndexer(bundle: bundle)
        var labels = Set<String>()
        try ContainerReader.forEachEntry(in: url) { xhtml in
            guard let entry = indexer.outcome(for: xhtml).entry else { return }
            for sense in entry.senses {
                if let sub = sense.position.subEntry { labels.insert(sub.lowercased()) }
            }
        }
        for bare in ["turn down", "give away", "look after"] {
            #expect(labels.contains(bare), "\(bare) is no longer a sub-entry")
        }
        for slotted in ["turn something down", "give something away", "look something up"] {
            #expect(!labels.contains(slotted), "\(slotted) is now marked — the inference can retire for it")
        }
    }
}
