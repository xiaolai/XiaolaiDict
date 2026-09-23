import Foundation
import XiaolaiDictCore

/// `--sense-report`: **the ladder's order, decided on the labelled set** — every rung scored on the
/// same six NOAD cases, inside the signed bundle, through the real paths: entries from the
/// dictionary service, the local model through its service, Apple's model where it runs.
///
/// Here rather than in the test suite because it is the only place all three rungs exist at once:
/// the suite cannot link MLX's service, and the E2E Mac — where Apple Intelligence runs — has the
/// bundle and not the sources. Nine hand-written cases favoured Qwen; this is what decides.
///
/// Scored in the suite's four buckets, and the number that decides honesty is `wrong` — a sense
/// marked with confidence and mistaken.
@MainActor
enum SenseReport {
    static func run(write: (String) -> Bool = LookupCommand.writeLine) async -> CommandStatus {
        let models = LocalModelAccess(client: ModelClient(), store: .standard())
        // **The shipped ladder and its own rungs** — one set of selectors, so the measurement cannot
        // be of a different composition from the one readers get.
        let ladder = models.senseLadder
        let rungs = ladder.rungs + [("ladder", ladder.ladder)]
        // Every bucket present in every rung's score, so a report never leaves a reader guessing
        // whether a missing key means zero or a bucket that was not counted.
        var scores = Dictionary(uniqueKeysWithValues: rungs.map { rung in
            (rung.name, Dictionary(uniqueKeysWithValues: LabelledSenses.Bucket.allCases.map { ($0.rawValue, 0) }))
        })
        var answers: [[String: Any]] = []
        var milliseconds: [String: [Int]] = [:]
        let dictionaries = DictionaryClient()
        var warmed = false
        for labelled in LabelledSenses.hardCases {
            let candidates: [SenseCandidate]
            do {
                candidates = try await Self.candidates(for: labelled.word, from: dictionaries)
            } catch is CancellationError {
                return .interrupted
            } catch {
                // Through the serialiser, never built by hand: an error's description carries
                // quotes, backslashes and newlines, and a hand-built line would be invalid JSON —
                // which the harness reads as the instrument crashing rather than as this failure.
                _ = Instrument.write(["error": String(describing: error)], to: write)
                return .failure
            }
            // **The labelled answer has to be among the candidates.** A dictionary asset updated
            // under us, or a parser change that drops a sense, would otherwise be scored as every
            // rung getting the word wrong — the instrument reporting a model defect for a fixture
            // one. Checked against the set as it is today, before anything is asked of a model.
            if let correct = labelled.correct, !candidates.contains(where: { $0.key == correct }) {
                _ = Instrument.write(
                    ["error": "\(labelled.word): the labelled sense \(correct) is not among NOAD's candidates today, so this set cannot score it"],
                    to: write)
                return .failure
            }
            let partOfSpeech = Lemmatizer.partOfSpeech(of: labelled.word, in: labelled.sentence, at: nil)
            // **Warmed before anything is timed.** Otherwise the first rung measured pays the cold
            // load and grammar compile that every rung after it is spared, and the numbers say more
            // about the order they were run in than about the rungs.
            if !warmed {
                for rung in rungs {
                    // **A warm-up that timed out stops the run.** `withDeadline` gives up on work
                    // it cannot cancel, so a generation that overran would go on running beside
                    // every timing below — and the numbers would be of two answers at once.
                    do {
                        _ = try await withDeadline(Self.rungLimit) {
                            await rung.selector.choose(
                                from: candidates, reading: labelled.sentence, context: .complete,
                                partOfSpeech: partOfSpeech)
                        }
                    } catch is CancellationError {
                        return .interrupted
                    } catch {
                        _ = Instrument.write(
                            ["error": "\(rung.name) did not warm up within \(Self.rungLimit); anything measured after it would be beside a generation still running"],
                            to: write)
                        return .failure
                    }
                }
                warmed = true
                guard !Task.isCancelled else { return .interrupted }
            }
            // What makes the case hard, beside what each rung made of it: a wrong answer is easier to
            // read against the reason the case is in the set at all.
            var row: [String: Any] = ["word": labelled.word, "why": labelled.why]
            for rung in rungs {
                let started = ContinuousClock.now
                // **The instrument's own bound.** A rung that never answers would otherwise hang the
                // whole report until something outside kills it, and the run would report nothing at
                // all rather than which rung stopped.
                let choice: SenseSelection
                do {
                    choice = try await withDeadline(Self.rungLimit) {
                        await rung.selector.choose(
                            from: candidates, reading: labelled.sentence, context: .complete,
                            partOfSpeech: partOfSpeech)
                    }
                } catch is CancellationError {
                    // A run someone stopped measured nothing. Filed as an abstention it would be a
                    // rung's score, which is the one thing this report must not invent.
                    return .interrupted
                } catch {
                    _ = Instrument.write(
                        ["error": "\(rung.name) did not answer for \(labelled.word): \(error)"], to: write)
                    return .failure
                }
                let took = ContinuousClock.now - started
                milliseconds[rung.name, default: []].append(
                    Int(took.components.seconds * 1_000 + took.components.attoseconds / 1_000_000_000_000_000))
                let bucket = LabelledSenses.bucket(choice, correct: labelled.correct)
                scores[rung.name]?[bucket.rawValue, default: 0] += 1
                row[rung.name] = choice.abstention.map { "\(bucket.rawValue) (\($0.rawValue))" } ?? bucket.rawValue
                // **Which sense, not only which bucket.** Two different wrong answers both read as
                // "wrong", so a ladder that dropped its top rung's answer and got the same bucket
                // from a lower one passed the check that says the answer was carried through.
                row["\(rung.name)Key"] = choice.key ?? choice.nearest?.key ?? NSNull()
            }
            answers.append(row)
        }
        let report: [String: Any] = [
            "cases": LabelledSenses.hardCases.count, "localModelInstalled": models.isInstalled,
            // **The shipped ladder's own order**, read from the value the app uses. Scoring a rung
            // beside the ladder says nothing about where the ladder puts it; this is what a check
            // on the order can be made against.
            "order": ladder.rungs.map(\.name),
            "scores": scores, "answers": answers, "milliseconds": milliseconds,
        ]
        return Instrument.write(report, to: write) ? .success : .internalError
    }

