import Foundation
import Testing
@testable import AppleDictionaryFormat

/// Re-measures `SenseKey`'s headline claim **through the indexer that ships**, not through a probe.
///
/// The 100.00% figure in `SenseKey`'s docstring came from a Python probe whose sense selection and
/// definition extraction were written separately from `EntryIndexer`. Four times during this module's
/// construction a side-probe disagreed with the real extraction path and the path was right each time —
/// including three adapter declarations that claimed a publisher id the indexer could not find. So the
/// claim is re-established here, over real bundles, using the same code the app will run.
///
/// Gated on `XIAOLAIDICT_BUNDLES`; prints and returns when unset so the ordinary suite is unaffected.
@Suite struct SenseKeyValidityTests {
    @Test func aPublisherIDMapsToExactlyOneContentKey() throws {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else {
            print("SenseKeyValidityTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        let bundles = DictionaryLocator.installed(in: [URL(fileURLWithPath: root)])
        var forward: [String: Set<String>] = [:]      // publisher id -> content keys seen
        var reverse: [String: Set<String>] = [:]      // content key  -> publisher ids seen
        var pairs = 0, dictionariesWithIDs = 0

        for bundle in bundles {
            let profile = LanguageAdapters.profile(for: bundle.identifier)
            guard profile.expectsPublisherID else { continue }
            let indexer = EntryIndexer(dictionary: bundle.identifier, profile: profile)
            guard let entries = try? ContainerReader.entries(in: bundle.url) else { continue }
            var here = 0
            for xhtml in entries.prefix(1200) {
                guard let entry = indexer.index(xhtml) else { continue }
                let publisherIDs = entry.senses.compactMap { $0.key.origin == .publisher ? $0.key.value : nil }
                guard publisherIDs.count == entry.senses.count, !publisherIDs.isEmpty else { continue }
                // The same definitions the indexer used, keyed the content way for comparison.
                let content = SenseKey.keys(dictionary: bundle.identifier, entry: entry.entryID,
                                            definitions: entry.senses.map(\.definition))
                for (pid, ck) in zip(publisherIDs, content) {
                    // **Full keys, entry included.** Keying on dictionary+id alone would conflate two
                    // senses that live in different entries, and the content key is per-entry by
                    // construction — so comparing bare digests would compare two different things.
                    // Namespacing matters too: keyed globally the same measurement gave 99.39%,
                    // because sense ids repeat across dictionaries.
                    let publisherKey = SenseKey.publisher(
                        dictionary: bundle.identifier, entry: entry.entryID, id: pid).description
                    forward[publisherKey, default: []].insert(ck.description)
                    reverse[ck.description, default: []].insert(publisherKey)
                    pairs += 1
                    here += 1
                }
            }
            if here > 0 { dictionariesWithIDs += 1 }
        }

        guard pairs > 0 else {
            print("SenseKeyValidityTests: no id-bearing senses among the bundles, not measured"); return
        }
        let oneToOne = forward.values.count { $0.count == 1 }
        let oneFromOne = reverse.values.count { $0.count == 1 }
        let fwd = Double(oneToOne) / Double(forward.count)
        let rev = Double(oneFromOne) / Double(reverse.count)
        print(String(format: "SenseKeyValidityTests: %d pairs from %d dictionaries — forward %.2f%%, reverse %.2f%%",
                     pairs, dictionariesWithIDs, fwd * 100, rev * 100))

        // The forward direction is the load-bearing half: the key must be a function of the sense.
        #expect(fwd == 1.0, Comment(rawValue: String(
            format: "forward is %.4f, not exact — %d of %d publisher ids map to more than one content key",
            fwd, forward.count - oneToOne, forward.count)))
        // Reverse collisions are two senses worded identically; the ordinal handles them, so this is a
        // floor rather than a target.
        #expect(rev > 0.90, Comment(rawValue: String(format: "reverse %.2f%% is lower than expected", rev * 100)))
    }
}

