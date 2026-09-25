import Foundation
import Synchronization
import Testing
@testable import XiaolaiDict
@testable import XiaolaiDictCore
import XiaolaiDictBase
import XiaolaiDictTestSupport

/// The instrument that decided the ladder's order, exercised with scripted rungs.
///
/// It measures on the E2E Mac and nowhere else, so for as long as it built its own model access,
/// dictionary client, case list and deadline, **nothing here could reach it at all**: the scoring,
/// the buckets, the fixture check and the three ways a run stops were covered by the one machine
/// that runs `--sense-report`, which is to say by a report a person reads afterwards. These tests
/// go through `run` itself and read the line it writes.
@MainActor
struct SenseReportTests {
    // MARK: the labelled set this suite scores on

    private static let noad = DictionaryIdentity(
        name: "New Oxford American Dictionary", identifier: DictionaryIdentity.noad, version: "2.6")

    private static let cases = [
        LabelledCase(
            word: "fine", sentence: "He was ordered to pay a heavy fine for speeding.",
            correct: "fine.right", why: "the penalty, not the adjective"),
        LabelledCase(
            word: "hold", sentence: "It was stowed forward in the ship's hold.",
            correct: "hold.right", why: "the cargo space, not the grip"),
    ]

    /// Two senses per word, one of them the labelled answer.
    private static func senses(for word: String) -> [SenseCandidate] {
        ["\(word).right", "\(word).wrong"].map {
            SenseCandidate(
                entryID: "m_en_\(word)", key: $0, keyKind: .publisher, text: "a sense of \(word)",
                partOfSpeech: "noun")
        }
    }

    private static func candidates(for word: String) -> SenseReport.Candidates {
        SenseReport.Candidates(senses: senses(for: word), dictionary: noad)
    }

