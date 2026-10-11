import DictionaryModel
import Foundation
import Synchronization
import Testing
import XiaolaiDictBase
import XiaolaiDictCore
@testable import XiaolaiDict
import XiaolaiDictTestSupport

/// **`--spelling-report`: what each term's miss is offered, through the path the card is offered it by** — one JSON
/// line a term, with both candidates, the rule that decided and two durations, and never a word of dictionary text.
@MainActor
struct SpellingReportTests {
    /// The checker of the experiment's table, in miniature.
    private struct Checker: SpellingSuggesting {
        func suggestion(for term: String, language: String?) async -> String? {
            ["recieve": "receive", "mochii": "mochi", "receives": "receiver"][term]
        }
    }

    /// Dictionaries that have `receive`, `ephemeral` and `dalesman`, and could not be asked about `crash` — nor about `fallback`, whose
    /// public fallback answered in prose. **Each entry with its part of speech**, which licenses a regular dictionary form
    /// (D1, 2026-10-10): `receives` is offered `receive` because *receive* is a verb.
    nonisolated private static func lookUp(_ term: String) throws(CancellationError) -> LookupOutcome {
        if term == "crash" { return .notFound(serviceFailure: "the dictionary service crashed") }
        if term == "fallback" { return .plainText("an answer in prose", serviceFailure: "the dictionary service crashed") }
        let partsOfSpeech = ["receive": "verb", "ephemeral": "adjective", "dalesman": "noun", "receiver": "noun"]
        guard let partOfSpeech = partsOfSpeech[term] else {
            return .notFound(serviceFailure: nil)
        }
        let document = EntryDocument(isStyled: true, entryID: "e1", homograph: nil,
                                     blocks: [SenseBlock(number: 1, partOfSpeech: partOfSpeech, senses: [])])
        let entry = DictionaryEntry(dictionary: DictionaryIdentity(name: "NOAD", identifier: "noad"),
                                    headword: term, lookedUp: term, html: "<p>a definition nobody may print</p>",
                                    document: document)
        return .entries(NonEmpty([entry])!, unreadable: [])
    }

    private func report(_ terms: [String]) async -> (CommandStatus, [[String: Any]], [String]) {
        let lines = Mutex<[String]>([])
        let status = await SpellingReport.run(
            terms: terms, lookUp: { term throws(CancellationError) in try Self.lookUp(term) }, checker: Checker(),
            language: { "en-GB" }, forms: { nil }, write: { line in lines.withLock { $0.append(line) }; return true })
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
        #expect(lines.map { $0["offer"] as? String } == ["offered", "abstained", "abstained", "refused"])
        #expect(lines.map { $0["rule"] as? String } == ["correction", "unverified", "noCandidate", "refused"])
        #expect(lines[0]["suggestion"] as? String == "receive")
        #expect(lines[0]["correction"] as? String == "receive")
        #expect(lines[0]["correctionEdit"] as? String == "transposition")
        #expect(lines[1]["correction"] as? String == "mochi")
        #expect(lines[1]["correctionVerified"] as? Bool == false)
        #expect(lines[1]["suggestion"] == nil)
        #expect(lines[2]["correction"] == nil)
        #expect(lines[3]["refusal"] as? String == "notAMiss")
        // **A term on the command line was typed**, and says so: the source is recorded, never weighed.
        #expect(lines.allSatisfy { $0["captureSource"] as? String == "typed" })
        #expect(lines.allSatisfy { $0["readersEnglish"] as? String == "en-GB" })
        for line in lines {
            #expect((line["lookupMilliseconds"] as? Double).map { $0 >= 0 } == true)
            #expect((line["suggestionMilliseconds"] as? Double).map { $0 >= 0 } == true)
        }
    }

