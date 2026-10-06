import Foundation
import Testing
@testable import AppleDictionaryFormat

/// **How many of the definitions a dictionary declares actually reach a sense.**
///
/// `d:def` is not how a definition is marked; it is how *some* definitions are marked. Classifying every
/// `class="df"` element in NOAD by ancestry — reproduced independently, and every figure matched:
///
/// | where it sits | count | share |
/// |---|---|---|
/// | carries `d:def` | 142,031 | 71.8% |
/// | under `x_xd*`, no `d:def` | 23,494 | 11.9% |
/// | under `x_xdNsub`, no `d:def` | 19,580 | 9.9% |
/// | under `x_xo*` — a sub-entry | 12,610 | 6.4% |
/// | under neither | 46 | 0.0% |
///
/// So the predicate is `d:def` **or** `class="df"`, inside a main-sense region **or** a sub-entry — which
/// puts 197,715 of 197,761 within reach, and leaves only the 46 that sit inside no region at all.
///
/// Gated on `XIAOLAIDICT_BUNDLES`; prints "not measured" and returns when unset, because a green suite is
/// otherwise indistinguishable from one that measured nothing.
@Suite struct DefinitionReachTests {
    static func bundles() -> [DictionaryBundle] {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else { return [] }
        return DictionaryLocator.installed(in: [URL(fileURLWithPath: root)])
    }