    /// A model access with nothing installed: `isInstalled` is false, so **no session is ever
    /// opened** and the run never reaches XPC. What the status question asks of a Mac with no
    /// model, which is every Mac running this suite.
    private static func noModel() -> LocalModelAccess {
        LocalModelAccess(
            client: ModelClient(connect: { _ in throw NoService() }),
            store: ModelStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)))
    }

    private struct NoService: Error {}

    /// The one line the instrument wrote, decoded.
    private static func written(_ lines: [String]) throws -> [String: Any] {
        let line = try #require(lines.last, "the instrument wrote nothing")
        return try #require(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            "the instrument wrote a line that is not JSON: \(line)")
    }

    // MARK: the measurement

    /// The happy path, and the three things the harness reads off it: the order the rungs were
    /// measured in, what each answered on each case, and a timing per rung per case.
    @Test func everyRungIsScoredOnEveryCaseInTheOrderItWasMeasured() async throws {
        let top = ScriptedRung { word, _ in .chose(key: "\(word).right", margin: nil) }
        let bottom = ScriptedRung { word, _ in .chose(key: "\(word).wrong", margin: nil) }
        let lines = Recorder<[String]>([])

        let status = await SenseReport.run(
            write: { line in lines.withLock { $0.append(line) }; return true },
            models: Self.noModel(),
            rungs: [("top", top), ("bottom", bottom)],
            cases: Self.cases,
            candidates: { Self.candidates(for: $0) })

        #expect(status == .success)
        let report = try Self.written(lines.withLock { $0 })
        #expect(report["cases"] as? Int == 2)
        #expect(report["order"] as? [String] == ["top", "bottom"], "the composite is not a rung of the ladder")

        let scores = try #require(report["scores"] as? [String: [String: Int]])
        #expect(scores["top"]?["right"] == 2)
        #expect(scores["top"]?["wrong"] == 0)
        #expect(scores["bottom"]?["wrong"] == 2)
        // The ladder is the composite over exactly these rungs, so it answers as its top rung does.
        #expect(scores["ladder"]?["right"] == 2)

        let answers = try #require(report["answers"] as? [[String: Any]])
        #expect(answers.map { $0["word"] as? String } == ["fine", "hold"])
        #expect(answers.first?["why"] as? String == "the penalty, not the adjective")
        #expect(answers.first?["top"] as? String == "right")
        #expect(answers.first?["bottom"] as? String == "wrong")
        // Which sense, not only which bucket: two different wrong answers both read as "wrong".
        #expect(answers.first?["topKey"] as? String == "fine.right")
        #expect(answers.first?["bottomKey"] as? String == "fine.wrong")
        #expect(answers.first?["ladderKey"] as? String == "fine.right")

        let milliseconds = try #require(report["milliseconds"] as? [String: [Int]])
        #expect(milliseconds.keys.sorted() == ["bottom", "ladder", "top"])
        for (rung, took) in milliseconds {
            #expect(took.count == Self.cases.count, "\(rung) was timed \(took.count) times on 2 cases")
        }
    }

    /// **The rungs are warmed; the composite over them is not.** `LadderSenseSelector` is a struct
    /// over these same rung values and holds no state of its own, so warming it as well is one
    /// extra generation through whichever rung decides first — on the E2E Mac one more 4B answer
    /// per run, charged to the rung the line above it has just warmed.
    ///
    /// Counted rather than timed: an elapsed-time assertion would measure how many other tests the
    /// runner is executing, and the extra generation is a single call among ten.
    @Test func theWarmUpAsksTheRungsAndNotTheCompositeOverThem() async throws {
        let top = ScriptedRung { word, _ in .chose(key: "\(word).right", margin: nil) }
        let bottom = ScriptedRung { word, _ in .chose(key: "\(word).wrong", margin: nil) }

        let status = await SenseReport.run(
            write: { _ in true },
            models: Self.noModel(),
            rungs: [("top", top), ("bottom", bottom)],
            cases: Self.cases,
            candidates: { Self.candidates(for: $0) })

        #expect(status == .success)
        // One warm-up, then one timed call per case — and one more per case through the ladder,
        // which stops at the first rung that answers and so never reaches `bottom`.
        #expect(top.asked.withLock { $0 }.count == 1 + 2 + 2, "the composite was warmed as though it were a rung")
        #expect(bottom.asked.withLock { $0 }.count == 1 + 2)
    }

    /// **A rung that says nothing is still a rung that ran.** Every bucket is present in every
    /// rung's score, so a missing key can never be read as a zero that was measured.
    @Test func aRungThatAbstainsThroughoutIsStillCountedInEveryBucket() async throws {
        let quiet = ScriptedRung { _, _ in .abstained(.unavailable) }
        let lines = Recorder<[String]>([])

        let status = await SenseReport.run(
            write: { line in lines.withLock { $0.append(line) }; return true },
            models: Self.noModel(),
            rungs: [("quiet", quiet)],
            cases: Self.cases,
            candidates: { Self.candidates(for: $0) })

        #expect(status == .success)
        let report = try Self.written(lines.withLock { $0 })
        let scores = try #require(report["scores"] as? [String: [String: Int]])
        let quietly = try #require(scores["quiet"])
        #expect(quietly.keys.sorted() == LabelledSenses.Bucket.allCases.map(\.rawValue).sorted())
        #expect(quietly["abstained"] == 2)
        #expect(quietly.values.reduce(0, +) == 2, "a rung was scored more cases than it was asked")
        // The reason travels with the bucket: "abstained" alone cannot say whether the rung judged
        // the sentence or was never here.
        let answers = try #require(report["answers"] as? [[String: Any]])
        #expect(answers.first?["quiet"] as? String == "abstained (unavailable)")
        #expect(answers.first?["quietKey"] is NSNull)
    }

    /// **A fixture defect must not be scored as a model defect.** A dictionary asset updated under
    /// us, or a parser change that drops a sense, would otherwise read as every rung getting the
    /// word wrong — so the set is checked against the senses as they are today, and no rung is
    /// asked anything before it passes.
    @Test func aLabelledSenseNoLongerAmongTheCandidatesStopsTheRunBeforeAnyRungIsAsked() async throws {
        let rung = ScriptedRung { word, _ in .chose(key: "\(word).right", margin: nil) }
        let lines = Recorder<[String]>([])

        let status = await SenseReport.run(
            write: { line in lines.withLock { $0.append(line) }; return true },
            models: Self.noModel(),
            rungs: [("top", rung)],
            cases: Self.cases,
            candidates: { word in
                SenseReport.Candidates(
                    senses: Self.senses(for: word).filter { $0.key != "fine.right" }, dictionary: Self.noad)
            })

        #expect(status == .failure)
        let report = try Self.written(lines.withLock { $0 })
        let why = try #require(report["error"] as? String)
        #expect(why == "fine: the labelled sense fine.right is not among NOAD's candidates today, so this set cannot score it")
        #expect(rung.asked.withLock { $0 }.isEmpty, "a rung was asked about a case the set cannot score")
        #expect(report["scores"] == nil, "a run that scored nothing wrote scores")
    }

    /// **A rung that never answers is named.** `withDeadline` gives up on work it cannot cancel, so
    /// a warm-up that overran would go on generating beside every timing after it — and a report
    /// killed from outside says nothing at all about which rung stopped.
    @Test func aRungThatOutlivesTheLimitWhileWarmingIsNamed() async throws {
        let slow = ScriptedRung { word, _ in
            try? await Task.sleep(for: .seconds(30))
            return .chose(key: "\(word).right", margin: nil)
        }
        let lines = Recorder<[String]>([])

        let status = await SenseReport.run(
            write: { line in lines.withLock { $0.append(line) }; return true },
            models: Self.noModel(),
            rungs: [("fast", ScriptedRung { word, _ in .chose(key: "\(word).right", margin: nil) }),
                    ("stalled", slow)],
            cases: Self.cases,
            candidates: { Self.candidates(for: $0) },
            limit: .milliseconds(100))

        #expect(status == .failure)
        let why = try #require(try Self.written(lines.withLock { $0 })["error"] as? String)
        #expect(why.hasPrefix("stalled did not warm up within"), "the report did not name the rung that stopped: \(why)")
    }

    /// The same bound while the rungs are being timed — and there the **word** matters too: a rung
    /// that answers five cases and stalls on the sixth is a different finding from one that never
    /// answered at all.
    @Test func aRungThatStallsWhileBeingTimedIsNamedWithTheWordItStalledOn() async throws {
        // The first call is the warm-up, which must pass; every call after it stalls.
        let slow = ScriptedRung { word, turn in
            if turn > 1 { try? await Task.sleep(for: .seconds(30)) }
            return .chose(key: "\(word).right", margin: nil)
        }
        let lines = Recorder<[String]>([])

        let status = await SenseReport.run(
            write: { line in lines.withLock { $0.append(line) }; return true },
            models: Self.noModel(),
            rungs: [("stalled", slow)],
            cases: Self.cases,
            candidates: { Self.candidates(for: $0) },
            limit: .milliseconds(100))

        #expect(status == .failure)
        let why = try #require(try Self.written(lines.withLock { $0 })["error"] as? String)
        #expect(why.hasPrefix("stalled did not answer for fine:"), "the report did not say which case stopped: \(why)")
    }

    /// **A run someone stopped measured nothing.** Reported as a failure it would read as a defect
    /// in the ladder, and written as an abstention it would be a rung's score — which is the one
    /// thing this report must not invent.
    @Test func aStoppedLookupIsInterruptedRatherThanAFailure() async throws {
        let rung = ScriptedRung { word, _ in .chose(key: "\(word).right", margin: nil) }
        let lines = Recorder<[String]>([])

        let status = await SenseReport.run(
            write: { line in lines.withLock { $0.append(line) }; return true },
            models: Self.noModel(),
            rungs: [("top", rung)],
            cases: Self.cases,
            candidates: { _ in throw CancellationError() })

        #expect(status == .interrupted)
        #expect(lines.withLock { $0 }.isEmpty, "a run that measured nothing wrote a report")
        #expect(rung.asked.withLock { $0 }.isEmpty)
    }

    /// **Which model answered.** The report carried the scores, the order and the timings and
    /// nothing naming the model behind them, so a 2B run and a 4B run produced indistinguishable
    /// output — and the order this project records was read off one of them.
    @Test func theReportNamesTheModelTheRungsWereMeasuredWith() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-sense-report")
        let store = try Self.storeHolding(.standard, in: scratch)
        let service = StatusService(ModelServiceStatus(
            installed: .standard, loaded: true, gpu: "Apple M4 Max", footprint: 2_733 * 1_048_576,
            availableMemory: 20 * 1_073_741_824))
        let models = LocalModelAccess(
            client: ModelClient(connect: { _ in service.transport() }), store: store,
            physicalMemory: 48 * 1_073_741_824)
        let lines = Recorder<[String]>([])

        let status = await SenseReport.run(
            write: { line in lines.withLock { $0.append(line) }; return true },
            models: models,
            rungs: [("top", ScriptedRung { word, _ in .chose(key: "\(word).right", margin: nil) })],
            cases: Self.cases,
            candidates: { Self.candidates(for: $0) })

        #expect(status == .success)
        let report = try Self.written(lines.withLock { $0 })
        #expect(report["localModelInstalled"] as? Bool == true)
        #expect(report["modelSize"] as? String == LocalModelSize.standard.rawValue)
        #expect(report["modelLoaded"] as? Bool == true)
        // The pin, not only the size: an older revision of the same size satisfies every check
        // that compares sizes.
        #expect(report["modelIdentifier"] as? String == LocalModelSize.standard.manifest.identifier)
        withExtendedLifetime(scratch) {}
    }

    /// **And which dictionary issued the keys.** A sense key is only meaningful inside one version
    /// of one dictionary, so a report naming neither cannot be read again once an asset update has
    /// moved the senses under it.
    @Test func theReportNamesTheDictionaryTheKeysBelongTo() async throws {
        let lines = Recorder<[String]>([])
        let status = await SenseReport.run(
            write: { line in lines.withLock { $0.append(line) }; return true },
            models: Self.noModel(),
            rungs: [("top", ScriptedRung { word, _ in .chose(key: "\(word).right", margin: nil) })],
            cases: Self.cases,
            candidates: { Self.candidates(for: $0) })

        #expect(status == .success)
        let report = try Self.written(lines.withLock { $0 })
        #expect(report["dictionary"] as? String == DictionaryIdentity.noad)
        #expect(report["dictionaryVersion"] as? String == "2.6")
    }

    /// A store holding one model whole, as the downloader would leave it.
    ///
    /// **Each file is truncated to its pinned length, never written.** The store checks a file's
    /// size and nothing else about its bytes, and the 4B weights are 3,034,300,695 of them — a
    /// fixture built by writing that many zeros costs three gigabytes of memory and three of disk
    /// for a number that a sparse file answers just as well. Measured here at 2.0 s against 0.02 s.
    private static func storeHolding(_ size: LocalModelSize, in scratch: TemporaryDirectory) throws -> ModelStore {
        let store = ModelStore(root: scratch.url)
        let manifest = size.manifest
        let directory = store.directory(for: manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in manifest.files {
            let url = directory.appending(path: file.path)
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.size))
            try handle.close()
        }
        try ModelStore.markerText(for: manifest).write(
            to: directory.appending(path: ModelStore.completionMarker), atomically: true, encoding: .utf8)
        return store
    }
}

