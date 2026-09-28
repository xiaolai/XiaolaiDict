import Foundation
import Testing
import XiaolaiDictTestSupport
@testable import AppleDictionaryFormat

/// The rebuild decision, tested without a body pass.
///
/// The rule is a pure function on three facts, so it is checked here rather than by resolving a 230 MB
/// dictionary three times to find out what the driver would have decided.
@Suite struct RebuildDecisionTests {
    static func report(groups: Int = 1000, agreement: Double, checked: Int = 1000) -> KeyResolutionReport {
        var r = KeyResolutionReport()
        r.groups = groups
        r.resolved = groups
        r.displayFormAgreement = agreement
        r.displayFormsChecked = checked
        return r
    }

    @Test func aVerifiedMappingWithChangedContentIsRebuilt() {
        let decision = RebuildDecision.decide(needsRebuild: true, report: Self.report(agreement: 0.95))
        #expect(decision == .rebuild)
    }

    @Test func aVerifiedMappingWithNothingChangedIsLeftAlone() {
        #expect(RebuildDecision.decide(needsRebuild: false, report: Self.report(agreement: 0.95))
                == .upToDate)
    }

    /// **Refusal comes before "up to date".** Deciding a dictionary is current before checking its mapping
    /// would let one indexed under an earlier, laxer rule stay indexed for ever.
    @Test func anUnverifiedMappingIsRefusedEvenWhenNothingChanged() {
        for agreement in [0.0, 0.06, 0.49, 0.6, 0.79] {
            let decision = RebuildDecision.decide(needsRebuild: false, report: Self.report(agreement: agreement))
            guard case .refuse(.keyMappingNotVerified(_, let measured)) = decision else {
                Issue.record("agreement \(agreement) was not refused: \(decision)")
                continue
            }
            #expect(measured == agreement)
        }
    }

    /// The threshold itself: 0.80 is the documented bar, and it is inclusive.
    @Test func theBarIsEightyPercentAndItIsInclusive() {
        #expect(RebuildDecision.decide(needsRebuild: true, report: Self.report(agreement: 0.80))
                == .rebuild)
        guard case .refuse = RebuildDecision.decide(needsRebuild: true,
                                                    report: Self.report(agreement: 0.7999)) else {
            Issue.record("just below the bar was not refused"); return
        }
    }

    /// A mapping nothing checked is never treated as passing.
    @Test func anUnmeasuredMappingIsRefused() {
        var r = Self.report(agreement: 0)
        r.displayFormsChecked = 0
        guard case .refuse(.keyMappingNotVerified(let confidence, _)) =
                RebuildDecision.decide(needsRebuild: true, report: r) else {
            Issue.record("an unmeasured mapping was not refused"); return
        }
        #expect(confidence == .unmeasured)
    }

    @Test func noKeyGroupsIsItsOwnRefusal() {
        var r = Self.report(agreement: 1.0)
        r.groups = 0
        guard case .refuse(.noKeyIndex) = RebuildDecision.decide(needsRebuild: true, report: r) else {
            Issue.record("a dictionary with no key index was not refused for that reason"); return
        }
    }

    /// **A refusal withdraws whatever was indexed before.**
    ///
    /// Returning `.refused` while leaving the rows in place meant a dictionary that had passed once stayed
    /// searchable after it stopped passing — `candidates(for:)` does not filter by verification status, so
    /// checking refusal before freshness bought nothing.
    @Test func aRefusalRemovesWhatWasIndexedBefore() throws {
        let store = try IndexStore(path: ":memory:")
        try store.beginRebuild(identifier: "d", displayName: "d", contentVersion: "1.0",
                               keyConfidence: "verified")
        let key = SenseKey(dictionary: "d", entry: "e", value: "k1", origin: .content)
        try store.insert(IndexedEntry(entryID: "e", headword: "give", homograph: nil,
                                      senses: [IndexedSense(key: key, contentKey: key,
                                                            position: .unplaced,
                                                            definition: "to hand over")]),
                         dictionary: "d", aliases: [SearchAlias(search: "give", display: "give")])
        #expect(try store.candidates(for: "give").count == 1)

        // A refusal for a reason that is about the dictionary must take its rows with it.
        try store.forget("d")
        #expect(try store.candidates(for: "give").isEmpty)
        #expect(try store.needsRebuild("d", contentVersion: "1.0") == true,
                "a withdrawn dictionary must look unbuilt, or it will never be reconsidered")
    }

    /// A storage failure is **not** a verdict about the dictionary, and must not delete its rows.
    @Test func aStorageFailureIsNotADictionaryVerdict() {
        let why = RebuildRefusal.storageFailure("database is locked")
        #expect(why.description.contains("The dictionary is fine"))
        #expect(!why.description.contains("key mapping"))
        #expect(!why.withdrawsTheIndex, "a store failure would have deleted a good index")
    }

    /// **Every refusal that is a verdict about the dictionary withdraws its index.**
    ///
    /// Stated as a property of the reason rather than checked at each `return`, because three early returns
    /// decided it for themselves and got it wrong: a dictionary that lost its `KeyText.data` was reported
    /// refused while its previous candidates stayed searchable.
    @Test func everyDictionaryVerdictWithdrawsTheIndex() {
        let verdicts: [RebuildRefusal] = [
            .keyMappingNotVerified(confidence: .disagrees, agreement: 0.06),
            .keyMappingNotVerified(confidence: .unmeasured, agreement: 0),
            .containerUnreadable("KeyText.data: no chunks at 68"),
            .noKeyIndex("0 key groups parsed"),
            .noEntries,
        ]
        for why in verdicts {
            #expect(why.withdrawsTheIndex, "\(why) left a stale index searchable")
        }
        #expect(!RebuildRefusal.storageFailure("locked").withdrawsTheIndex)
    }

    /// An empty replacement must roll back rather than commit over a good index.
    ///
    /// `beginRebuild` deletes the previous index first, so returning `.noEntries` after the commit destroyed
    /// it *and* recorded the empty result as current — worse than either outcome alone.
    @Test func anEmptyReplacementRollsBackRatherThanCommitting() throws {
        let store = try IndexStore(path: ":memory:")
        try store.beginRebuild(identifier: "d", displayName: "d", contentVersion: "1.0",
                               keyConfidence: "verified")
        let key = SenseKey(dictionary: "d", entry: "e", value: "k1", origin: .content)
        try store.insert(IndexedEntry(entryID: "e", headword: "give", homograph: nil,
                                      senses: [IndexedSense(key: key, contentKey: key,
                                                            position: .unplaced,
                                                            definition: "to hand over")]),
                         dictionary: "d", aliases: [SearchAlias(search: "give", display: "give")])

        struct NoEntries: Error {}
        #expect(throws: NoEntries.self) {
            try store.inTransaction {
                try store.beginRebuild(identifier: "d", displayName: "d", contentVersion: "2.0",
                                       keyConfidence: "verified")
                throw NoEntries()
            }
        }
        #expect(try store.candidates(for: "give").count == 1, "the previous index was destroyed")
        #expect(try store.dictionaries().map(\.contentVersion) == ["1.0"],
                "the empty replacement's version was recorded as current")
    }

    /// **The refusal must say something a reader could act on.** "Skipped" is not a reason.
    @Test func aRefusalNamesItsMeasurementAndItsBar() {
        let why = RebuildRefusal.keyMappingNotVerified(confidence: .disagrees, agreement: 0.06)
        #expect(why.description.contains("disagrees"))
        #expect(why.description.contains("6.0%"))
        #expect(why.description.contains("80%"), "the bar it missed")
        // And it must not claim the dictionary is broken — agreement measures a chain, not the mapping.
        #expect(why.description.contains("Nothing is known to be wrong"))

        let outcome = RebuildOutcome(identifier: "d", displayName: "Hebrew", verdict: .refused(why))
        #expect(outcome.summary.hasPrefix("Hebrew: not indexed, because"))
        #expect(outcome.wasRefused)
        #expect(!outcome.wasRebuilt)
    }
}