    /// Definitions declared against definitions reached, per dictionary.
    ///
    /// The assertion is a floor rather than the exact figure, because the figure depends on which
    /// dictionaries the Mac has. What cannot drift is that a dictionary declaring definitions in bulk
    /// reaches nearly all of them — reading only `d:def` put NOAD at 74.6% and ODE at 75.5%.
    @Test func nearlyEveryDeclaredDefinitionReachesASense() throws {
        let all = Self.bundles()
        guard !all.isEmpty else {
            print("DefinitionReachTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        struct Row {
            var id = ""
            /// Definition-marked elements in records that became entries.
            var declared = 0
            var captured = 0
            var senses = 0
            var fromSubEntries = 0
            /// **And the ones in records the indexer refused**, which is the denominator this test would
            /// otherwise lose. Counting only accepted entries made NOAD read *exactly* 203,253 of 203,253 —
            /// a clean 100.00% — while 46 definitions sat in 27 records with no headword block and were
            /// unreachable. An aggregate coming out exactly equal is what gave it away.
            var declaredInRejected = 0
            var rejected: [EntryIndexer.Rejection: Int] = [:]
            var records = 0
            var total: Int { declared + declaredInRejected }
            var reached: Double { total > 0 ? Double(captured) / Double(total) : 1 }
        }
        var rows: [Row] = []
        var short: [String] = []
        for bundle in all {
            let indexer = EntryIndexer(bundle: bundle)
            var row = Row(id: bundle.identifier)
            guard (try? ContainerReader.forEachEntry(in: bundle.url) { xhtml in
                row.records += 1
                let outcome = indexer.outcome(for: xhtml)
                guard let entry = outcome.entry else {
                    row.declaredInRejected += outcome.declaredDefinitions
                    if let why = outcome.rejection { row.rejected[why, default: 0] += 1 }
                    return
                }
                row.declared += entry.declaredDefinitions
                row.captured += entry.capturedDefinitions
                row.senses += entry.senses.count
                row.fromSubEntries += entry.senses.count { $0.position.subEntry != nil }
            }) != nil else { continue }
            guard row.total > 0 else { continue }
            rows.append(row)
            // Bulk only: a dictionary declaring a handful can miss one and mean nothing by it.
            if row.total >= 1000, row.reached < 0.95 {
                short.append(String(format: "%@ reaches %.2f%% (%d of %d)", row.id,
                                    row.reached * 100, row.captured, row.total))
            }
        }
        guard !rows.isEmpty else { print("DefinitionReachTests: no dictionary declared a definition"); return }
        print("DefinitionReachTests: \(rows.count) dictionaries")
        for row in rows.sorted(by: { $0.id < $1.id }) {
            let why = row.rejected.sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ",")
            print(String(format: """
                          %-24@ declared %7d  reached %7d  %6.2f%%  senses %7d  sub-entry %6d  \
                         lost to refused records %4d  (%d records; %@)
                         """,
                         row.id.replacingOccurrences(of: "com.apple.dictionary.", with: ""),
                         row.total, row.captured, row.reached * 100, row.senses, row.fromSubEntries,
                         row.declaredInRejected, row.records, why.isEmpty ? "none refused" : why))
        }
        // Captured can never exceed declared — the property the old "split on `; `" count did not have,
        // which is why that one could report 154%.
        #expect(rows.allSatisfy { $0.captured <= $0.total },
                "a dictionary reached more definitions than it declares")
        #expect(short.isEmpty, Comment(rawValue: short.joined(separator: "; ")))
    }

    /// **Sub-entry senses are recovered, and they are the ones a phrase lookup needs.**
    ///
    /// Before this step `give up` and `give in` both resolved to `give`'s entry and none of their own
    /// senses existed — 6.4% of NOAD's definitions, and the only ones that say *which* sense a phrasal
    /// verb has.
    ///
    /// **A sub-entry region does not imply a definition inside it, and assuming otherwise was wrong.** An
    /// earlier version of this test required every dictionary with `x_xo` markup to yield sub-entry senses
    /// and failed on five of the nine here. Measured independently: `OAWT`, `ko-en.NewAce`, `zh_CN-en.OCD`,
    /// `zh_CN.thes` and `zh_TW-en.DrEye` have between 517 and 7,204 `x_xo[1-9]` regions and **zero**
    /// definition-marked elements inside any of them — their sub-entries hold synonyms, phrases and
    /// examples. The three that do yield senses are exactly the three that have definitions there. So what
    /// is asserted is that recovery works where there is something to recover, and that what comes back is
    /// well formed.
    @Test func subEntrySensesAreRecoveredWhereTheMarkupDeclaresThem() throws {
        let all = Self.bundles()
        guard !all.isEmpty else {
            print("DefinitionReachTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        var withSubEntryRegions = 0, yielding = 0
        var unlabelled: [String] = []
        var collisions: [String] = []
        for bundle in all {
            let indexer = EntryIndexer(bundle: bundle)
            let profile = bundle.profile
            var entriesWithRegions = 0, subEntrySenses = 0, labelled = 0
            guard (try? ContainerReader.forEachEntry(in: bundle.url, limit: 4000) { xhtml in
                guard let entry = indexer.outcome(for: xhtml).entry else { return }
                // Asked of the reader's own predicate over the record's class attributes, not of a
                // substring search for "x_xo" — which also matches `x_xo0` and `x_xoLblBlk`, neither of
                // which is a sub-entry.
                if xhtml.range(of: "x_xo") != nil,
                   Self.classAttributes(of: xhtml).contains(where: { profile.marksSubEntry(classAttribute: $0) }) {
                    entriesWithRegions += 1
                }
                let sub = entry.senses.filter { $0.position.subEntry != nil }
                subEntrySenses += sub.count
                labelled += sub.count { !($0.position.subEntry ?? "").isEmpty }
                if let bad = sub.first(where: { ($0.position.subEntry ?? "").isEmpty }),
                   unlabelled.count < 5 {
                    unlabelled.append("\(bundle.identifier)/\(entry.entryID) sub-entry sense "
                                      + "\(bad.contentKey.value) carries no label")
                }
                // A sub-entry sense must not take a main sense's name. The label is what separates them,
                // and this is the check that the label actually reaches the digest.
                let main = Set(entry.senses.filter { $0.position.subEntry == nil }.map(\.contentKey.value))
                if let clash = sub.first(where: { main.contains($0.contentKey.value) }), collisions.count < 5 {
                    collisions.append("\(bundle.identifier)/\(entry.entryID) sub-entry sense collides "
                                      + "with a main sense at \(clash.contentKey.value)")
                }
            }) != nil else { continue }
            guard entriesWithRegions > 20 else { continue }
            withSubEntryRegions += 1
            if subEntrySenses > 0 { yielding += 1 }
            print("""
                  DefinitionReach \(bundle.identifier): \(entriesWithRegions) entries open a sub-entry \
                  region, \(subEntrySenses) sub-entry senses read, \(labelled) of them labelled
                  """)
        }
        print("DefinitionReachTests: \(yielding) of \(withSubEntryRegions) "
              + "sub-entry-declaring dictionaries hold definitions there and yield senses")
        #expect(unlabelled.isEmpty, Comment(rawValue: unlabelled.joined(separator: "; ")))
        #expect(collisions.isEmpty, Comment(rawValue: collisions.joined(separator: "; ")))
        #expect(withSubEntryRegions > 0, "no dictionary opened a sub-entry region, so this measured nothing")
        // The capability must be exercised somewhere, or it is dead code that nothing would notice
        // breaking. It does not name which dictionary: pinning one is the mistake `zh_TW-en.DrEye` taught.
        #expect(yielding > 0, "not one dictionary yielded a sub-entry sense")
    }

    /// Every `class` attribute value in a record. Cheap and exact enough to ask a profile predicate about,
    /// which is the point — the predicate is the thing under test, not a substring.
    static func classAttributes(of xhtml: String) -> [String] {
        var out: [String] = []
        var rest = Substring(xhtml)
        while let open = rest.range(of: "class=\"") {
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "\"") else { break }
            out.append(String(rest[..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return out
    }
}

/// The predicate on invented markup, where the right answer is known by construction rather than read out
/// of a licensed bundle.
@Suite struct DefinitionPredicateTests {
    static let profile = DictionaryProfile(identifier: "test", senseDepth: 1)
    static func index(_ xml: String) -> IndexedEntry? {
        EntryIndexer(dictionary: "test", profile: profile).index(xml)
    }

    /// A definition marked only by `class="df"` is read. 43,074 of NOAD's — 21.8% of all of them — are
    /// ordinary main-sense definitions like this, and the attribute-only predicate reached none.
    @Test func aDefinitionWithNoAttributeIsStillADefinition() {
        let xml = """
            <d:entry id="e1" d:title="wibble"><span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span d:pos="1" class="pos">noun</span>\
            <span id="e1.1" class="x_xd1"><span class="df">a small device</span></span></span>\
            </d:entry>
            """
        #expect(Self.index(xml)?.senses.map(\.definition) == ["a small device"])
    }

    /// Guide punctuation is not a definition. `class="gp tg_df"` holds the colon before an example, and a
    /// substring test for `df` reads it as a definition.
    @Test func guidePunctuationIsNotADefinition() {
        let xml = """
            <d:entry id="e1" d:title="wibble"><span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span id="e1.1" class="x_xd1">\
            <span class="df">a small device</span><span class="gp tg_df">: </span>\
            <span class="eg"><span class="ex">a brass wibble</span></span></span></span>\
            </d:entry>
            """
        #expect(Self.index(xml)?.senses.map(\.definition) == ["a small device"])
    }

    /// A definition outside every sense region is counted as declared and not captured, so the ratio shows
    /// the loss instead of hiding it. NOAD has 46 of these.
    @Test func aDefinitionOutsideEverySenseRegionIsDeclaredButNotReached() {
        let xml = """
            <d:entry id="e1" d:title="wibble"><span class="x_xh0">wibble</span>\
            <span class="df">a definition in no region at all</span>\
            <span class="x_xd0"><span id="e1.1" class="x_xd1">\
            <span class="df">a small device</span></span></span></d:entry>
            """
        let entry = Self.index(xml)
        #expect(entry?.senses.count == 1)
        #expect(entry?.declaredDefinitions == 2)
        #expect(entry?.capturedDefinitions == 1)
        #expect(entry?.definitionsReached == 0.5)
    }

    /// **A sub-entry is a sense region.** `x_xo1` the sub-entry, `x_xo2` a sense inside it, `x_xo2sub` the
    /// subsense holding the definition — and those definitions carry `class="df"` with no `d:def`, which
    /// is why a retention figure counting `d:def=` reported 100% while a quarter of NOAD went unread.
    @Test func subEntrySensesAreRead() {
        let xml = """
            <d:entry id="e3" d:title="wibble"><span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span d:pos="1" class="pos">verb</span>\
            <span id="e3.1" class="x_xd1"><span d:def="1" class="df">to move unsteadily</span></span></span>\
            <span id="e3.9" class="subEntry x_xo1"><span class="l x_xoh">wibble out </span>\
            <span id="e3.10" class="se2 x_xo2 hasSn"><span class="gp sn">1</span>\
            <span id="e3.11" class="msDict x_xo2sub"><span class="df">to withdraw at the last moment</span>\
            </span></span></span></d:entry>
            """
        let senses = Self.index(xml)?.senses ?? []
        #expect(senses.count == 2)
        #expect(senses.last?.definition == "to withdraw at the last moment")
        #expect(senses.last?.position.subEntry == "wibble out")
        #expect(senses.first?.position.subEntry == nil, "the main sense is not in a sub-entry")
        #expect(Self.index(xml)?.definitionsReached == 1.0)
    }

    /// **The sub-entry block is not a sub-entry.** `x_xo0` wraps several `x_xo1` siblings, so opening a
    /// region there would merge `wibble out` and `wibble on` into one sense.
    @Test func eachSubEntryInABlockIsItsOwnSense() {
        let xml = """
            <d:entry id="e4" d:title="wibble"><span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span id="e4.1" class="x_xd1">\
            <span class="df">to move unsteadily</span></span></span>\
            <span class="subEntryBlock x_xo0 t_phrasalVerbs">\
            <span class="gp x_xoLblBlk">PHRASAL VERBS </span>\
            <span id="e4.2" class="subEntry x_xo1"><span class="x_xoh"><span class="l">wibble out </span>\
            <span class="prx"> | ˈwɪbl aʊt | </span></span>\
            <span id="e4.3" class="msDict x_xo2"><span class="df">to withdraw</span></span></span>\
            <span id="e4.4" class="subEntry x_xo1"><span class="x_xoh"><span class="l">wibble on </span></span>\
            <span id="e4.5" class="msDict x_xo2"><span class="df">to continue at length</span></span></span>\
            </span></d:entry>
            """
        let senses = Self.index(xml)?.senses ?? []
        #expect(senses.count == 3, "one main sense and two sub-entries, not one merged block")
        #expect(senses.map(\.position.subEntry) == [nil, "wibble out", "wibble on"])
        // The `l` span wins over the `x_xoh` block, whose text also carries the pronunciation.
        #expect(!(senses[1].position.subEntry ?? "").contains("|"))
    }

    /// Two sub-entries of one entry can word a sense identically; the label is what keeps them apart, so
    /// neither needs the ordinal fallback.
    @Test func twoSubEntriesWordedAlikeGetDistinctKeys() {
        let xml = """
            <d:entry id="e5" d:title="give"><span class="x_xh0">give</span>\
            <span class="x_xd0"><span id="e5.1" class="x_xd1"><span class="df">to hand over</span></span></span>\
            <span class="subEntryBlock x_xo0">\
            <span id="e5.2" class="subEntry x_xo1"><span class="l">give up </span>\
            <span class="msDict x_xo2"><span class="df">to stop trying</span></span></span>\
            <span id="e5.3" class="subEntry x_xo1"><span class="l">give in </span>\
            <span class="msDict x_xo2"><span class="df">to stop trying</span></span></span>\
            </span></d:entry>
            """
        let entry = Self.index(xml)
        let senses = entry?.senses ?? []
        #expect(senses.count == 3)
        #expect(Set(senses.map(\.contentKey.value)).count == 3, "the labels must separate them")
        #expect(entry?.sensesNeedingOrdinals.isEmpty == true, "no ordinal was needed")
    }

    /// **A record that is not an entry still says what it declared.**
    ///
    /// Found the hard way: counting definitions only from accepted entries made NOAD report *exactly*
    /// 203,253 of 203,253 — a clean 100.00% — while 46 definition-marked elements sat in 27 records with no
    /// headword block. The aggregate coming out exactly equal is what gave it away; a figure merely close
    /// to 100% would have been believed.
    @Test func aRefusedRecordStillReportsWhatItDeclared() {
        // No headword block, so not an entry — but it declares a definition all the same.
        let noHeadword = """
            <d:entry id="e1" d:title="wibble">\
            <span class="x_xd0"><span id="e1.1" class="x_xd1">\
            <span class="df">a small device</span></span></span></d:entry>
            """
        let indexer = EntryIndexer(dictionary: "test", profile: Self.profile)
        let refused = indexer.outcome(for: noHeadword)
        #expect(refused.entry == nil)
        #expect(refused.rejection == .noHeadword)
        #expect(refused.declaredDefinitions == 1, "the definition must stay in the denominator")

        // No `d:entry` id at all.
        let noID = """
            <d:entry d:title="wibble"><span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">a small device</span></span></span>\
            </d:entry>
            """
        #expect(indexer.outcome(for: noID).rejection == .noEntryID)
        #expect(indexer.outcome(for: noID).declaredDefinitions == 1)

        // Not XML at all.
        let broken = "<d:entry id=\"e1\"><span class=\"x_xh0\">wibble</span>"
        #expect(indexer.outcome(for: broken).rejection == .notWellFormed)

        // And an accepted record reports no rejection.
        let good = """
            <d:entry id="e2" d:title="wibble"><span class="x_xh0">wibble</span>\
            <span class="x_xd0"><span class="x_xd1"><span class="df">a small device</span></span></span>\
            </d:entry>
            """
        let accepted = indexer.outcome(for: good)
        #expect(accepted.rejection == nil)
        #expect(accepted.entry?.capturedDefinitions == 1)
        #expect(accepted.declaredDefinitions == 1)
    }

    /// The etymology block also uses `x_xo0`/`x_xo1` in NOAD and is not a sub-entry. It carries no
    /// definition-marked element, so the predicate keeps its prose out — no special case needed.
    @Test func anEtymologyBlockYieldsNoSense() {
        let xml = """
            <d:entry id="e6" d:title="abject"><span class="x_xh0">abject</span>\
            <span class="x_xd0"><span id="e6.1" class="x_xd1"><span class="df">utterly hopeless</span></span></span>\
            <span class="etym x_xo0"><span class="gp x_xoLblBlk">ORIGIN </span>\
            <span class="x_xo1">late Middle English: from Latin <span class="ff">abjectus</span>.</span>\
            </span></d:entry>
            """
        let senses = Self.index(xml)?.senses ?? []
        #expect(senses.count == 1, "the etymology is not a sense")
        #expect(senses.first?.definition == "utterly hopeless")
    }
}

/// `DictionarySurvey`, which is where the corrected retention metric is read from when `DICTIONARIES.md` is
/// regenerated. Gated on `XIAOLAIDICT_BUNDLES`.
///
/// **It had no test at all, and step 2 changed its arithmetic.** The survey is the only caller that has to
/// add what a *refused* record declared to the denominator; getting that wrong is precisely how a retention
/// figure reads 100% while definitions are unreachable, and nothing would have caught it.
@Suite struct DictionarySurveyTests {
    /// Surveyed without keys: key resolution is three body passes and is measured by
    /// `KeyIndexMeasurementTests` already.
    @Test func theSurveyReportsABoundedRetentionOverACompleteDenominator() throws {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else {
            print("DictionarySurveyTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        let bundles = DictionaryLocator.installed(in: [URL(fileURLWithPath: root)])
        // **The smallest body that is a dictionary**, so this is seconds rather than minutes. Readable is not enough:
        // `com.apple.accessibility.dictionary.TTY` reads fine and holds 72 records that all lack a headword, so it
        // survives a "readable" test, measures 0 entries and makes every assertion below about nothing. A candidate
        // has to yield an entry when surveyed, and smaller ones are tried first.
        let bySize = bundles.compactMap { bundle -> (DictionaryBundle, Int)? in
            guard let body = try? ContainerReader.bodyURL(of: bundle.url),
                  let size = (try? FileManager.default.attributesOfItem(atPath: body.path))?[.size] as? Int,
                  (try? ContainerReader.forEachEntry(in: bundle.url, limit: 1) { _ in }) != nil
            else { return nil }
            return (bundle, size)
        }.sorted { $0.1 < $1.1 }.map(\.0)
        let smallest = bySize.first { DictionarySurvey.measure($0, includingKeys: false).entries > 0 }
        guard let smallest else {
            print("DictionarySurveyTests: no readable bundle yields an entry, not measured"); return
        }
        let facts = DictionarySurvey.measure(smallest, includingKeys: false)
        print("""
              DictionarySurveyTests: \(facts.identifier) — \(facts.entries) entries, \(facts.senses) senses, \
              declared \(facts.declaredDefinitions), captured \(facts.capturedDefinitions), \
              retention \(String(format: "%.4f", facts.definitionRetention)), \
              ordinals \(facts.sensesNeedingOrdinals), refused \(facts.refusedRecords)
              """)
        #expect(facts.entries > 0)
        #expect(facts.declaredDefinitions > 0, "nothing was declared, so retention measures nothing")
        // Bounded by construction — the old metric could exceed 1 and reported 154% for one dictionary.
        #expect(facts.capturedDefinitions <= facts.declaredDefinitions)
        #expect(facts.definitionRetention <= 1.0)
        #expect(facts.definitionRetention
                == Double(facts.capturedDefinitions) / Double(facts.declaredDefinitions),
                "the reported share is not the ratio of the counts beside it")
        // The denominator must include what a refused record declared, which is the whole point.
        let refusedRecords = facts.refusedRecords.values.reduce(0, +)
        #expect(refusedRecords >= 0)
        if refusedRecords > 0 {
            #expect(facts.capturedDefinitions < facts.declaredDefinitions,
                    "records were refused yet every declared definition was reached")
        }
        #expect(facts.usability != .unreadable)
    }
}
