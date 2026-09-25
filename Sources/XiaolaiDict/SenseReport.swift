import DictionaryModel
import Foundation
import XiaolaiDictBase
import XiaolaiDictCore

/// `--sense-report`: **the ladder's order, decided on the labelled set** — every rung scored on the
/// same six NOAD cases, inside the signed bundle, through the real paths: entries from the
/// dictionary service, the local model through its service, Apple's model where it runs.
///
/// Here rather than in the test suite because it is the only place all three rungs exist at once:
/// the suite cannot link MLX's service, and the E2E Mac — where Apple Intelligence runs — has the
/// bundle and not the sources. Nine hand-written cases favoured Qwen; this is what decides.
///
/// Scored in the suite's five buckets, and the number that decides honesty is `wrong` — a sense
/// marked with confidence and mistaken.
///
/// **Every parameter but `write` is defaulted to what the instrument runs with, and only a test
/// passes one.** `run` used to build its own model access, dictionary client, case list and
/// deadline, so its scoring, its buckets and the three ways it can stop were reachable from the
/// E2E Mac and from nowhere else — which is to say they were not covered at all.
@MainActor
enum SenseReport {
    /// Where the candidate set comes from. The dictionary service by default; a test hands in
    /// senses of its own, which is what lets the scoring be measured without a Mac full of
    /// dictionaries.
    typealias CandidateSource = (String) async throws -> Candidates

    /// NOAD's senses for one word, **and which NOAD answered**. A sense key is only meaningful
    /// inside one version of one dictionary, so the identity travels out with the senses rather
    /// than being dropped by the one function that had it in hand.
    struct Candidates {
        let senses: [SenseCandidate]
        let dictionary: DictionaryIdentity
    }

    /// **Which model answered.** The report named none, so a 2B run and a 4B run produced
    /// indistinguishable output — and the order this project records was read off one of them,
    /// with nothing in the artifact to say which size earned it.
    struct MeasuredModel {
        /// Whether this Mac counts the model as here at all, by the same rule the setup board uses.
        let installed: Bool
        let size: LocalModelSize?
        let loaded: Bool
        /// The pin, not only the size: an older revision of the same size satisfies every check
        /// that compares sizes.
        let identifier: String?
    }

    static func run(
        write: (String) -> Bool = LookupCommand.writeLine,
        models: LocalModelAccess = LocalModelAccess(client: ModelClient(), store: .standard()),
        rungs measuring: [(name: String, selector: any SenseSelecting)]? = nil,
        cases: [LabelledCase] = LabelledSenses.hardCases,
        candidates: CandidateSource? = nil,
        limit: Duration = rungLimit
    ) async -> CommandStatus {
        // **The shipped ladder and its own rungs** — one set of selectors, so the measurement
        // cannot be of a different composition from the one readers get. Where a caller measures
        // rungs of its own, the composite is the ladder over exactly those.
        let rungs: [(name: String, selector: any SenseSelecting)]
        let ladder: LadderSenseSelector
        if let measuring {
            rungs = measuring
            ladder = LadderSenseSelector(rungs: measuring.map(\.selector))
        } else {
            let shipped = models.senseLadder
            (rungs, ladder) = (shipped.rungs, shipped.ladder)
        }
        let measured = rungs + [("ladder", ladder)]
        // Every bucket present in every rung's score, so a report never leaves a reader guessing
        // whether a missing key means zero or a bucket that was not counted.
        var scores = Dictionary(uniqueKeysWithValues: measured.map { rung in
            (rung.name, Dictionary(uniqueKeysWithValues: LabelledSenses.Bucket.allCases.map { ($0.rawValue, 0) }))
        })
        var answers: [[String: Any]] = []
        var milliseconds: [String: [Int]] = [:]
        // **One dictionary client for the whole run**, captured by the closure that uses it — and
        // none at all where the caller brought its own senses, so nothing here opens a session that
        // is never asked anything.
        let lookUp = candidates ?? {
            let dictionaries = DictionaryClient()
            return { try await Self.candidates(for: $0, from: dictionaries) }
        }()
        var dictionary: DictionaryIdentity?
        var warmed = false
        for labelled in cases {
            let found: Candidates
            do {
                found = try await lookUp(labelled.word)
            } catch is CancellationError {
                return stop(.interrupted, to: write)
            } catch {
                return stop(.failed(String(describing: error)), to: write)
            }
            // **The labelled answer has to be among the candidates.** A dictionary asset updated
            // under us, or a parser change that drops a sense, would otherwise be scored as every
            // rung getting the word wrong — the instrument reporting a model defect for a fixture
            // one. Checked against the set as it is today, before anything is asked of a model.
            if let correct = labelled.correct, !found.senses.contains(where: { $0.key == correct }) {
                return stop(
                    .failed("\(labelled.word): the labelled sense \(correct) is not among NOAD's candidates today, so this set cannot score it"),
                    to: write)
            }
            // Which dictionary answered, carried out with the senses. Every case is the same one;
            // recording it per case would say the same thing six times.
            dictionary = found.dictionary
            let partOfSpeech = Lemmatizer.partOfSpeech(of: labelled.word, in: labelled.sentence, at: nil)
            if !warmed {
                if case .failure(let why) = await warmUp(
                    rungs, on: labelled, from: found.senses, partOfSpeech: partOfSpeech, limit: limit) {
                    return stop(why, to: write)
                }
                warmed = true
                guard !Task.isCancelled else { return .interrupted }
            }
            switch await score(
                labelled, with: measured, from: found.senses, partOfSpeech: partOfSpeech, limit: limit) {
            case .success(let scored):
                answers.append(scored.row)
                for (rung, bucket) in scored.buckets { scores[rung]?[bucket.rawValue, default: 0] += 1 }
                for (rung, took) in scored.milliseconds { milliseconds[rung, default: []].append(took) }
            case .failure(let why):
                return stop(why, to: write)
            }
        }
        let model = await measuredModel(models)
        let report: [String: Any] = [
            "cases": cases.count, "localModelInstalled": model.installed,
            // **Which model answered.** Without these three a 2B run and a 4B run are the same
            // artifact, and the order recorded from one of them cannot be attributed to a size.
            "modelSize": model.size?.rawValue ?? NSNull(),
            "modelLoaded": model.loaded,
            "modelIdentifier": model.identifier ?? NSNull(),
            // **And which dictionary issued the keys.** A sense key is only meaningful inside one
            // version of one dictionary, so a report that names neither cannot be read again after
            // an asset update moved the senses under it.
            "dictionary": dictionary?.identifier ?? NSNull(),
            "dictionaryVersion": dictionary?.version ?? NSNull(),
            // **The shipped ladder's own order**, read from the value the app uses. Scoring a rung
            // beside the ladder says nothing about where the ladder puts it; this is what a check
            // on the order can be made against.
            "order": rungs.map(\.name),
            "scores": scores, "answers": answers, "milliseconds": milliseconds,
        ]
        return Instrument.write(report, to: write) ? .success : .internalError
    }

