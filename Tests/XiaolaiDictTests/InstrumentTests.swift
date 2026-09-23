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
/// serialiser, so `JSONSerialization` must appear in `Sources/XiaolaiDict` in one file only.
///
/// `LookupCommand` is not an exemption in disguise — it encodes typed `Encodable` reports through
/// `JSONEncoder`, and writes many lines per run rather than one report.
struct InstrumentSerialisationTests {
    private static var app: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/XiaolaiDict")
    }

    @Test func onlyInstrumentSerialisesAReport() throws {
        let root = Self.app
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { throw ScanFailure.unreadable(root.path) }

        var scanned = 0
        var offenders: [String] = []
        for case let file as URL in walk where file.pathExtension == "swift" {
            scanned += 1
            // Thrown rather than defaulted to "": a scanner that silently reads nothing passes
            // forever and guards nothing.
            let text = try String(contentsOf: file, encoding: .utf8)
            // Comment lines are dropped first, so the paragraph above explaining the rule is not
            // itself reported as a breach of it.
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            guard code.contains("JSONSerialization"), file.lastPathComponent != "Instrument.swift"
            else { continue }
            offenders.append(file.lastPathComponent)
        }

        // The positive control. If the walk ever stops finding files this test would pass while
        // reading nothing at all.
        #expect(scanned > 20, "the scan found \(scanned) Swift files, so it is not reading the sources")
        #expect(offenders.isEmpty, "a report is serialised outside Instrument.write: \(offenders)")
    }

    enum ScanFailure: Error {
        case unreadable(String)
    }
}
