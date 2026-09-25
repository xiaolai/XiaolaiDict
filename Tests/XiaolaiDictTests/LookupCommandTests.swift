import Foundation
@testable import XiaolaiDict
import XiaolaiDictBase
import XiaolaiDictCore
import Synchronization
import Testing

/// `XiaolaiDict --lookup`'s output and exit status, with the XPC client replaced: the real round trip is
/// what the command itself verifies, inside the built bundle.
struct LookupCommandTests {
    private static let entries = NonEmpty([
        DictionaryEntry(dictionary: DictionaryIdentity(name: "Oxford"), headword: "run", lookedUp: "running", html: "<html/>", document: nil),
    ])!

    private final class Output: Sendable {
        private let lines = Mutex<[String]>([])
        func write(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    private func run(
        repeats: Int, outcomes: [LookupOutcome], sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) async -> (CommandStatus, [String]) {
        let output = Output()
        let queue = Mutex(outcomes)
        let status = await LookupCommand.run(
            term: "running", repeats: repeats, interval: .zero,
            lookup: { _ throws(CancellationError) in queue.withLock { $0.removeFirst() } },
            sleep: sleep, write: output.write)
        return (status, output.all)
    }

    /// One object per line — JSON Lines — so a repeat run can be read line by line. Pretty-printed,
    /// each lookup spanned many lines and the whole was neither JSON nor JSON Lines.
    @Test func eachLookupIsOneLineOfJSON() async throws {
        let (_, lines) = await run(repeats: 3, outcomes: Array(repeating: .entries(Self.entries, unreadable: []), count: 3))
        #expect(lines.count == 3)
        for line in lines {
            #expect(!line.contains("\n"))
            let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            #expect(object["outcome"] as? String == "entries")
            #expect(object["matches"] as? [String] == ["dictionaryForm"])
        }
    }

    @Test func everyLookupAnsweredWithEntriesSucceeds() async {
        let (status, _) = await run(repeats: 2, outcomes: Array(repeating: .entries(Self.entries, unreadable: []), count: 2))
        #expect(status == .success)
    }

    /// A fallback in the middle of a run — the service killed between lookups — is what a repeat
    /// run exists to catch. A later success must not hide it.
    @Test func aFailureAnywhereFailsTheRun() async {
        let (status, lines) = await run(repeats: 3, outcomes: [
            .entries(Self.entries, unreadable: []), .plainText("text", serviceFailure: "crashed"),
            .entries(Self.entries, unreadable: []),
        ])
        #expect(status == .failure)
        #expect(lines.count == 3)
    }

    /// The fallback's text is reported whole: cut to a preview, it would still read as the complete
    /// definition.
    @Test func thePlainTextIsReportedWhole() async throws {
        let long = String(repeating: "a definition ", count: 40)
        let (_, lines) = await run(repeats: 1, outcomes: [.plainText(long, serviceFailure: "down")])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(object["text"] as? String == long)
    }

    /// Cancelled while waiting between lookups, the run stops — it does not go on to the next one.
    @Test func cancellationStopsTheRun() async {
        let (status, lines) = await run(repeats: 3, outcomes: Array(repeating: .notFound(serviceFailure: nil), count: 3),
                                        sleep: { _ in throw CancellationError() })
        #expect(status == .interrupted)
        #expect(lines.count == 1)
    }

    /// With the clock injected, the reported timings are exact, not merely present.
    @Test func timingsComeFromTheInjectedClock() async throws {
        let output = Output()
        let base = ContinuousClock.now
        let ticks = Mutex(0)
        // Each reading of the clock is 250 ms after the last.
        let now: @Sendable () -> ContinuousClock.Instant = {
            base.advanced(by: .milliseconds(250 * ticks.withLock { tick in defer { tick += 1 }; return tick }))
        }
        _ = await LookupCommand.run(
            term: "running", repeats: 2, interval: .zero,
            lookup: { _ throws(CancellationError) in .notFound(serviceFailure: nil) }, now: now, sleep: { _ in },
            write: output.write, writeError: { _ in })
        let reports = try output.all.map { try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(reports.map { $0["startedAtSeconds"] as? Double } == [0.3, 0.8])
        #expect(reports.map { $0["tookMilliseconds"] as? Double } == [250, 250])
    }

    @Test func aSelectionReportCarriesItsQuality() throws {
        let selection = Selection(
            text: "saw", sentence: "I saw it yesterday.", rangeInSentence: NSRange(location: 2, length: 3),
            quality: .accessibility(.accessibilityTextMarkers, context: .mayBeCut),
            place: ReadingPlace(
                bundleID: "com.apple.Safari", name: "Safari", document: nil,
                page: "https://example.com/", title: "Example", rawTitle: "Example"))
        let line = try LookupCommand.jsonLine(SelectionReport(selection))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["captureSource"] as? String == "accessibilityTextMarkers")
        #expect(object["context"] as? String == "mayBeCut")
        #expect(object["confidence"] as? Double == 1)
        #expect(object["bundleID"] as? String == "com.apple.Safari")
        #expect(object["lemma"] as? String == "see")
        #expect(object["lemmaBasis"] as? String == "inferred")
    }
}
