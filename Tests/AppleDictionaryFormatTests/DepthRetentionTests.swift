import Foundation
import Testing
@testable import AppleDictionaryFormat

/// Which `x_xdN` depth actually keeps a dictionary's definitions.
///
/// The strict depth measurement asked "is there a block at depth N holding a definition?" and answered
/// yes at depth 1 for all 84. That is the wrong question: a dictionary can have *a* depth-1 block with a
/// definition while most of its definitions sit deeper, and indexing at depth 1 then silently drops them.
/// Vietnamese retained 21.9% of its declared definitions under that reading.
///
/// So the question here is retention: for each candidate depth, what share of the definitions the markup
/// declares reach a sense? Printed as a table, and asserted only where a profile's declared depth is
/// clearly not the best one.
///
/// **The ratio is now exact and bounded in [0, 1], and was neither before.** It counted only `d:def=`,
/// so a definition marked by `class="df"` alone was in neither numerator nor denominator — a quarter of
/// NOAD. And it counted the numerator by splitting the joined definition on `"; "`, which a definition may
/// contain itself, so the figure could exceed 100% and did: 154% for `as-en.oup`. Both sides now come from
/// `IndexedEntry`, counted by the parser over the union of `d:def` and `class="df"`.
@Suite struct DepthRetentionTests {
    @Test func theDeclaredDepthIsTheOneThatKeepsTheDefinitions() throws {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else {
            print("DepthRetentionTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        var wrong: [(String, Int, Double, Int, Double)] = []
        var rows = 0
        for bundle in DictionaryLocator.installed(in: [URL(fileURLWithPath: root)]) {
            // Streamed with a limit rather than materialised: the sample is 300 entries and an
            // `entries(in:)` call paid for all 111,606 of NOAD's to get them.
            var sample: [String] = []
            guard (try? ContainerReader.forEachEntry(in: bundle.url, limit: 300) { sample.append($0) })
                    != nil else { continue }
            var best = (depth: 1, kept: 0.0)
            var atDeclared = 0.0
            var declared = 0
            let declaredDepth = bundle.profile.senseDepth
            var shares: [Int: Double] = [:]
            for depth in 1...4 {
                let profile = DictionaryProfile(identifier: bundle.identifier, senseDepth: depth,
                                                senseIDAttributes: bundle.profile.senseIDAttributes)
                let indexer = EntryIndexer(dictionary: bundle.identifier, profile: profile)
                let indexed = sample.compactMap(indexer.index)
                // The denominator does not depend on depth — it is what the markup declares — but it is
                // read from the same pass so the two sides can never come from different samples.
                let here = indexed.reduce(0) { $0 + $1.declaredDefinitions }
                let kept = indexed.reduce(0) { $0 + $1.capturedDefinitions }
                declared = max(declared, here)
                guard here > 0 else { continue }
                let share = Double(kept) / Double(here)
                shares[depth] = share
                if depth == declaredDepth { atDeclared = share }
                if share > best.kept { best = (depth, share) }
            }
            guard declared > 30, !shares.isEmpty else { continue }
            rows += 1
            // Bounded by construction now, so a figure above 1 is a defect rather than an artefact.
            #expect(shares.values.allSatisfy { $0 <= 1.0 },
                    "\(bundle.identifier): retention above 100%, so the metric is counting wrongly")
            // Printed per dictionary, not only when it fails: the plan's step 2 re-measures retention on
            // the corrected metric, and a dictionary that was ranked lossy under the old count has to be
            // visible as re-ranked rather than silently dropping off the failure list.
            print(String(format: "  %-46@ declared %2d  %@",
                         bundle.identifier.replacingOccurrences(of: "com.apple.dictionary.", with: ""),
                         declaredDepth,
                         shares.sorted { $0.key < $1.key }
                            .map { String(format: "d%d %5.1f%%", $0.key, $0.value * 100) }
                            .joined(separator: "  ")))
            // A depth is "clearly better" only by a wide margin — noise must not churn the table.
            if best.depth != declaredDepth, best.kept > atDeclared + 0.25 {
                wrong.append((bundle.identifier, declaredDepth, atDeclared, best.depth, best.kept))
            }
        }
        print("DepthRetentionTests: \(rows) dictionaries measured; \(wrong.count) declare a depth that loses definitions")
        for (id, dd, da, bd, bk) in wrong.sorted(by: { $0.2 < $1.2 }) {
            let left = id.padding(toLength: max(44, id.count), withPad: " ", startingAt: 0)
            print(String(format: "  %@ declared %d keeps %.0f%%  ->  depth %d keeps %.0f%%",
                         left, dd, da * 100, bd, bk * 100))
        }
        #expect(wrong.isEmpty, Comment(rawValue:
            "\(wrong.count) dictionaries lose definitions at their declared depth: "
            + wrong.map(\.0).prefix(6).joined(separator: ", ")))
    }
}