extension SenseKeyValidityTests {
    /// **A sense block must yield exactly one sense.** The assertion, not just the fix.
    ///
    /// A block can hold several `d:def` elements — the extras are cross-references and regional-variant
    /// pointers, "American English = rappel" — and emitting one sense per `d:def` gave two senses the
    /// same publisher id with different text. 1,112 publisher ids collided that way, every one inside a
    /// single entry. The symptom was a dropped validation percentage, which is easy to explain away; this
    /// names the cause so it cannot come back quietly.
    @Test func noSenseBlockYieldsTwoSensesUnderOnePublisherID() throws {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else {
            print("SenseKeyValidityTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        var offenders: [String] = []
        var checked = 0
        for bundle in DictionaryLocator.installed(in: [URL(fileURLWithPath: root)]) {
            let profile = LanguageAdapters.profile(for: bundle.identifier)
            guard profile.expectsPublisherID,
                  let entries = try? ContainerReader.entries(in: bundle.url) else { continue }
            let indexer = EntryIndexer(dictionary: bundle.identifier, profile: profile)
            for xhtml in entries.prefix(800) {
                guard let entry = indexer.index(xhtml) else { continue }
                let ids = entry.senses.compactMap { $0.key.origin == .publisher ? $0.key.value : nil }
                guard !ids.isEmpty else { continue }
                checked += 1
                if Set(ids).count != ids.count, offenders.count < 5 {
                    offenders.append("\(bundle.identifier)/\(entry.entryID) repeats a publisher id "
                                     + "across \(ids.count) senses")
                }
            }
        }
        print("SenseKeyValidityTests: \(checked) id-bearing entries checked for repeated ids")
        #expect(offenders.isEmpty, Comment(rawValue: offenders.joined(separator: "; ")))
    }
}

extension SenseKeyValidityTests {
    /// **A sense block keeps every definition it holds.** The other half of the assertion.
    ///
    /// Emitting one sense per `d:def` gave 1,112 publisher ids two identities. Keeping only the *first*
    /// `d:def` fixed that and silently destroyed content: 譯典通's entry for 一 has one sense block
    /// holding "one", "one only", "alone", "once", "undivided", "throughout" — six glosses, of which five
    /// were lost. One sense, all its text, is the only reading that is wrong in neither direction, and
    /// the collision test alone would not have caught the loss.
    @Test func aSenseBlockKeepsEveryDefinitionItHolds() throws {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else {
            print("SenseKeyValidityTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        var worstLoss = 0.0, worstName = "", checked = 0
        for bundle in DictionaryLocator.installed(in: [URL(fileURLWithPath: root)]) {
            guard let entries = try? ContainerReader.entries(in: bundle.url) else { continue }
            let indexer = EntryIndexer(bundle: bundle)
            var defsInMarkup = 0, defsKept = 0
            for xhtml in entries.prefix(400) {
                guard let entry = indexer.index(xhtml) else { continue }
                // Every d:def the markup declares, against every one that survived into a sense.
                defsInMarkup += xhtml.components(separatedBy: "d:def=").count - 1
                defsKept += entry.senses.reduce(0) { $0 + $1.definition.components(separatedBy: "; ").count }
            }
            guard defsInMarkup > 20 else { continue }
            checked += 1
            let kept = Double(defsKept) / Double(defsInMarkup)
            if 1 - kept > worstLoss { worstLoss = 1 - kept; worstName = bundle.identifier }
        }
        print(String(format: "SenseKeyValidityTests: %d dictionaries; worst definition loss %.1f%% (%@)",
                     checked, worstLoss * 100, worstName))
        // A d:def can sit outside any sense block, so perfect retention is not expected — but losing
        // most of them is the regression this names.
        #expect(worstLoss < 0.50, Comment(rawValue: String(
            format: "%@ retains only %.0f%% of its declared definitions", worstName, (1 - worstLoss) * 100)))
    }
}
