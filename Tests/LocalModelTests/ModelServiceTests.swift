import CryptoKit
import Foundation
import FoundationModels
@testable import LocalModel
import XiaolaiDictTestSupport
import Testing
@testable import XiaolaiDictCore

/// A language model that answers from a script and records what it was asked — the injected
/// executor the plan calls for, so the service's handling is tested with no GPU and no weights.
///
/// The framework builds the executor itself, from `executorConfiguration`, so the script travels as
/// a `Hashable` key into a shared table rather than as the executor's own state.
struct ScriptedModel: LanguageModel {
    typealias Executor = ScriptedExecutor

    enum Behaviour: Sendable {
        case answer(String)
        /// Answers after a pause, counting how many generations run at once.
        case answerSlowly(String)
        /// Hangs on the **first** request and answers every one after it — a prewarm that never
        /// comes back, in front of a question that would answer at once if it were let through.
        case wedgeOnce(String)
        case refuse
        case fail
    }

    let id: UUID
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.guidedGeneration]) }
    var executorConfiguration: UUID { id }

    static let scripts = Recorder<[UUID: Behaviour]>([:])
    /// Everything each model was sent — instructions and prompt — as one string per request.
    static let heard = Recorder<[UUID: [String]]>([:])
    /// The response budget each request carried.
    static let budgets = Recorder<[UUID: [Int?]]>([:])
    /// The sampling temperature each request carried. **Recorded because it is load-bearing**: a
    /// sense answer is a choice from a list and must be deterministic, and nothing else in the
    /// suite would notice it drifting back to the backend's default.
    static let temperatures = Recorder<[UUID: [Double?]]>([:])
    /// Generations running now, and the most there ever were at once.
    static let running = Recorder<(now: Int, most: Int)>((0, 0))
    /// The models whose one wedged request has already been taken.
    static let wedged = Recorder<Set<UUID>>([])

    init(_ behaviour: Behaviour) {
        id = UUID()
        Self.scripts.withLock { $0[id] = behaviour }
    }

    var requests: [String] { Self.heard.withLock { $0[id] ?? [] } }
    var budgets: [Int?] { Self.budgets.withLock { $0[id] ?? [] } }
    var temperatures: [Double?] { Self.temperatures.withLock { $0[id] ?? [] } }
}

struct ScriptedExecutor: LanguageModelExecutor {
    typealias Model = ScriptedModel
    let id: UUID

    init(configuration: UUID) throws { id = configuration }

    func respond(
        to request: LanguageModelExecutorGenerationRequest, model: ScriptedModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        ScriptedModel.heard.withLock { $0[id, default: []].append(Self.text(of: request.transcript)) }
        ScriptedModel.budgets.withLock { $0[id, default: []].append(request.generationOptions.maximumResponseTokens) }
        ScriptedModel.temperatures.withLock { $0[id, default: []].append(request.generationOptions.temperature) }
        switch ScriptedModel.scripts.withLock({ $0[id] }) {
        case .answer(let text)?:
            await channel.send(.response(action: .appendText(text, tokenCount: 1)))
        case .answerSlowly(let text)?:
            ScriptedModel.running.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
            try? await Task.sleep(for: .milliseconds(100))
            ScriptedModel.running.withLock { $0.now -= 1 }
            await channel.send(.response(action: .appendText(text, tokenCount: 1)))
        case .wedgeOnce(let text)?:
            if ScriptedModel.wedged.withLock({ $0.insert(id).inserted }) {
                try? await Task.sleep(for: .seconds(10))
            }
            await channel.send(.response(action: .appendText(text, tokenCount: 1)))
        case .refuse?:
            throw LanguageModelError.refusal(.init(explanation: "declined", debugDescription: "declined"))
        case .fail?, nil:
            throw CancellationError()
        }
    }

