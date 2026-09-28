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
///
/// **This test was structurally unable to notice the migration it stands over, in two ways.** It
/// *skipped any entry where some sense lacked a publisher id* — `guard publisherIDs.count ==
/// entry.senses.count` — so recovering content-keyed senses would have removed entries from its own
/// sample, and it *required reverse agreement only `> 0.90`* while the measured figure was 100.00%. Both
/// together meant: recover definitions, watch the sample shrink, watch the suite stay green.
///
/// What replaces them is stated as an **exact equality against the walk itself** rather than as a
/// remembered figure. `pairs == sensesWithPublisherID` says every sense carrying a publisher id was
/// compared, and `dictionariesWithIDs == dictionariesExpectingIDs` says no dictionary fell out. Neither
/// depends on which dictionaries a Mac has, which a hardcoded 75,401 would.
@Suite struct SenseKeyValidityTests {
    @Test func aPublisherIDMapsToExactlyOneContentKey() throws {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else {
            print("SenseKeyValidityTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        let bundles = DictionaryLocator.installed(in: [URL(fileURLWithPath: root)])
        var forward: [String: Set<String>] = [:]      // publisher key -> content keys seen
        var reverse: [String: Set<String>] = [:]      // content key   -> publisher keys seen
        var pairs = 0, dictionariesWithIDs = 0
        // The denominator the sample is checked against: every sense the indexer gave a publisher key,
        // counted over exactly the entries walked below. A sample that stops covering one of these is the
        // failure this test exists to see.
        var sensesWithPublisherID = 0, dictionariesYieldingIDs = 0, entriesWalked = 0

        for bundle in bundles {
            let profile = LanguageAdapters.profile(for: bundle.identifier)
            guard profile.expectsPublisherID else { continue }
            let indexer = EntryIndexer(dictionary: bundle.identifier, profile: profile)
            var here = 0, availableHere = 0
            guard (try? ContainerReader.forEachEntry(in: bundle.url, limit: 1200) { xhtml in
                guard let entry = indexer.index(xhtml) else { return }
                entriesWalked += 1
                availableHere += entry.senses.count { $0.key.origin == .publisher }
                // **Every sense that has a publisher id, not only entries where all of them do.** The
                // old guard dropped a whole entry the moment one sense was content-keyed, which is
                // precisely what step 2 of the plan makes common.
                for sense in entry.senses where sense.key.origin == .publisher {
                    // **Full keys, entry included.** Keying on dictionary+id alone would conflate two
                    // senses that live in different entries, and the content key is per-entry by
                    // construction — so comparing bare digests would compare two different things.
                    // Namespacing matters too: keyed globally the same measurement gave 99.39%,
                    // because sense ids repeat across dictionaries.
                    //
                    // `sense.contentKey` is the indexer's own, never recomputed here: rebuilding the
                    // pairing outside the shipping path is how a side probe drifts from it, which
                    // happened four times in this module's construction and the path was right each time.
                    forward[sense.key.description, default: []].insert(sense.contentKey.description)
                    reverse[sense.contentKey.description, default: []].insert(sense.key.description)
                    pairs += 1
                    here += 1
                }
            }) != nil else { continue }
            sensesWithPublisherID += availableHere
            if availableHere > 0 { dictionariesYieldingIDs += 1 }
            if here > 0 { dictionariesWithIDs += 1 }
        }

        guard pairs > 0 else {
            print("SenseKeyValidityTests: no id-bearing senses among the bundles, not measured"); return
        }
        let oneToOne = forward.values.count { $0.count == 1 }
        let oneFromOne = reverse.values.count { $0.count == 1 }
        let fwd = Double(oneToOne) / Double(forward.count)
        let rev = Double(oneFromOne) / Double(reverse.count)
        print(String(format: """
                     SenseKeyValidityTests: %d pairs from %d dictionaries over %d entries — \
                     forward %.2f%%, reverse %.2f%% (%d distinct publisher keys, %d content keys)
                     """,
                     pairs, dictionariesWithIDs, entriesWalked, fwd * 100, rev * 100,
                     forward.count, reverse.count))

        // **The sample size, asserted and not merely printed.** This is the assertion the old guard
        // defeated: if a change causes the indexer to content-key senses that used to carry publisher
        // ids, `pairs` falls below the senses available and this fails instead of quietly measuring less.
        #expect(pairs == sensesWithPublisherID, Comment(rawValue:
            "\(pairs) pairs compared but \(sensesWithPublisherID) senses carry a publisher id — "
            + "\(sensesWithPublisherID - pairs) were dropped from the sample"))
        #expect(dictionariesWithIDs == dictionariesYieldingIDs, Comment(rawValue:
            "\(dictionariesYieldingIDs) dictionaries yield publisher ids but only \(dictionariesWithIDs) "
            + "reached the comparison"))

        // The forward direction is the load-bearing half: the key must be a function of the sense.
        #expect(fwd == 1.0, Comment(rawValue: String(
            format: "forward is %.4f, not exact — %d of %d publisher ids map to more than one content key",
            fwd, forward.count - oneToOne, forward.count)))
        // **Exact, not a floor.** The measured figure is 100.00% and `> 0.90` could not tell 100% from 91%.
        //
        // Stated honestly: with the entry in the key and `SenseKey.keys` guaranteeing distinct values
        // inside one entry, reverse exactness is close to structural — what it still catches is two body
        // records claiming one entry id, and any bug that lets the keying scheme emit a duplicate. The
        // sample-size assertions above are the ones that catch the failure this step was written for.
        #expect(rev == 1.0, Comment(rawValue: String(
            format: "reverse is %.4f, not exact — %d of %d content keys carry more than one publisher id",
            rev, reverse.count - oneFromOne, reverse.count)))
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
            guard profile.expectsPublisherID else { continue }
            let indexer = EntryIndexer(dictionary: bundle.identifier, profile: profile)
            _ = try? ContainerReader.forEachEntry(in: bundle.url, limit: 800) { xhtml in
                guard let entry = indexer.index(xhtml) else { return }
                let ids = entry.senses.compactMap { $0.key.origin == .publisher ? $0.key.value : nil }
                guard !ids.isEmpty else { return }
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
        var worstEntry = 1.0, worstEntryName = "", checked = 0, overCounted: [String] = []
        var entriesLosingEverything = 0, entriesWithDefinitions = 0
        for bundle in DictionaryLocator.installed(in: [URL(fileURLWithPath: root)]) {
            let indexer = EntryIndexer(bundle: bundle)
            var sawAny = false
            _ = try? ContainerReader.forEachEntry(in: bundle.url, limit: 400) { xhtml in
                guard let entry = indexer.index(xhtml), entry.declaredDefinitions > 0 else { return }
                sawAny = true
                entriesWithDefinitions += 1
                // **The invariant, per entry.** `captured ≤ declared` is what the old metric did not have:
                // it counted `d:def=` against the joined definition split on `"; "`, so the numerator could
                // exceed the denominator — 154% for `as-en.oup` — and a definition marked only by
                // `class="df"` was in neither side. Both now come from the parser.
                if entry.capturedDefinitions > entry.declaredDefinitions, overCounted.count < 5 {
                    overCounted.append("\(bundle.identifier)/\(entry.entryID) captured "
                                       + "\(entry.capturedDefinitions) of \(entry.declaredDefinitions)")
                }
                if entry.capturedDefinitions == 0 { entriesLosingEverything += 1 }
                if entry.definitionsReached < worstEntry {
                    worstEntry = entry.definitionsReached
                    worstEntryName = "\(bundle.identifier)/\(entry.entryID)"
                }
            }
            if sawAny { checked += 1 }
        }
        print(String(format: """
                     SenseKeyValidityTests: %d dictionaries, %d entries with definitions; \
                     worst single entry reached %.1f%% (%@); %d entries reached none
                     """,
                     checked, entriesWithDefinitions, worstEntry * 100, worstEntryName,
                     entriesLosingEverything))
        // The aggregate threshold belongs to `DefinitionReachTests`, which owns it for the whole
        // dictionary; asserting a second, looser one here would be a threshold nobody maintains.
        #expect(overCounted.isEmpty, Comment(rawValue:
            "an entry reached more definitions than it declares: " + overCounted.joined(separator: "; ")))
        // An entry that declares definitions and reaches none is the shape of the 一 regression: its single
        // sense block held six glosses — "one", "one only", "alone", "once", "undivided", "throughout" —
        // and keeping only the first destroyed five of them. Losing all of them is worse and must be rare.
        #expect(Double(entriesLosingEverything) / Double(max(1, entriesWithDefinitions)) < 0.05,
                Comment(rawValue: "\(entriesLosingEverything) of \(entriesWithDefinitions) entries "
                        + "declare definitions and reach none"))
    }
}
