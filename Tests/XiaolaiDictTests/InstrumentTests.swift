import Foundation
import Testing
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **An instrument's report is only measured if it arrived.** `Instrument.write` exists so every
/// in-bundle report answers that question the same way, and so a line handed to a closed pipe ends
/// the run rather than being counted as one that printed.
///
/// Two instruments were outside it. `--speech-report` and `--translation-report` each serialised
/// their own JSON and pushed it into a `(String) -> Void` sink, which threw away the `Bool`
/// `LookupCommand.writeLine` returns — so a run that measured everything and printed nothing
/// exited `.success`, and to the harness that reads the exit status it was indistinguishable from
/// a run that worked.
struct InstrumentWriteTests {
    /// The report reaches the sink as one line of JSON, and the sink's answer is the one given
    /// back — which is the whole reason the sink returns anything.
    @Test func aReportThatLandedIsReportedAsWritten() {
        let written = Recorder<[String]>([])
        #expect(Instrument.write(["b": 2, "a": 1], to: { line in written.withLock { $0.append(line) }; return true }))
        #expect(written.withLock { $0 } == ["{\"a\":1,\"b\":2}"])
    }

    /// **A sink that refused is a report nobody received.** The caller must be told, or it goes on
    /// to exit with the status its measurement earned rather than the one its output did.
    @Test func aSinkThatRefusedIsReportedAsNotWritten() {
        let written = Recorder<[String]>([])
        #expect(!Instrument.write(["a": 1], to: { line in written.withLock { $0.append(line) }; return false }))
        #expect(written.withLock { $0 }.count == 1, "the line was never offered to the sink")
    }

    /// A report that could not be built has no report to send: the sink is not called at all, the
    /// diagnostic goes to standard error instead, and the caller is told.
    ///
    /// **That this test can run at all is the point of it.** `JSONSerialization` raises an
    /// Objective-C exception for a value it cannot write rather than throwing a Swift error, so
    /// before the validity check went in front of it this line killed the test process instead of
    /// failing an expectation — which is what the guard behind it had always looked like it
    /// prevented.
    @Test func aReportThatCouldNotBeSerialisedIsNeverSentToTheSink() {
        let written = Recorder<[String]>([])
        #expect(!Instrument.write(["nan": Double.nan], to: { line in written.withLock { $0.append(line) }; return true }))
        #expect(written.withLock { $0 }.isEmpty, "a report that could not be serialised was written anyway")
    }
}

/// **The rule, mechanically.** The two instruments that bypassed `Instrument.write` did it by
/// serialising for themselves, and their tests could not see it: what they built was correct JSON
/// and what it was handed to never answered. What can fail is the presence of the second
/// serialiser, so `JSONSerialization` must appear in one file only of every module the app links.
///
/// `LookupCommand` is not an exemption in disguise — it encodes typed `Encodable` reports through
/// `JSONEncoder`, and writes many lines per run rather than one report.
///
/// **Every module the app links, not `Sources/XiaolaiDict`** (2026-10-08): code an instrument reaches left that
/// directory with the split — the developer pane's ledger counts for `StudyModels`, the readers `--read-point` and
/// `--read-selection` drive for `MacCapture` — and a second serialiser there was outside the walk (`AppModules`).
struct InstrumentSerialisationTests {
    @Test func onlyInstrumentSerialisesAReport() throws {
        let scan = try AppModules.scan()
        #expect(scan.problems.isEmpty, "\(scan.problems)")
        // `Instrument.swift` is the one place allowed to serialise, which is the rule this asserts. `SourceScan`
        // throws rather than skipping a directory it cannot read — this used to walk with no error handler, so an
        // unreadable subtree passed in silence while a count floor still held on whatever remained.
        let offenders = scan.files.filter { $0.code.contains("JSONSerialization") }
            .map { "\($0.module)/\($0.file.lastPathComponent)" }
            .filter { $0 != "XiaolaiDict/Instrument.swift" }
        // Named, not counted: the one serialiser allowed, and the instrument that encodes instead.
        let unread = SourceScan.unread(["Instrument.swift", "LookupCommand.swift"], in: scan.read)
        #expect(unread.isEmpty, "the scan no longer reads \(unread)")
        #expect(offenders.isEmpty, "a report is serialised outside Instrument.write: \(offenders)")
    }


}
