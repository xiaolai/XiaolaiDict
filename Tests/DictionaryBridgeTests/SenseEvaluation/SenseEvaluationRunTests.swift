import AppleDictionaryFormat
import CaptureModel
import DictionaryModel
import Foundation
import NaturalLanguage
import Testing
@testable import XiaolaiDictCore

/// **The paired evaluation, run against the reader's own NOAD** — only where a case file exists.
///
/// `XIAOLAIDICT_SENSE_EVAL` names a directory outside the repository holding `cases.tsv`. The cases name NOAD sense
/// keys, so they are derived from licensed content and are never committed; a clone without them runs the synthetic
/// tests in `SenseEvaluationTests` and prints here that the measurement did not run. With them, every label is
/// generated from the dictionary on this Mac, the arms are scored, and `report.txt` and `outcomes.tsv` are written
/// beside the cases.
///
/// `XIAOLAIDICT_SENSE_EVAL_DUMP=1` with `surfaces.tsv` (`group \t surface` a line) in the same directory writes
/// `senses.json` instead: every keyable NOAD sense for each surface, which is what an annotator writes cases against.
struct SenseEvaluationRunTests {
    private static var directory: URL? {
        ProcessInfo.processInfo.environment["XIAOLAIDICT_SENSE_EVAL"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The annotation input: what NOAD offers for each surface form, written outside the repository.
    @Test func theSensesAreDumpedForAnnotation() throws {
        guard ProcessInfo.processInfo.environment["XIAOLAIDICT_SENSE_EVAL_DUMP"] == "1", let directory = Self.directory
        else {
            print("SKIPPED theSensesAreDumpedForAnnotation: XIAOLAIDICT_SENSE_EVAL_DUMP is not set")
            return
        }
        let text = try String(contentsOf: directory.appendingPathComponent("surfaces.tsv"), encoding: .utf8)
        var dump: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            try #require(fields.count == 2, "surfaces.tsv: \(line)")
            let candidates = SenseCandidates.considered(try SenseSelectionAccuracyTests.candidates(for: fields[1]))
            dump.append([
                "group": fields[0], "surface": fields[1],
                "senses": candidates.map { ["key": $0.key, "pos": $0.partOfSpeech ?? "", "text": $0.text] },
            ])
        }
        try #require(JSONSerialization.isValidJSONObject(dump))
        let data = try JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("senses.json"))
        print("dumped \(dump.count) surfaces to \(directory.path)/senses.json")
    }

    @Test func theBonusIsMeasuredOnAHeldOutSet() async throws {
        guard let directory = Self.directory,
              let text = try? String(contentsOf: directory.appendingPathComponent("cases.tsv"), encoding: .utf8)
        else {
            print("SKIPPED theBonusIsMeasuredOnAHeldOutSet: no XIAOLAIDICT_SENSE_EVAL/cases.tsv — the measurement did not run")
            // The production weight may only be non-zero where the measurement that justifies it can be repeated.
            return
        }
        let cases = try SenseEvaluation.parse(text)
        try #require(!cases.isEmpty, "cases.tsv holds no cases")

        // Label every case from this Mac's NOAD, and refuse a label that names a sense NOAD does not have.
        var candidatesFor: [String: [SenseCandidate]] = [:]
        var labelled: [SenseEvaluation.Labelled] = []
        let tagger = Lemmatizer.Pass()
        for item in cases {
            let candidates: [SenseCandidate]
            if let known = candidatesFor[item.word] { candidates = known } else {
                candidates = try SenseSelectionAccuracyTests.candidates(for: item.word)
                candidatesFor[item.word] = candidates
            }
            if let correct = item.correct {
                #expect(SenseCandidates.considered(candidates).contains { $0.key == correct },
                        "\(item.id): \(correct) is not a keyable NOAD sense of \(item.word)")
            }
            labelled.append(.init(case: item, candidates: candidates,
                                  tag: tagger.partOfSpeech(of: item.word, in: item.sentence, at: nil)))
        }