    /// **The dictionary form too, as the card is offered it** (plan-card-refinements WI-3): a missed inflection whose
    /// lemma the dictionaries have is reported offered, with the form and the rule; a checker's correction says its own.
    @Test func aMissedInflectionIsReportedWithItsDictionaryForm() async {
        let (_, lines, raw) = await report(["receiving", "recieve"])
        #expect(lines.count == 2, "\(raw)")
        #expect(lines.first?["offer"] as? String == "offered")
        #expect(lines.first?["suggestion"] as? String == "receive")
        #expect(lines.first?["rule"] as? String == "regular")
        #expect(lines.first?["dictionaryFormSlot"] as? String == "ing")
        #expect(lines.last?["rule"] as? String == "correction")
    }

    /// **Both candidates, their verification and their distances, and the rule — even where nothing is offered** (the
    /// owner's ruling of 2026-10-11): *receives* is *receive*'s regular third person and the checker's *receiver* is
    /// verified one edit away, so the card is offered nothing, and the line says why.
    @Test func anAbstentionIsReportedWithBothCandidates() async {
        let (_, lines, raw) = await report(["receives"])
        let line = lines.first ?? [:]
        #expect(line["offer"] as? String == "abstained", "\(raw)")
        #expect(line["rule"] as? String == "conflict")
        #expect(line["suggestion"] == nil)
        #expect(line["dictionaryForm"] as? String == "receive")
        #expect(line["dictionaryFormSupported"] as? Bool == true)
        #expect(line["dictionaryFormDistance"] as? Int == 1)
        #expect(line["correction"] as? String == "receiver")
        #expect(line["correctionVerified"] as? Bool == true)
        #expect(line["correctionDistance"] as? Int == 1)
        #expect(line["correctionEdit"] as? String == "substitution")
    }

    /// **Which dictionary form was tried, offered or not** (the owner's order of 2026-10-09): a miss that had none is told
    /// apart from one whose form the dictionaries could not verify — the difference between "this Mac's dictionaries
    /// have no form for it" and "the form lost". Absent where the term has none, and on a found word.
    @Test func eachLineNamesTheDictionaryFormItTried() async {
        let (_, lines, raw) = await report(["receiving", "runs", "recieve", "ephemeral"])
        #expect(lines.count == 4, "\(raw)")
        #expect(lines[0]["dictionaryForm"] as? String == "receive")
        #expect(lines[0]["offer"] as? String == "offered")
        #expect(lines[1]["dictionaryForm"] as? String == "run", "an unverified form was not named: \(raw)")
        #expect(lines[1]["dictionaryFormSupported"] as? Bool == false)
        #expect(lines[1]["offer"] as? String == "abstained")
        #expect(lines[2]["dictionaryForm"] == nil)
        #expect(lines[3]["dictionaryForm"] == nil)
    }

    /// **And what makes the form defensible** (D1, 2026-10-10): `printed` where the reader's dictionaries print the term
    /// as its inflection, `regular` where English spelling makes it one — the provenance of the offer, which the card
    /// does not draw and a measurement needs. Absent where no form was tried.
    @Test func eachLineNamesWhatMakesItsFormDefensible() async {
        let printed = FormTable(sources: [], forms: ["dalesmen": [.init(lemma: "dalesman", partOfSpeech: "noun")]],
                                ownHeadwords: [])
        let lines = Mutex<[String]>([])
        _ = await SpellingReport.run(
            terms: ["receives", "dalesmen", "recieve"], lookUp: { term throws(CancellationError) in try Self.lookUp(term) },
            checker: Checker(), language: { nil }, forms: { printed },
            write: { line in lines.withLock { $0.append(line) }; return true })
        let objects = lines.withLock { $0 }.compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        #expect(objects.count == 3)
        #expect(objects.map { $0["dictionaryFormEvidence"] as? String } == ["regular", "printed", nil])
    }