    /// Every text segment of every instructions and prompt entry.
    static func text(of transcript: Transcript) -> String {
        transcript.map { entry -> String in
            let segments: [Transcript.Segment]
            switch entry {
            case .instructions(let instructions): segments = instructions.segments
            case .prompt(let prompt): segments = prompt.segments
            default: segments = []
            }
            return segments.compactMap { segment -> String? in
                if case .text(let text) = segment { return text.content }
                return nil
            }.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

struct ModelServiceTests {
    private static let gigabyte: UInt64 = 1_073_741_824

    /// The tiny standard model the tests install: the real one's repository and commit, with files
    /// seven bytes long.
    private static let manifest: ModelManifest = {
        let body = Data("weights".utf8)
        let sha = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let real = LocalModelSize.standard.manifest
        return ModelManifest(
            size: .standard, repository: real.repository, revision: real.revision,
            files: real.files.map {
                ModelFile(repository: $0.repository, revision: $0.revision, path: $0.path, size: Int64(body.count), sha256: sha)
            })
    }()

    /// A store holding it whole, as the downloader would leave it.
    /// A store holding it whole, as the downloader would leave it — **in a directory that removes
    /// itself**, returned alongside so the test holds its lifetime.
    private static func installedStore() throws -> (ModelStore, TemporaryDirectory) {
        let scratch = TemporaryDirectory(named: "xiaolaidict-service")
        let store = ModelStore(root: scratch.url)
        let body = Data("weights".utf8)
        let manifest = Self.manifest
        let directory = store.directory(for: manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in manifest.files { try body.write(to: directory.appending(path: file.path)) }
        try ModelStore.markerText(for: manifest).write(
            to: directory.appending(path: ModelStore.completionMarker), atomically: true, encoding: .utf8)
        return (store, scratch)
    }

    /// The scratch directories these tests made, held for the life of the test instance so they are
    /// removed when it ends — 2,291 had been left behind under the system's temporary directory.
    private let scratches = Recorder<[TemporaryDirectory]>([])

    private func service(
        _ model: ScriptedModel, store: ModelStore? = nil, available: UInt64 = 40 * gigabyte,
        built: Recorder<Int> = Recorder(0), prewarmWait: Duration = .seconds(45)
    ) throws -> ModelService {
        let store = try store ?? {
            let (made, scratch) = try Self.installedStore()
            scratches.withLock { $0.append(scratch) }
            return made
        }()
        return ModelService(
            store: store, manifests: [Self.manifest], physicalMemory: 48 * Self.gigabyte,
            availableMemory: { available },
            makeModel: { _, _ in built.withLock { $0 += 1 }; return model }, prewarmWait: prewarmWait)
    }

    private static let question = SenseQuestion(
        sentence: "The ship's hold was full of grain.", partOfSpeech: "noun",
        senses: ["an act of grasping", "a large space in the lower part of a ship"])

    @Test func aSenseAnswerComesBackAsTheNumberTheModelChose() async throws {
        let model = ScriptedModel(.answer(#"{"senseNumber": 2}"#))
        let reply = try await service(model).reply(to: .pickSense(Self.question))
        #expect(reply == .sense(2))
    }

    /// The model is asked the app's own question: the instructions, the sentence, the part of speech
    /// and every sense, numbered.
    @Test func theModelIsAskedTheAppsOwnQuestion() async throws {
        let model = ScriptedModel(.answer(#"{"senseNumber": 2}"#))
        _ = try await service(model).reply(to: .pickSense(Self.question))
        let asked = try #require(model.requests.first)
        #expect(asked.contains("You identify which dictionary sense of a word"))
        #expect(asked.contains("Sentence: The ship's hold was full of grain."))
        #expect(asked.contains("The word is used as a noun."))
        #expect(asked.contains("2. a large space in the lower part of a ship"))
    }

    /// **The chosen sense reaches Qwen.** The measurement this rests on: told that *hold* meant the
    /// cargo space, 4B wrote 货舱 in every run; untold, the vaguer 船舱.
    @Test func theChosenSenseReachesTheTranslation() async throws {
        let model = ScriptedModel(.answer("这艘船的货舱装满了货物。"))
        let question = TranslationQuestion(
            sentence: "The ship's hold was full.", target: "zh-Hans",
            met: .init(term: "hold", sense: "a large space in the lower part of a ship in which cargo is stored"))
        let reply = try await service(model).reply(to: .translate(question))
        #expect(reply == .translation("这艘船的货舱装满了货物。"))
        let asked = try #require(model.requests.first)
        #expect(asked.contains(#""hold" is used in this sense — a large space in the lower part of a ship in which cargo is stored"#))
        // As prompt data, not as instructions: what a dictionary wrote must not be read as one.
        #expect(!asked.contains("Translate the user's text into natural, fluent Chinese (Simplified). Output only the translation — no notes, no romanisation, no quotation marks.\nIn this text"))
        #expect(asked.contains("The ship's hold was full."))
    }

    /// An echo is not a translation, however confidently it arrives.
    @Test func anEchoIsAFailureNotATranslation() async throws {
        let model = ScriptedModel(.answer("The ship's hold was full."))
        let reply = try await service(model).reply(
            to: .translate(TranslationQuestion(sentence: "The ship's hold was full.", target: "zh-Hans")))
        guard case .failure(.generationFailed) = reply else {
            Issue.record("an echo came back as \(reply)")
            return
        }
    }

    /// A refusal is its own answer — never "no model here".
    @Test func aRefusalIsReportedAsARefusal() async throws {
        let reply = try await service(ScriptedModel(.refuse)).reply(to: .pickSense(Self.question))
        #expect(reply == .failure(.refused))
    }

    @Test func nothingInstalledIsNotInstalled() async throws {
        let empty = ModelStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let built = Recorder(0)
        let reply = try await service(ScriptedModel(.answer("{}")), store: empty, built: built)
            .reply(to: .pickSense(Self.question))
        #expect(reply == .failure(.notInstalled))
        #expect(built.withLock { $0 } == 0)
    }

    /// **Decided before loading.** With 2 GB free, 4B is never built — the model is not constructed,
    /// so nothing is mapped — and the reply says how much it needed.
    @Test func aModelThatDoesNotFitIsNeverLoaded() async throws {
        let built = Recorder(0)
        let reply = try await service(
            ScriptedModel(.answer(#"{"senseNumber": 1}"#)), available: 2 * Self.gigabyte, built: built
        ).reply(to: .pickSense(Self.question))
        #expect(reply == .failure(.insufficientMemory(
            needed: LocalModelSize.standard.peakMemory + ModelSizing.headroom, available: 2 * Self.gigabyte)))
        #expect(built.withLock { $0 } == 0, "a model that does not fit was built")
    }

    /// Unknown free memory is not plenty.
    @Test func unknownFreeMemoryLoadsNothing() async throws {
        let built = Recorder(0)
        let service = ModelService(
            store: try { let (made, scratch) = try Self.installedStore()
                         scratches.withLock { $0.append(scratch) }
                         return made }(),
            manifests: [Self.manifest], physicalMemory: 48 * Self.gigabyte,
            availableMemory: { nil },
            makeModel: { _, _ in built.withLock { $0 += 1 }; return ScriptedModel(.answer("{}")) })
        guard case .failure(.insufficientMemory) = await service.reply(to: .pickSense(Self.question)) else {
            Issue.record("loaded with free memory unknown")
            return
        }
        #expect(built.withLock { $0 } == 0)
    }

    /// Built once, however many questions follow.
    @Test func theModelIsBuiltOnce() async throws {
        let built = Recorder(0)
        let service = try service(ScriptedModel(.answer(#"{"senseNumber": 1}"#)), built: built)
        for _ in 0..<3 { _ = await service.reply(to: .pickSense(Self.question)) }
        #expect(built.withLock { $0 } == 1)
    }

    @Test func statusSaysWhatIsInstalledAndWhetherItIsLoaded() async throws {
        let service = try service(ScriptedModel(.answer(#"{"senseNumber": 1}"#)))
        guard case .status(let before) = await service.reply(to: .status) else { Issue.record("no status"); return }
        #expect(before.installed == .standard)
        #expect(!before.loaded)
        #expect(await service.reply(to: .prewarm) == .prewarmed)
        guard case .status(let after) = await service.reply(to: .status) else { Issue.record("no status"); return }
        #expect(after.loaded)
    }

    /// Loaded is the model having answered — a translation first counts as much as a prewarm.
    @Test func aTranslationFirstLeavesTheModelLoaded() async throws {
        let service = try service(ScriptedModel(.answer("这艘船的货舱装满了。")))
        _ = await service.reply(to: .translate(TranslationQuestion(sentence: "The ship's hold was full.", target: "zh-Hans")))
        guard case .status(let status) = await service.reply(to: .status) else { Issue.record("no status"); return }
        #expect(status.loaded)
    }

    /// Two prewarms at once are one: the second waits on the first rather than running its own.
    @Test func concurrentPrewarmsAskTheModelOnce() async throws {
        let model = ScriptedModel(.answer(#"{"senseNumber": 1}"#))
        let service = try service(model)
        async let first = service.reply(to: .prewarm)
        async let second = service.reply(to: .prewarm)
        #expect(await [first, second] == [.prewarmed, .prewarmed])
        #expect(model.requests.count == 1)
    }

    /// A question arriving while a prewarm runs waits for it instead of generating beside it — the
    /// prewarm is loading the weights and compiling the grammar that question needs.
    @Test func aQuestionWaitsForAPrewarmAlreadyRunning() async throws {
        ScriptedModel.running.withLock { $0 = (0, 0) }
        let service = try service(ScriptedModel(.answerSlowly(#"{"senseNumber": 2}"#)))
        async let warming = service.reply(to: .prewarm)
        try await Task.sleep(for: .milliseconds(20))
        async let answer = service.reply(to: .pickSense(Self.question))
        #expect(await warming == .prewarmed)
        #expect(await answer == .sense(2))
        #expect(ScriptedModel.running.withLock { $0.most } == 1, "two generations ran at once")
    }

    /// …but **not for ever**. A prewarm that never comes back would otherwise hold every later
    /// question behind it for as long as the process lives. Bounded against the wedge itself rather
    /// than against the clock: the answer arrives while the prewarm is still hanging.
    @Test func aQuestionDoesNotWaitForeverOnAPrewarmThatNeverFinishes() async throws {
        let service = try service(
            ScriptedModel(.wedgeOnce(#"{"senseNumber": 2}"#)), prewarmWait: .milliseconds(50))
        let finished = Recorder(false)
        let prewarm = Task { _ = await service.reply(to: .prewarm); finished.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await service.reply(to: .pickSense(Self.question)) == .sense(2))
        #expect(finished.withLock { $0 } == false, "the question waited for the wedged prewarm")
        prewarm.cancel()
    }

    /// A reader who closes the panel takes their question with them. Waiting on a task's value
    /// cannot be given up on, so the wait watches for cancellation itself.
    @Test func aQuestionGivesUpOnAPrewarmWhenItsCallerDoes() async throws {
        let service = try service(ScriptedModel(.wedgeOnce(#"{"senseNumber": 2}"#)))
        let finished = Recorder(false)
        let prewarm = Task { _ = await service.reply(to: .prewarm); finished.withLock { $0 = true } }
        try await Task.sleep(for: .milliseconds(20))
        let question = Task { await service.reply(to: .pickSense(Self.question)) }
        try await Task.sleep(for: .milliseconds(20))
        question.cancel()
        _ = await question.value
        #expect(finished.withLock { $0 } == false, "the cancelled question outlived the wedged prewarm")
        prewarm.cancel()
    }

    /// **The sentence pane's answer comes from this model too.** It is prose, so it is bounded by a
    /// token budget rather than a grammar — and it may carry the dictionary's own sense text,
    /// because this model runs on the reader's Mac.
    @Test func anExplanationComesBackAsProseAndCarriesTheSense() async throws {
        let model = ScriptedModel(.answer("Here it names the cargo space of a ship."))
        let question = SentenceQuestion(
            sentence: "The ship's hold was full.", term: "orlop",
            senseText: "a large space in the lower part of a ship")
        let reply = try await service(model).reply(to: .explain(question))
        #expect(reply == .explanation("Here it names the cargo space of a ship."))
        let asked = try #require(model.requests.first)
        #expect(asked.contains("a large space in the lower part of a ship"))
        // A word the sentence does not contain, so this proves the *term* field reached the prompt
        // rather than matching the sentence it is quoted in.
        #expect(asked.contains("orlop"))
        let budget = try #require(model.budgets.first ?? nil)
        #expect(budget == ModelPrompt.explanationTokens(for: question))
        #expect(budget < 600)
    }

    /// An explanation with nothing to explain is refused before a model is woken for it.
    @Test func anExplanationNeedsASentenceAndAWord() async throws {
        let built = Recorder(0)
        let service = try service(ScriptedModel(.answer("x")), built: built)
        let blank = SentenceQuestion(sentence: "   ", term: "hold", senseText: nil)
        guard case .failure(.invalidRequest) = await service.reply(to: .explain(blank)) else {
            Issue.record("a blank sentence was sent to the model")
            return
        }
        #expect(built.withLock { $0 } == 0)
    }

    /// A model that answers an explanation with nothing has not explained anything.
    @Test func anEmptyExplanationIsAFailureNotAnExplanation() async throws {
        let service = try service(ScriptedModel(.answer("   ")))
        let question = SentenceQuestion(sentence: "The ship's hold was full.", term: "hold", senseText: nil)
        guard case .failure(.generationFailed) = await service.reply(to: .explain(question)) else {
            Issue.record("a blank answer was passed off as an explanation")
            return
        }
    }

    /// **A sense is picked at temperature 0.** It is a choice from a numbered list, not writing:
    /// sampling only lets one sentence be answered two ways, and the measurement compares the rung
    /// against the whole ladder over the same sentence. Left to the backend's default, nothing else
    /// here would have noticed.
    @Test func aSenseIsPickedWithoutSampling() async throws {
        let model = ScriptedModel(.answer(#"{"senseNumber": 2}"#))
        _ = try await service(model).reply(to: .pickSense(Self.question))
        #expect(model.temperatures == [0], "the sense answer was sampled")
    }

    /// Prose is not: at temperature 0 a small model repeats itself, so the translation and the
    /// explanation keep the backend's own sampling and are bounded by their token budget instead.
    @Test func proseKeepsItsSampling() async throws {
        let translator = ScriptedModel(.answer("这艘船的货舱装满了。"))
        _ = try await service(translator).reply(to: .translate(
            TranslationQuestion(sentence: "The ship's hold was full.", target: "zh-Hans")))
        #expect(translator.temperatures == [nil], "the translation was pinned to a temperature")

        let explainer = ScriptedModel(.answer("Here it names the cargo space."))
        _ = try await service(explainer).reply(to: .explain(
            SentenceQuestion(sentence: "The ship's hold was full.", term: "hold")))
        #expect(explainer.temperatures == [nil], "the explanation was pinned to a temperature")
    }

    /// **A generation that failed for any other reason is not a refusal.** `.refused` is the model
    /// declining this sentence and the ladder keeps it apart from everything else; a failed prewarm
    /// is also not kept, so the next one tries again rather than reporting the old failure for ever.
    @Test func aFailedGenerationIsNotARefusalAndAFailedPrewarmIsRetried() async throws {
        let model = ScriptedModel(.fail)
        let service = try service(model)
        guard case .failure(.generationFailed) = await service.reply(to: .pickSense(Self.question)) else {
            Issue.record("a generation that failed was reported as something else")
            return
        }
        guard case .failure = await service.reply(to: .prewarm) else {
            Issue.record("a prewarm over a failing model reported success")
            return
        }
        // Not kept: asked again, the model is asked again.
        _ = await service.reply(to: .prewarm)
        #expect(model.requests.count >= 3, "a failed prewarm was remembered instead of retried")
    }

    /// A list longer than the answer can name is refused before a model is woken for it.
    @Test func moreSensesThanTheAnswerCanNameAreRefused() async throws {
        let built = Recorder(0)
        let service = try service(ScriptedModel(.answer(#"{"senseNumber": 1}"#)), built: built)
        let long = SenseQuestion(sentence: "A sentence.", partOfSpeech: nil, senses: (1...100).map { "sense \($0)" })
        guard case .failure(.invalidRequest) = await service.reply(to: .pickSense(long)) else {
            Issue.record("a list of 100 senses was asked")
            return
        }
        #expect(built.withLock { $0 } == 0)
    }

    /// A translation carries a budget the size of a sentence, never the backend's default of
    /// thousands of tokens.
    @Test func aTranslationIsBudgetedToItsSentence() async throws {
        let model = ScriptedModel(.answer("这艘船的货舱装满了。"))
        let question = TranslationQuestion(sentence: "The ship's hold was full.", target: "zh-Hans")
        _ = try await service(model).reply(to: .translate(question))
        let budget = try #require(model.budgets.first ?? nil)
        #expect(budget == ModelPrompt.translationTokens(for: question))
        #expect(budget < 200)
    }

    /// Prewarming is sent on every lookup's first need; the second one costs the model nothing.
    @Test func prewarmingTwiceAsksTheModelOnce() async throws {
        let model = ScriptedModel(.answer(#"{"senseNumber": 1}"#))
        let service = try service(model)
        #expect(await service.reply(to: .prewarm) == .prewarmed)
        #expect(await service.reply(to: .prewarm) == .prewarmed)
        #expect(model.requests.count == 1)
    }

    /// A question with nothing to ask is refused before a model is woken for it.
    @Test func anEmptyQuestionIsRefusedBeforeLoading() async throws {
        let built = Recorder(0)
        let service = try service(ScriptedModel(.answer("{}")), built: built)
        guard case .failure(.invalidRequest) = await service.reply(
            to: .pickSense(SenseQuestion(sentence: " ", partOfSpeech: nil, senses: ["a"])))
        else { Issue.record("a blank sentence was asked"); return }
        #expect(built.withLock { $0 } == 0)
    }
}

/// The refusal classifier both model rungs share.
struct ModelRefusalTests {
    @Test func aRefusalAndAGuardrailViolationAreRefusals() {
        #expect(ModelRefusal.isRefusal(LanguageModelError.refusal(.init(explanation: "x", debugDescription: "x"))))
        #expect(ModelRefusal.isRefusal(LanguageModelError.guardrailViolation(.init(debugDescription: "x"))))
    }

    /// A context overflow or a cancelled request is the model not answering, never it declining.
    @Test func otherFailuresAreNotRefusals() {
        #expect(!ModelRefusal.isRefusal(LanguageModelError.contextSizeExceeded(
            .init(contextSize: 1, tokenCount: 2, debugDescription: "x"))))
        #expect(!ModelRefusal.isRefusal(CancellationError()))
    }
}