        // Rank once per case; every arm decides over the same distances.
        let ranker = EmbeddingSenseSelector(partOfSpeechWeight: 0)
        var ranked: [String: [(candidate: SenseCandidate, distance: Double)]] = [:]
        for item in labelled {
            ranked[item.case.id] = ranker.rank(SenseCandidates.considered(item.candidates), reading: item.case.sentence)
        }
        let arms: [SenseEvaluation.Variant] = [.legacyNarrowing] + SenseEvaluation.weights.map { .bonus($0) }
        var outcomes: [SenseEvaluation.Variant: SenseEvaluation.Outcomes] = [:]
        var chose: [SenseEvaluation.Variant: [String: Bool]] = [:]
        for arm in arms {
            var outcome = SenseEvaluation.Outcomes()
            var picks: [String: Bool] = [:]
            for item in labelled {
                let answer = arm.answer(item, ranked: ranked[item.case.id] ?? [])
                outcome.buckets[item.case.id] = LabelledSenses.bucket(answer, correct: item.case.correct)
                picks[item.case.id] = answer.key != nil && answer.abstention == nil
                if let key = answer.key {
                    #expect(item.candidates.contains { $0.key == key }, "\(arm) answered a sense it was not given")
                }
            }
            outcomes[arm] = outcome
            chose[arm] = picks
        }

        let development = labelled.filter { $0.split == .development }.map(\.case.id)
        let heldOut = labelled.filter { $0.split == .heldOut }.map(\.case.id)
        let weight = SenseEvaluation.chooseWeight(outcomes, over: development)
        var verdict = SenseEvaluation.verdict(for: weight, outcomes, over: heldOut)
        let groups = Set(cases.map(\.group))
        if case .enable = verdict, heldOut.count < 400 || groups.count < 150 {
            verdict = .notShown(["the set is smaller than declared: \(heldOut.count) held out, \(groups.count) headwords"])
        }

        // **The shortcut is the rung.** For the two arms that matter, the whole of `choose` must answer what the
        // per-arm decision answered, case by case — or the evaluation measured something that does not ship.
        for checked in Set([0, weight]) {
            let rung = EmbeddingSenseSelector(partOfSpeechWeight: checked)
            for item in labelled {
                let whole = await rung.choose(from: item.candidates, reading: item.case.sentence, context: .complete,
                                              partOfSpeech: item.tag)
                #expect(whole == SenseEvaluation.Variant.bonus(checked).answer(item, ranked: ranked[item.case.id] ?? []),
                        "\(item.case.id): choose and decide disagree at w = \(checked)")
            }
        }

        let report = SenseEvaluationReport.render(
            labelled: labelled, outcomes: outcomes, chose: chose, development: development, heldOut: heldOut,
            weight: weight, verdict: verdict, versions: Self.versions(candidatesFor))
        print(report)
        try report.write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        try SenseEvaluationReport.outcomes(labelled: labelled, outcomes: outcomes, arms: arms)
            .write(to: directory.appendingPathComponent("outcomes.tsv"), atomically: true, encoding: .utf8)

        // **What ships is what was shown.** The production weight is zero, or the weight this run enabled.
        let shipped = EmbeddingSenseSelector.partOfSpeechWeight
        #expect(shipped == 0 || verdict == .enable(shipped),
                "the shipped weight \(shipped) is not the one the held-out set enabled: \(verdict)")
    }

    /// The dictionary and the embedding the numbers were read from, frozen into the report.
    private static func versions(_ candidates: [String: [SenseCandidate]]) -> [String] {
        let noad = DictionaryLocator.installed().first { $0.identifier == DictionaryIdentity.noad }
        // FNV-1a over every candidate the run read, in a fixed order: the same number means the same text was scored.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for word in candidates.keys.sorted() {
            for candidate in candidates[word] ?? [] {
                for byte in "\(word)\t\(candidate.key)\t\(candidate.partOfSpeech ?? "")\t\(candidate.text)\n".utf8 {
                    hash ^= UInt64(byte)
                    hash = hash &* 0x0000_0100_0000_01b3
                }
            }
        }
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        return [
            "dictionary       NOAD \(noad?.declaredVersion ?? "?") at \(noad?.url.path ?? "?")",
            "candidate text   FNV-1a \(String(hash, radix: 16)) over \(candidates.count) surfaces",
            "embedding        NLEmbedding.sentenceEmbedding(en) revision \(embedding?.revision ?? -1), "
                + "dimension \(embedding?.dimension ?? -1)",
            "system           \(ProcessInfo.processInfo.operatingSystemVersionString)",
        ]
    }
}
