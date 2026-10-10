import Foundation
import StudyModels
import Testing
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **An instrument that looks a word up records into a ledger of its own, never the reader's** (audit of 2026-10-10).
///
/// `--panel-report` and `--placement-report` look a word up through the reader's own door, deliberately — the card they
/// measure is the card the product draws — and that door records. They used to record into the reader's ledger and then
/// delete every lookup above the id they had started from: which deletes a reading the reader's own app recorded in the
/// meantime, and leaves whatever study state the recording made, since a study note outlives its lookup. A ledger of the
/// instrument's own, in a scratch directory, leaves the reader's untouched by construction and has nothing to put back.
///
/// **Serialized**: what a run made is the process's (`Instruments` is one per process), so one test's `finish` takes away
/// another's directories if the two run at once.
@Suite(.serialized)
struct InstrumentLedgerTests {
    @Test func anInstrumentThatLooksAWordUpKeepsItsLedgerInAScratchDirectoryOfItsOwn() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-instrument-ledger")
        defer { Instruments.finish() }
        for instrument in [Instruments.Windowed.panel, .note, .placement] {
            let root = try #require(try Instruments.ledgerSupport(for: instrument, scratchIn: scratch.url),
                                    "\(instrument) records into the reader's own ledger")
            #expect(root.deletingLastPathComponent().standardizedFileURL == scratch.url.standardizedFileURL)
            // It opens there, as the app opens it: a ledger the reader has never had.
            _ = try await LedgerStore.openDefault(applicationSupport: root)
            #expect(FileManager.default.fileExists(atPath: root.appending(path: "XiaolaiDict/ledger.sqlite").path))
        }
        // Two runs, two directories: nothing one run recorded is another's.
        let first = try Instruments.ledgerSupport(for: .panel, scratchIn: scratch.url)
        let second = try Instruments.ledgerSupport(for: .panel, scratchIn: scratch.url)
        #expect(first != second)
    }

    /// The reader's app, and the instruments that only read — the drawer, Settings — open the reader's own.
    @Test func everythingElseOpensTheReadersLedger() throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-instrument-ledger-readers")
        for instrument in [nil, Instruments.Windowed.history, .settings] {
            #expect(try Instruments.ledgerSupport(for: instrument, scratchIn: scratch.url) == nil, "\(String(describing: instrument))")
        }
    }

    /// **Taken away when the run ends**, every directory it made: a scratch ledger left behind is a reading left on the
    /// Mac, if not in the reader's ledger.
    @Test func theScratchLedgersAreRemovedWhenTheRunEnds() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-instrument-ledger-finish")
        let roots = try [Instruments.Windowed.panel, .placement].map {
            try #require(try Instruments.ledgerSupport(for: $0, scratchIn: scratch.url))
        }
        for root in roots { _ = try await LedgerStore.openDefault(applicationSupport: root) }
        Instruments.finish()
        for root in roots { #expect(!FileManager.default.fileExists(atPath: root.path), "\(root.lastPathComponent) was left") }
    }
}