/// **The candidate set is NOAD's alone**, so what makes it incomplete is NOAD losing a record —
/// not any of the other six dictionaries on the E2E Mac having a term it cannot show.
@MainActor
struct SenseReportCandidateTests {
    private static let noad = DictionaryIdentity(
        name: "New Oxford American Dictionary", identifier: DictionaryIdentity.noad, version: "2.6")

    private static func entry(_ dictionary: DictionaryIdentity) -> DictionaryEntry {
        DictionaryEntry(
            dictionary: dictionary, headword: "fine", lookedUp: "fine", html: "<html/>", document: nil)
    }

    /// One broken Longman or 譯典通 record used to throw away a whole run of the measurement a
    /// release is read from — `unreadable` names every dictionary that had the term and could not
    /// show it, and the guard asked only whether the list was empty.
    @Test func anUnreadableDictionaryThatIsNotNOADDoesNotVoidTheRun() async throws {
        let client = FakeDictionaries(
            entries: [Self.entry(Self.noad)], unreadable: ["Longman", "譯典通"]).client()
        let found = try await SenseReport.candidates(for: "fine", from: client)
        #expect(found.dictionary.identifier == DictionaryIdentity.noad)
    }

    /// NOAD losing one of its own records is still a candidate set with senses missing, and a rung
    /// scored against it is scored on a different field from the one the labels were written for.
    @Test func anUnreadableNOADRecordStopsTheRun() async throws {
        let client = FakeDictionaries(
            entries: [Self.entry(Self.noad)], unreadable: ["Longman", Self.noad.name]).client()
        await #expect(throws: SenseReport.NoCandidates.self) {
            try await SenseReport.candidates(for: "fine", from: client)
        }
    }

    /// Every NOAD record failing is the other guard: no NOAD entries at all.
    @Test func noNOADEntriesIsReportedAsNOADNotBeingEnabled() async throws {
        let client = FakeDictionaries(
            entries: [Self.entry(DictionaryIdentity(name: "Longman", identifier: nil))],
            unreadable: []).client()
        do {
            _ = try await SenseReport.candidates(for: "fine", from: client)
            Issue.record("a set with no NOAD entries was accepted")
        } catch let why as SenseReport.NoCandidates {
            #expect(why.description.contains("NOAD is not enabled"))
        }
    }

    /// The identity the senses came from, carried out rather than discarded by the one function
    /// that had it.
    @Test func theCandidatesCarryWhichDictionaryAnsweredAndWhichVersionOfIt() async throws {
        let client = FakeDictionaries(entries: [Self.entry(Self.noad)], unreadable: []).client()
        let found = try await SenseReport.candidates(for: "fine", from: client)
        #expect(found.dictionary.identifier == DictionaryIdentity.noad)
        #expect(found.dictionary.version == "2.6")
    }
}