/// The driver end to end, against a real bundle. Gated on `XIAOLAIDICT_BUNDLES`.
///
/// **Deliberately the smallest verified dictionary available**, not every installed one: the point is that
/// the orchestration behaves, and resolving one dictionary is three body passes. `DictionarySurvey` is what
/// measures the whole catalogue.
@Suite struct IndexRebuilderMeasurementTests {
    static func bundles() -> [DictionaryBundle] {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else { return [] }
        return DictionaryLocator.installed(in: [URL(fileURLWithPath: root)])
    }

    /// Installed bundles, smallest body first, so the end-to-end check is seconds rather than minutes.
    /// Ordered by measurement rather than named: which dictionaries a Mac has depends on its region.
    static func smallestFirst() -> [DictionaryBundle] {
        bundles().compactMap { bundle -> (DictionaryBundle, Int)? in
            guard let body = try? ContainerReader.bodyURL(of: bundle.url),
                  let size = (try? FileManager.default.attributesOfItem(atPath: body.path))?[.size] as? Int
            else { return nil }
            return (bundle, size)
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    /// **The three checks step 5 of the plan names**, in one run: a rebuild, a second run that writes
    /// nothing, and a bumped extractor generation that rebuilds anyway.
    ///
    /// **It walks candidates smallest-first until one actually rebuilds, and that is not tidiness.** Picking
    /// "the smallest bundle" chose `com.apple.dictionary.AppleDictionary` — the catalogue's one unreadable
    /// asset — so the test took the refusal branch and returned green having exercised none of the three
    /// checks. A refusal is a legitimate outcome for a *dictionary* and is never a legitimate outcome for
    /// *this test*, so the two are now separated: refusals are counted and reported, and the run fails if no
    /// dictionary was ever rebuilt.
    @Test func aRunRebuildsThenASecondRunWritesNothing() throws {
        guard ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] != nil else {
            print("IndexRebuilderMeasurementTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        // **Configured but empty is a failure, not a skip.** Returning early on an empty candidate list
        // conflated "no variable" with "a directory holding nothing readable", so a mistyped path reported
        // "not measured" and passed.
        let candidates = Self.smallestFirst()
        try #require(!candidates.isEmpty,
                     "XIAOLAIDICT_BUNDLES is set but yielded no bundle with a readable body")
        let scratch = TemporaryDirectory(named: "adf-rebuild")
        let store = try IndexStore(path: scratch.appending("index.sqlite").path)
        let rebuilder = IndexRebuilder(store: store)

        var stages: Set<IndexRebuilder.Progress.Stage> = []
        var rebuilt: (bundle: DictionaryBundle, entries: Int, senses: Int, aliases: Int)?
        var refusals: [String] = []
        for bundle in candidates {
            stages = []
            let outcome = rebuilder.rebuild([bundle]) { stages.insert($0.stage) }[0]
            print("IndexRebuilder: \(outcome.summary)")
            switch outcome.verdict {
            case .rebuilt(let entries, let senses, let aliases):
                rebuilt = (bundle, entries, senses, aliases)
            case .refused(let why):
                // Legitimate for the dictionary, and it must still carry an actionable reason.
                #expect(!why.description.isEmpty, "\(bundle.identifier) refused with no reason")
                refusals.append(bundle.identifier)
                continue
            case .upToDate:
                Issue.record("\(bundle.identifier) was up to date in a brand-new store")
            }
            break
        }
        print("IndexRebuilderMeasurementTests: \(refusals.count) refused before one rebuilt "
              + "(\(refusals.joined(separator: ", ")))")
        guard let rebuilt else {
            Issue.record("no installed dictionary could be rebuilt, so none of step 5's checks ran")
            return
        }
        #expect(rebuilt.entries > 0)
        #expect(rebuilt.senses > 0)
        #expect(rebuilt.aliases > 0, "a verified dictionary must yield search keys")
        #expect(try store.senseCount(in: rebuilt.bundle.identifier) == rebuilt.senses)
        #expect(try store.aliasCount(in: rebuilt.bundle.identifier) == rebuilt.aliases)
        // **Progress must actually be reported**, or a long run is indistinguishable from a hang.
        #expect(stages.contains(.finished))
        #expect(stages.contains(.resolving))

        // **A second run with nothing changed writes nothing.** Read from SQLite's own row counter, because
        // a driver that decides "up to date" and rewrites anyway looks exactly like one that skipped.
        let changesBefore = store.totalRowChanges
        let second = rebuilder.rebuild([rebuilt.bundle])
        #expect(second[0].verdict == .upToDate, "the second run did not recognise the index as current")
        #expect(store.totalRowChanges == changesBefore,
                "the second run wrote \(store.totalRowChanges - changesBefore) rows")

        // **A bumped extractor generation rebuilds**, though the dictionary itself has not changed.
        let bumped = IndexRebuilder(store: store,
                                    extractorGeneration: IndexStore.extractorGeneration + 1)
        let third = bumped.rebuild([rebuilt.bundle])
        #expect(third[0].wasRebuilt, "a bumped extractor generation did not force a rebuild")
        #expect(store.totalRowChanges > changesBefore)

        // And the index is usable: a key the dictionary actually carries reaches at least one sense.
        let groups = try KeyIndexReader.groups(in: rebuilt.bundle.url)
        var reached = 0, probed = 0
        for probe in groups.compactMap(\.searchKey).filter({ !$0.isEmpty }).prefix(50) {
            probed += 1
            if !(try store.candidates(for: probe)).isEmpty { reached += 1 }
        }
        print("IndexRebuilder: \(reached) of \(probed) probed keys reached a sense in "
              + rebuilt.bundle.identifier)
        #expect(reached > 0, "not one of the dictionary's own keys reached a sense in the index it built")
    }

    /// **A dictionary whose mapping does not clear the bar is skipped, with a reason.**
    ///
    /// Run over every installed bundle's *report* rather than rebuilding each: the refusal is a decision
    /// about a measurement, and the measurement already exists.
    @Test func anUnverifiedDictionaryIsSkippedWithAReason() throws {
        guard ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] != nil else {
            print("IndexRebuilderMeasurementTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        let all = Self.bundles()
        try #require(!all.isEmpty, "XIAOLAIDICT_BUNDLES is set but no bundle was discovered")
        var refused = 0, accepted = 0
        for bundle in all.prefix(6) {
            guard let groups = try? KeyIndexReader.groups(in: bundle.url), groups.count > 500 else { continue }
            let report = try KeyIndexBuilder.build(bundle: bundle.url, profile: bundle.profile) { _ in }
            let decision = RebuildDecision.decide(needsRebuild: true, report: report)
            switch decision {
            case .refuse(let why):
                refused += 1
                print("IndexRebuilder would refuse \(bundle.identifier): \(why)")
                #expect(!report.isUsable, "\(bundle.identifier): refused while usable")
                #expect(why.description.count > 40, "the reason is too short to act on")
            case .rebuild, .upToDate:
                accepted += 1
                #expect(report.isUsable, "\(bundle.identifier): accepted while not usable")
                #expect(report.displayFormAgreement >= 0.80)
            }
        }
        print("IndexRebuilderMeasurementTests: \(accepted) would be indexed, \(refused) refused")
        #expect(accepted + refused > 0, "no dictionary was assessed, so this measured nothing")
    }
}

/// **A dictionary that cannot be searched is refused, however well it reads.**
///
/// 英譯廣東口語詞典 indexes 2,472 Cantonese colloquialisms and writes 7 search keys. Its key file
/// decompresses completely and the group parser understands almost none of it, so every other check
/// passed — entries, senses, 100% retention, and `verified` at 100% agreement, since agreement is
/// measured over the keys that *were* read. The floor is asserted at the values it was derived from.
@Suite struct SearchabilityFloorTests {
    /// The two the survey puts below the gap, over all 84 assets.
    @Test(arguments: [(7, 2_472, "英譯廣東口語詞典"), (160, 4_086, "漢英對照成語詞典")])
    func aDictionaryNothingReachesIsRefused(aliases: Int, entries: Int, name: String) {
        #expect(!IndexRebuilder.isSearchable(aliases: aliases, entries: entries),
                "\(name) writes \(aliases) keys for \(entries) entries and must be refused")
    }

    /// The lowest passer, and the three this product ships. None may be refused.
    @Test(arguments: [(772, 2_113, "现代汉语同义词典 — the lowest above the gap"),
                      (33_744, 36_866, "牛津粵英雙語詞典"),
                      (250_196, 111_579, "NOAD"),
                      (30_676, 16_007, "Oxford American Writer's Thesaurus"),
                      (311_243, 136_288, "牛津英汉汉英词典")])
    func aSearchableDictionaryIsKept(aliases: Int, entries: Int, name: String) {
        #expect(IndexRebuilder.isSearchable(aliases: aliases, entries: entries),
                "\(name) is searchable at \(aliases)/\(entries) and must not be refused")
    }

    /// The floor sits **inside** the 9.3× gap the survey measured, not on either edge — so neither the
    /// worst passer nor the best failure decides it.
    @Test func theFloorIsInsideTheGapRatherThanOnItsEdge() {
        let worstFailure = 160.0 / 4_086.0      // 0.0392
        let lowestPass = 772.0 / 2_113.0        // 0.3654
        #expect(worstFailure < IndexRebuilder.searchableAliasesPerEntry)
        #expect(IndexRebuilder.searchableAliasesPerEntry < lowestPass)
        #expect(lowestPass / worstFailure > 9, "the gap this rests on is 9.3×; if it narrows, re-derive")
    }

    /// A dictionary with no entries is refused by `noEntries` first, so this must not double-refuse it
    /// with a division that would be zero over zero.
    @Test func anEmptyDictionaryIsNotThisRulesBusiness() {
        #expect(IndexRebuilder.isSearchable(aliases: 0, entries: 0))
    }
}
