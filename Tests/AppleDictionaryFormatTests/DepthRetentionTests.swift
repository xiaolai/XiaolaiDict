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
/// So the question here is retention: for each candidate depth, what share of the `d:def` elements the
/// markup declares survive into a sense? Printed as a table, and asserted only where a profile's declared
/// depth is clearly not the best one.
///
/// The ratio is a **relative signal, not an exact count** — it can exceed 100%, because the joined
/// definition is split on "; " to count its parts and a definition may contain that sequence itself. What
/// matters is the gap between depths, which is large wherever it is real.
@Suite struct DepthRetentionTests {
    @Test func theDeclaredDepthIsTheOneThatKeepsTheDefinitions() throws {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else {
            print("DepthRetentionTests: XIAOLAIDICT_BUNDLES not set, not measured"); return
        }
        var wrong: [(String, Int, Double, Int, Double)] = []
        var rows = 0
        for bundle in DictionaryLocator.installed(in: [URL(fileURLWithPath: root)]) {
            guard let entries = try? ContainerReader.entries(in: bundle.url) else { continue }
            let sample = Array(entries.prefix(300))
            let declared = sample.reduce(0) { $0 + $1.components(separatedBy: "d:def=").count - 1 }
            guard declared > 30 else { continue }
            rows += 1
            var best = (depth: 1, kept: 0.0)
            var atDeclared = 0.0
            let declaredDepth = bundle.profile.senseDepth
            for depth in 1...4 {
                let profile = DictionaryProfile(identifier: bundle.identifier, senseDepth: depth,
                                                senseIDAttributes: bundle.profile.senseIDAttributes)
                let indexer = EntryIndexer(dictionary: bundle.identifier, profile: profile)
                let kept = sample.compactMap(indexer.index).flatMap(\.senses)
                    .reduce(0) { $0 + $1.definition.components(separatedBy: "; ").count }
                let share = Double(kept) / Double(declared)
                if depth == declaredDepth { atDeclared = share }
                if share > best.kept { best = (depth, share) }
            }
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