/// A rung that answers from a script and counts what it was asked. `turn` is how many times it has
/// been called, which is how a rung that warms up and then stalls is written.
private final class ScriptedRung: SenseSelecting, @unchecked Sendable {
    let asked = Recorder<[String]>([])
    private let answer: @Sendable (String, Int) async -> SenseSelection

    init(_ answer: @escaping @Sendable (String, Int) async -> SenseSelection) {
        self.answer = answer
    }

    func choose(
        from candidates: [SenseCandidate], reading sentence: String?, context: CaptureQuality.Context,
        partOfSpeech: String?
    ) async -> SenseSelection {
        // The word rather than the sentence: the script answers with a key built from it, and the
        // candidates all carry the same stem.
        let word = candidates.first.map { $0.key.split(separator: ".").first.map(String.init) ?? "" } ?? ""
        let turn = asked.withLock { $0.append(word); return $0.count }
        return await answer(word, turn)
    }
}

/// A dictionary service that answers one scripted lookup.
private final class FakeDictionaries: Sendable {
    private let entries: [DictionaryEntry]
    private let unreadable: [String]

    init(entries: [DictionaryEntry], unreadable: [String]) {
        self.entries = entries
        self.unreadable = unreadable
    }

    func client() -> DictionaryClient {
        DictionaryClient(connect: { _ in Transport(service: self) }, fallback: { _ in nil })
    }

    private struct Transport: DictionaryTransport {
        let service: FakeDictionaries

        func send(_ request: ServiceRequest) async throws -> ServiceReply {
            guard case .lookup = request else { return .dictionaries([]) }
            guard let found = NonEmpty(service.entries) else { return .lookup(.notFound) }
            return .lookup(.entries(found, unreadable: service.unreadable))
        }

        func cancel(reason: String) {}
    }
}

/// A model service that answers `.status` and nothing else — what `--sense-report` asks it for.
private final class StatusService: Sendable {
    private let status: ModelServiceStatus

    init(_ status: ModelServiceStatus) { self.status = status }

    func transport() -> any ModelTransport { Transport(service: self) }

    private struct Transport: ModelTransport {
        let service: StatusService

        func send(_ request: ModelRequest) async throws -> ModelReply {
            guard request == .status else { return .failure(.invalidRequest("\(request)")) }
            return .status(service.status)
        }

        func cancel(reason: String) {}
    }
}