    /// What one rung gets for one case. Far past a cold load and grammar compile on a slow Mac,
    /// and far short of the harness's own watchdog — a report that says which rung stopped is worth
    /// more than one killed from outside with nothing written.
    static let rungLimit = Duration.seconds(120)

    struct NoCandidates: Error, CustomStringConvertible {
        let description: String
    }

    /// Every sense NOAD has for `word` — **by identifier, never by display name**, which changes with
    /// the reader's interface language and would have this report claim NOAD is disabled.
    private static func candidates(
        for word: String, from dictionaries: DictionaryClient
    ) async throws -> [SenseCandidate] {
        let outcome = try await dictionaries.lookup(word)
        switch outcome {
        case .entries(let found, let unreadable):
            let noad = found.filter { $0.dictionary.identifier == DictionaryIdentity.noad }
            guard !noad.isEmpty else {
                throw NoCandidates(description: "NOAD is not enabled in Dictionary.app on this Mac")
            }
            // **An entry that could not be read is a missing candidate**, and a rung scored against
            // a set with senses missing is scored on a different field from the one the labels were
            // written for. The set is NOAD-only, so any unreadable dictionary named here may be it.
            guard unreadable.isEmpty else {
                throw NoCandidates(
                    description: "\(word): \(unreadable.joined(separator: ", ")) could not be read, so the candidate set is incomplete")
            }
            return SenseResolver.candidates(in: noad)
        case .plainText(_, let failure):
            throw NoCandidates(description: "the dictionary service did not answer (\(failure)); only plain text came back")
        case .notFound(let failure):
            throw NoCandidates(description: "no dictionary has \(word)\(failure.map { " (\($0))" } ?? "")")
        }
    }
}