    /// What one rung gets for one case. Far past a cold load and grammar compile on a slow Mac,
    /// and far short of the harness's own watchdog — a report that says which rung stopped is worth
    /// more than one killed from outside with nothing written.
    static let rungLimit = Duration.seconds(120)

    /// Why a run stopped before it had a report to write.
    private enum Stopped: Error {
        /// Someone stopped the run, so it measured nothing. Filed as an abstention it would be a
        /// rung's score, which is the one thing this report must not invent.
        case interrupted
        case failed(String)
    }

    /// **The one place a stopped run is written.** Four sites built this line for themselves, and
    /// the text goes through the serialiser rather than into a line assembled by hand: an error's
    /// description carries quotes, backslashes and newlines, and an invalid JSON line reads to the
    /// harness as the instrument crashing rather than as the failure it is.
    private static func stop(_ why: Stopped, to write: (String) -> Bool) -> CommandStatus {
        switch why {
        case .interrupted:
            return .interrupted
        case .failed(let message):
            _ = Instrument.write(["error": message], to: write)
            return .failure
        }
    }

    /// **Warmed before anything is timed.** Otherwise the first rung measured pays the cold load
    /// and grammar compile that every rung after it is spared, and the numbers say more about the
    /// order they were run in than about the rungs.
    ///
    /// **The rungs, never the composite.** `LadderSenseSelector` is a struct over these same rung
    /// values and holds no state of its own, so warming it too is one extra generation through
    /// whichever rung decides first — which is the rung the line above it has just warmed.
    private static func warmUp(
        _ rungs: [(name: String, selector: any SenseSelecting)], on labelled: LabelledCase,
        from candidates: [SenseCandidate], partOfSpeech: String?, limit: Duration
    ) async -> Result<Void, Stopped> {
        for rung in rungs {
            // **A warm-up that timed out stops the run.** `withDeadline` gives up on work it
            // cannot cancel, so a generation that overran would go on running beside every timing
            // below — and the numbers would be of two answers at once.
            do {
                _ = try await withDeadline(limit) {
                    await rung.selector.choose(
                        from: candidates, reading: labelled.sentence, context: .complete,
                        partOfSpeech: partOfSpeech)
                }
            } catch is CancellationError {
                return .failure(.interrupted)
            } catch {
                return .failure(.failed(
                    "\(rung.name) did not warm up within \(limit); anything measured after it would be beside a generation still running"))
            }
        }
        return .success(())
    }

