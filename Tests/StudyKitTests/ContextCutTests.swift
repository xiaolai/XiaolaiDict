import CaptureModel
import DictionaryModel
import Foundation
import Testing
@testable import StudyKit
import XiaolaiDictTestSupport

/// **Which side of a reading's sentence was cut, kept — and "not recorded" kept apart from "neither"** (schema 14).
///
/// A sentence the capture may have cut is shown and used, and the card puts an ellipsis on the side that was cut. The
/// ledger kept only `context_quality = 'mayBeCut'`, so a reading reopened from History lost the side, and every surface
/// that drew one ellipsis drew it at the end. A row written before schema 14 says a cut happened and not where: it stays
/// a possible cut on an unknown side, and is never read as one cut at its end.
struct ContextCutTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func path() -> String { ScratchFile.path("context-cut") }

    private func lookup(_ lemma: String, context: CaptureQuality.Context?, cut: TextSegmenter.Clipping = [])
        -> LookupRecord {
        LookupRecord(
            surface: lemma, lemma: lemma, context: "a sentence holding \(lemma) that ran past", lemmaBasis: .tagger,
            language: "en", lookedUpAt: now, result: .found, answeredBy: .dictionaryService,
            quality: context.flatMap { CaptureQuality(source: .opticalRecognition, confidence: 1, context: $0) },
            contextCut: cut)
    }

    /// The four answers a reading can carry, each read back as itself — through the full record and through the reading
    /// every surface (History, Library, reopening) is built from.
    @Test func eachCutSideIsKeptAndReadBack() throws {
        let ledger = try Ledger(path: ":memory:")
        let cases: [(String, CaptureQuality.Context, TextSegmenter.Clipping)] = [
            ("start", .mayBeCut, [.start]), ("end", .mayBeCut, [.end]), ("both", .mayBeCut, [.start, .end]),
            ("unknown", .mayBeCut, []), ("whole", .complete, []),
        ]
        for (lemma, context, cut) in cases {
            let id = try ledger.record(lookup(lemma, context: context, cut: cut))
            #expect(try ledger.history(of: lemma).first?.contextCut == cut, "\(lemma): the record read back another side")
            let reading = try #require(try ledger.reading(ofLookup: id))
            #expect(reading.sentenceCut == cut, "\(lemma): the reading was given \(reading.sentenceCut)")
            #expect(reading.cutSideUnknown == (lemma == "unknown"), "\(lemma): unknown and known were not told apart")
        }
    }

    /// **A whole sentence has no cut side**, whatever a caller passes: the side is a fact about a possible cut.
    @Test func aWholeSentenceStoresNoSide() throws {
        let ledger = try Ledger(path: ":memory:")
        let id = try ledger.record(lookup("whole", context: .complete, cut: [.end]))
        #expect(try ledger.reading(ofLookup: id)?.sentenceCut == [])
        #expect(try ledger.reading(ofLookup: id)?.cutSideUnknown == false)
    }

    /// The column names its three values and nothing else, so a value this build cannot read is refused at the write.
    @Test func theSchemaRefusesASideItCannotName() throws {
        let ledger = try Ledger(path: ":memory:")
        let id = try ledger.record(lookup("fine", context: .mayBeCut, cut: [.end]))
        #expect(throws: (any Error).self) {
            try ledger.execute("UPDATE lookups SET context_cut = 'sideways' WHERE id = \(id)")
        }
    }

    /// **Every row survives the migration, a legacy possible cut stays unknown in direction, and after reopening the
    /// ledger start, end, both and unknown are four different answers.**
    @Test func aSchema13LedgerKeepsEveryRowAndItsLegacyCutStaysUnknown() throws {
        let path = path()
        defer { ScratchFile.remove(path) }
        do {
            let ledger = try Ledger(path: path)
            for (lemma, context) in [("legacy", CaptureQuality.Context.mayBeCut), ("whole", .complete)] {
                _ = try ledger.record(lookup(lemma, context: context, cut: [.end]))
            }
            _ = try ledger.record(lookup("bare", context: nil))
        }
        // Back to schema 13's shape: no column, so nothing written then could say a side.
        do {
            let ledger = try Ledger(path: path)
            try ledger.execute("""
                PRAGMA foreign_keys = OFF;
                ALTER TABLE lookups DROP COLUMN context_cut;
                PRAGMA user_version = 13;
                """)
        }
        let before = try StudyMigrationTests.rowCounts(at: path)
        do {
            let migrated = try Ledger(path: path)
            let after = try StudyMigrationTests.rowCounts(at: path)
            for (table, count) in before where count > 0 {
                #expect(after[table] == count, "\(table) held \(count) rows and now \(after[table] ?? 0)")
            }
            #expect(FileManager.default.fileExists(atPath: path + ".schema13.backup"), "no copy before the migration")
            let legacy = try #require(try migrated.history(of: "legacy").first)
            #expect(legacy.quality?.context == .mayBeCut, "the possible cut itself was lost")
            #expect(legacy.contextCut == [], "a legacy cut was given a side: \(legacy.contextCut)")
            for (lemma, cut) in [("start", TextSegmenter.Clipping.start), ("end", .end), ("both", [.start, .end])] {
                _ = try migrated.record(lookup(lemma, context: .mayBeCut, cut: cut))
            }
        }
        let reopened = try Ledger(path: path)
        let readings = try reopened.recentLookups(since: .distantPast, limit: 10, studying: Set(ProbeScript.allCases))
        func reading(_ lemma: String) throws -> ReadingEntry { try #require(readings.first { $0.lemma == lemma }) }
        let legacy = try reading("legacy")
        #expect(legacy.cutSideUnknown, "a legacy cut must read as a cut on an unknown side")
        #expect(legacy.sentenceCut == [], "a legacy cut was reinterpreted as \(legacy.sentenceCut)")
        #expect(try reading("start").sentenceCut == [.start])
        #expect(try reading("end").sentenceCut == [.end])
        #expect(try reading("both").sentenceCut == [.start, .end])
        #expect(try ["start", "end", "both", "whole", "bare"].allSatisfy { try !reading($0).cutSideUnknown })
    }
}
