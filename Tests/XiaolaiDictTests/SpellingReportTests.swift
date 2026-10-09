import DictionaryModel
import Foundation
import Synchronization
import Testing
import XiaolaiDictBase
import XiaolaiDictCore
@testable import XiaolaiDict

/// **`--spelling-report`: what each term's miss is offered, through the path the card is offered it by** — one JSON
/// line a term, with kinds, the checker's word and two durations, and never a word of dictionary text.
@MainActor
struct SpellingReportTests {
    /// The checker of the experiment's table, in miniature.
    private struct Checker: SpellingSuggesting {
        func suggestion(for term: String, language: String?) async -> String? {
            ["recieve": "receive", "mochii": "mochi"][term]
        }
    }

    /// Dictionaries that have `receive` and `ephemeral`, and could not be asked about `crash`.
    nonisolated private static func lookUp(_ term: String) throws(CancellationError) -> LookupOutcome {
        if term == "crash" { return .notFound(serviceFailure: "the dictionary service crashed") }
        guard ["receive", "ephemeral"].contains(term) else { return .notFound(serviceFailure: nil) }
        let entry = DictionaryEntry(dictionary: DictionaryIdentity(name: "NOAD", identifier: "noad"),
                                    headword: term, lookedUp: term, html: "<p>a definition nobody may print</p>",
                                    document: nil)
        return .entries(NonEmpty([entry])!, unreadable: [])
    }

    private func report(_ terms: [String]) async -> (CommandStatus, [[String: Any]], [String]) {
        let lines = Mutex<[String]>([])
        let status = await SpellingReport.run(
            terms: terms, lookUp: { term throws(CancellationError) in try Self.lookUp(term) }, checker: Checker(),
            language: { "en-GB" }, write: { line in lines.withLock { $0.append(line) }; return true })
        let written = lines.withLock { $0 }
        let objects = written.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        return (status, objects, written)
    }

    /// **One line a term, in order, each saying what the card would be offered** — the offer, the checker's word for an
    /// offer and for one no dictionary has, why a found word was asked nothing — and the two durations.
    @Test func eachTermIsReportedWithWhatItsMissIsOffered() async throws {
        let (status, lines, raw) = await report(["recieve", "mochii", "ambages", "ephemeral"])
        #expect(status == .success)
        #expect(lines.count == 4, "\(raw)")
        #expect(lines.map { $0["term"] as? String } == ["recieve", "mochii", "ambages", "ephemeral"])
        #expect(lines.map { $0["outcome"] as? String } == ["notFound", "notFound", "notFound", "entries"])
        #expect(lines.map { $0["offer"] as? String } == ["offered", "unverified", "noCorrection", "refused"])
        #expect(lines[0]["correction"] as? String == "receive")
        #expect(lines[1]["correction"] as? String == "mochi")
        #expect(lines[2]["correction"] == nil)
        #expect(lines[3]["refusal"] as? String == "notAMiss")
        #expect(lines.allSatisfy { $0["readersEnglish"] as? String == "en-GB" })
        for line in lines {
            #expect((line["lookupMilliseconds"] as? Double).map { $0 >= 0 } == true)
            #expect((line["suggestionMilliseconds"] as? Double).map { $0 >= 0 } == true)
        }
    }

    /// **No dictionary text, ever** — the keys are exactly these, whatever the outcome: a definition, a headword or a
    /// dictionary's name would be licensed content printed from a shell.
    @Test func noLineCarriesDictionaryText() async {
        let (_, lines, raw) = await report(["recieve", "ephemeral", "crash"])
        let allowed: Set<String> = ["term", "outcome", "offer", "refusal", "correction", "readersEnglish",
                                    "lookupMilliseconds", "suggestionMilliseconds"]
        for line in lines { #expect(Set(line.keys).isSubset(of: allowed), "\(line.keys.sorted())") }
        #expect(!raw.joined().contains("definition nobody may print"))
        #expect(!raw.joined().contains("NOAD"))
    }

    /// **A term the service could not be asked about fails the run**: the miss was not the dictionaries' answer, so
    /// what it was offered says nothing about them — reported, and the exit says so.
    @Test func aTermTheServiceCouldNotAnswerFailsTheRun() async {
        let (status, lines, _) = await report(["recieve", "crash"])
        #expect(status == .failure)
        #expect(lines.count == 2, "a failed term stopped the report")
        #expect(lines.last?["offer"] as? String == "refused")
        #expect(lines.last?["refusal"] as? String == "serviceUnanswered")
    }

    /// **A line that could not be written is not a report**, and the run says so rather than succeeding.
    @Test func aLineThatCouldNotBeWrittenFailsTheRun() async {
        let status = await SpellingReport.run(
            terms: ["recieve"], lookUp: { term throws(CancellationError) in try Self.lookUp(term) }, checker: Checker(),
            language: { nil }, write: { _ in false })
        #expect(status == .internalError)
    }

    /// **A test build is not a development bundle**: without the define the instrument refuses, as a release does.
    @Test func withoutTheDefineTheInstrumentRefuses() async {
        #expect(await SpellingReport.run(terms: ["recieve"]) == .usage)
    }
}