    /// What one case yielded: the row the report prints, and the buckets and timings the totals are
    /// made of. Kept in rung order, so folding them into the totals cannot reorder them.
    private struct Scored {
        var row: [String: Any]
        var buckets: [(rung: String, bucket: LabelledSenses.Bucket)] = []
        var milliseconds: [(rung: String, took: Int)] = []
    }

    /// Every rung asked the same case, timed.
    private static func score(
        _ labelled: LabelledCase, with rungs: [(name: String, selector: any SenseSelecting)],
        from candidates: [SenseCandidate], partOfSpeech: String?, limit: Duration
    ) async -> Result<Scored, Stopped> {
        // What makes the case hard, beside what each rung made of it: a wrong answer is easier to
        // read against the reason the case is in the set at all.
        var scored = Scored(row: ["word": labelled.word, "why": labelled.why])
        for rung in rungs {
            let started = ContinuousClock.now
            // **The instrument's own bound.** A rung that never answers would otherwise hang the
            // whole report until something outside kills it, and the run would report nothing at
            // all rather than which rung stopped.
            let choice: SenseSelection
            do {
                choice = try await withDeadline(limit) {
                    await rung.selector.choose(
                        from: candidates, reading: labelled.sentence, context: .complete,
                        partOfSpeech: partOfSpeech)
                }
            } catch is CancellationError {
                return .failure(.interrupted)
            } catch {
                return .failure(.failed("\(rung.name) did not answer for \(labelled.word): \(error)"))
            }
            let took = ContinuousClock.now - started
            scored.milliseconds.append((rung.name, Int(took.milliseconds.rounded())))
            let bucket = LabelledSenses.bucket(choice, correct: labelled.correct)
            scored.buckets.append((rung.name, bucket))
            scored.row[rung.name] = choice.abstention.map { "\(bucket.rawValue) (\($0.rawValue))" } ?? bucket.rawValue
            // **Which sense, not only which bucket.** Two different wrong answers both read as
            // "wrong", so a ladder that dropped its top rung's answer and got the same bucket
            // from a lower one passed the check that says the answer was carried through.
            scored.row["\(rung.name)Key"] = choice.key ?? choice.nearest?.key ?? NSNull()
        }
        return .success(scored)
    }

    /// Asked of the service the way `--model-status` asks it, and **after the cases rather than
    /// before**: the service is launch-on-demand, so nothing is loaded until the first question and
    /// `loaded` would read false on every run that worked.
    private static func measuredModel(_ models: LocalModelAccess) async -> MeasuredModel {
        let installed = models.isInstalled
        guard case .status(let status)? = await models.ask(.status) else {
            return MeasuredModel(installed: installed, size: nil, loaded: false, identifier: nil)
        }
        return MeasuredModel(
            installed: installed, size: status.installed, loaded: status.loaded,
            identifier: status.installed?.manifest.identifier)
    }

    struct NoCandidates: Error, CustomStringConvertible {
        let description: String
    }

    /// Every sense NOAD has for `word` — **by identifier, never by display name**, which changes with
    /// the reader's interface language and would have this report claim NOAD is disabled.
    ///
    /// The default `CandidateSource`, reachable so the tests can put a scripted dictionary service
    /// behind it: what it refuses is what a release measurement is thrown away for.
    static func candidates(
        for word: String, from dictionaries: DictionaryClient
    ) async throws -> Candidates {
        let outcome = try await dictionaries.lookup(word)
        switch outcome {
        case .entries(let found, let unreadable):
            let noad = found.filter { $0.dictionary.identifier == DictionaryIdentity.noad }
            guard let identity = noad.first?.dictionary else {
                throw NoCandidates(description: "NOAD is not enabled in Dictionary.app on this Mac")
            }
            // **An entry that could not be read is a missing candidate**, and a rung scored against
            // a set with senses missing is scored on a different field from the one the labels were
            // written for. **NOAD's own, though**: `unreadable` names every dictionary that had the
            // term and could not show it, while the candidate set is NOAD's alone — so one broken
            // Longman or 譯典通 record voided a run of the measurement a release is read from. Named
            // per dictionary, from the same identity the readable entries carry, so the name NOAD's
            // entries came back under is what says whether NOAD is the one that lost a record. Every
            // NOAD record failing is the guard above: no entries at all.
            if unreadable.contains(identity.name) {
                throw NoCandidates(
                    description: "\(word): \(identity.name) could not be read, so the candidate set is incomplete")
            }
            return Candidates(senses: SenseResolver.candidates(in: noad), dictionary: identity)
        case .plainText(_, let failure):
            throw NoCandidates(description: "the dictionary service did not answer (\(failure)); only plain text came back")
        case .notFound(let failure):
            throw NoCandidates(description: "no dictionary has \(word)\(failure.map { " (\($0))" } ?? "")")
        }
    }
}