    /// **No dictionary text, ever** — the keys are exactly these, whatever the outcome: a definition, a headword or a
    /// dictionary's name would be licensed content printed from a shell.
    @Test func noLineCarriesDictionaryText() async {
        let (_, lines, raw) = await report(["recieve", "ephemeral", "crash", "receiving", "receives"])
        let allowed: Set<String> = ["term", "outcome", "captureSource", "offer", "rule", "refusal", "suggestion",
                                    "dictionaryForm", "dictionaryFormEvidence", "dictionaryFormSlot",
                                    "dictionaryFormSupported", "dictionaryFormDistance", "proposedBase", "correction",
                                    "correctionVerified", "correctionDistance", "correctionEdit", "readersEnglish",
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

    /// **Prose from the public fallback is still a service that could not be asked** (audit round 2, 2026-10-09): the
    /// term is not a miss, so it is offered nothing — and the run fails, as it does for a miss the service could not
    /// answer. Judged from the outcome's own service failure, never from the offer.
    @Test func aTermAnsweredOnlyByTheFallbackFailsTheRun() async {
        let (status, lines, _) = await report(["recieve", "fallback"])
        #expect(lines.last?["outcome"] as? String == "plainText")
        #expect(lines.last?["refusal"] as? String == "notAMiss")
        #expect(status == .failure, "a run whose dictionary service failed exited \(status)")
    }

    /// **A line that could not be written is not a report**, and the run says so rather than succeeding — on the error
    /// writer it is given, as `LookupCommand.run` takes one, so the test hears it and the suite's own log does not.
    @Test func aLineThatCouldNotBeWrittenFailsTheRun() async {
        var said: [String] = []
        let status = await SpellingReport.run(
            terms: ["recieve"], lookUp: { term throws(CancellationError) in try Self.lookUp(term) }, checker: Checker(),
            language: { nil }, forms: { nil }, write: { _ in false }, writeError: { said.append($0) })
        #expect(status == .internalError)
        #expect(said == ["could not write the report"], "the failed write said \(said)")
    }

    /// **A test build is not a development bundle**: without the define the instrument refuses, as a release does.
    @Test func withoutTheDefineTheInstrumentRefuses() async {
        #expect(await SpellingReport.run(terms: ["recieve"]) == .usage)
    }
}

/// **The report measures with the form table the reader will have, not the first seconds after an update** (2026-10-10).
/// A new format refuses the stored table, and the dictionary service rebuilds it in the background once a lookup starts it
/// — about 30 s on the Macs measured. The lookup stage asked straight after installing a build that moved the format, so
/// `heavied` and `gazeboes` were reported with no table and read as guards that had lost them. The table is waited for,
/// bounded, and its absence at the deadline is said.
@MainActor
struct SpellingReportFormTableTests {
    private final class Store {
        var reads = 0
        var startedService = 0
        /// The read, counted from one, from which the table is there; nil for never.
        var presentFrom: Int?
        let table = FormTable(sources: ["s"], forms: [:], ownHeadwords: [])
        func read() -> FormTable? {
            reads += 1
            return presentFrom.map { reads >= $0 } == true ? table : nil
        }
    }

    private func await(_ store: Store, within: Duration) async -> FormTable? {
        await SpellingReport.awaitFormTable(read: store.read, startService: { store.startedService += 1 },
                                            within: within, every: .milliseconds(1))
    }

    @Test func aTableAlreadyStoredIsUsedAndNothingIsStarted() async {
        let store = Store()
        store.presentFrom = 1
        #expect(await self.await(store, within: Patience.wait) != nil)
        #expect(store.startedService == 0)
    }

    @Test func aTableTheServiceIsStillBuildingIsWaitedFor() async {
        let store = Store()
        store.presentFrom = 5
        #expect(await self.await(store, within: Patience.wait) != nil, "the rebuild was not waited for")
        #expect(store.startedService == 1, "the service was not started, or started more than once")
    }

    @Test func aTableThatNeverArrivesIsNoneAtTheDeadline() async {
        let store = Store()
        #expect(await self.await(store, within: .milliseconds(50)) == nil)
        #expect(store.startedService == 1)
    }
}
