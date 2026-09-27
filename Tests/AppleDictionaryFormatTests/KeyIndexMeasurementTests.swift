import Foundation
import Testing
@testable import AppleDictionaryFormat

/// What the key index actually yields, measured against the bundles this machine has.
///
/// Gated on `XIAOLAIDICT_BUNDLES`. **These tests pass while measuring nothing when it is unset** — they
/// say so on the way past, because a green suite is otherwise indistinguishable from a suite that ran.
///
/// **One body pass per dictionary, deliberately.** Decompressing a body is ~230 MB of work and an earlier
/// version of this file did it three times per dictionary, which took the suite past ten minutes. Every
/// question about the derivation is answered from the single report `KeyIndexBuilder` returns.
struct KeyIndexMeasurementTests {
    static func bundles() -> [DictionaryBundle] {
        guard let root = ProcessInfo.processInfo.environment["XIAOLAIDICT_BUNDLES"] else { return [] }
        return DictionaryLocator.installed(in: [URL(fileURLWithPath: root)])
    }

    /// Only the keys, which needs no body pass — so this stays cheap and runs on every machine that has
    /// any dictionary at all.
    @Test func theIndexHoldsPhrasesNoSingleWordLookupWouldFind() throws {
        let all = Self.bundles()
        guard !all.isEmpty else { print("KeyIndexMeasurementTests: XIAOLAIDICT_BUNDLES not set, not measured"); return }
        var measured = 0, anyPhrases = false
        for bundle in all {
            guard let groups = try? KeyIndexReader.groups(in: bundle.url), groups.count > 500 else { continue }
            measured += 1
            let phrases = groups.count(where: { $0.isPhrase })
            let strings = groups.reduce(0) { $0 + $1.keys.count }
            #expect(strings >= groups.count, "\(bundle.identifier): a group must carry at least one key")
            #expect(groups.allSatisfy { !($0.searchKey ?? "").isEmpty }, "\(bundle.identifier): an empty search key")
            if phrases > 0 { anyPhrases = true }
            print("""
                  KeyIndex \(bundle.identifier): \(groups.count) groups, \(strings) key strings, \
                  \(phrases) with a phrase (\(String(format: "%.1f", 100 * Double(phrases) / Double(groups.count)))%)
                  """)
        }
        #expect(measured > 0, "no bundle yielded a key index")
        // The whole reason to read this file: a phrase cannot be found by looking up one word.
        #expect(anyPhrases, "not one dictionary yielded a phrase, so the index adds nothing")
        print("KeyIndexMeasurementTests: \(measured) dictionaries measured")
    }

    /// Resolution end to end, and **the gate that keeps a wrong mapping from being used.**
    ///
    /// `resolved` means the pointer hit a record; it does not mean the record is the right one. For
    /// `zh_TW-en.DrEye` the pointer hits a real record every single time and 96.5% of them are the wrong
    /// record — so the assertion that matters here is not about resolution but about refusal.
    @Test func keysResolveToAnEntryOrTheDictionaryIsRefused() throws {
        let all = Self.bundles()
        guard !all.isEmpty else { print("KeyIndexMeasurementTests: not measured"); return }
        var verdicts: [String: KeyResolutionReport.Confidence] = [:]
        for bundle in all {
            guard (try? KeyIndexReader.groups(in: bundle.url))?.count ?? 0 > 500 else { continue }
            var delivered = 0, variants = 0
            let report = try KeyIndexBuilder.build(bundle: bundle.url, profile: bundle.profile) { key in
                delivered += 1
                #expect(!key.entryID.isEmpty, "\(bundle.identifier): resolved to an entry with no id")
                if let k = key.keys.first, !key.headword.lowercased().contains(k.lowercased()) { variants += 1 }
            }
            verdicts[bundle.identifier] = report.confidence

            #expect(report.resolved == delivered, "\(bundle.identifier): report and callback disagree")
            #expect(report.groups == report.resolved + report.unknownChunkID + report.notARecord
                                     + report.unparsableEntry,
                    "\(bundle.identifier): outcome counts do not add up to the group count")
            // Ambiguity is a residue, not the rule — NOAD leaves 1 id and ko.NewAce 5.
            let seenIDs = report.chunkIDsPinned + report.chunkIDsAmbiguous
            #expect(Double(report.chunkIDsAmbiguous) / Double(max(1, seenIDs)) < 0.05,
                    "\(bundle.identifier): \(report.chunkIDsAmbiguous) of \(seenIDs) ids never narrowed")
            #expect(report.chunkIDsPinned <= report.bodyChunks, "\(bundle.identifier): more ids than chunks")

            // The gate. Never usable without a measurement, never usable while disagreeing with its keys.
            #expect(report.confidence != .unmeasured, "\(bundle.identifier): resolved without any check")
            if report.displayFormAgreement < 0.5 {
                #expect(!report.isUsable, "\(bundle.identifier): agreement \(report.displayFormAgreement) yet usable")
            }
            if report.isUsable {
                #expect(report.displayFormAgreement >= 0.80, "\(bundle.identifier): usable below the threshold")
            }
            print("KeyIndex \(bundle.identifier): \(report.summary)")
            print("""
                  KeyIndex \(bundle.identifier): \(variants) keys are a form the headword does not contain \
                  (\(String(format: "%.1f", 100 * Double(variants) / Double(max(1, delivered))))%)
                  """)
        }
        guard !verdicts.isEmpty else { return }
        print("KeyIndex verdicts: " + verdicts
            .map { "\($0.key.replacingOccurrences(of: "com.apple.dictionary.", with: ""))=\($0.value.rawValue)" }
            .sorted().joined(separator: " "))
        #expect(verdicts.values.contains(.verified), "no dictionary was verified, so nothing can be built")
        // **At least the known-bad one must be refused, or the gate is decoration.** DrEye resolves
        // every pointer and gets 96.5% of them wrong; a gate that passes it would ship that silently.
        if let dreye = verdicts["com.apple.dictionary.zh_TW-en.DrEye"] {
            #expect(dreye == .rejected, "DrEye was \(dreye.rawValue), not rejected")
        }
    }
}
