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
        /// Hangs the **first** request for ten seconds — longer than anything in this suite waits —
        /// and answers every request after it at once: a prewarm the tests can treat as never
        /// coming back, in front of a question that would answer immediately if it were let
        /// through. **A cancelled wedge is not failed**: the sleep is `try?`, so a cancelled wedge
        /// falls out of the pause and answers. That is why every test here asserts what it came for
        /// before it cancels the prewarm, never after.
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
    /// The **instructions** of each request, on their own. Recorded apart from the prompt because
    /// the two roles are not interchangeable and one flattened string cannot tell them apart: a
    /// model weighs its instructions most, so the publisher's own sense text may travel as prompt
    /// data and must never arrive as an instruction. A guard written against the flattened string
    /// forbade a byte sequence the assembly cannot produce, and so could not fail.
    static let heardInstructions = Recorder<[UUID: [String]]>([:])
    /// The response budget each request carried.
    static let budgets = Recorder<[UUID: [Int?]]>([:])
    /// The sampling temperature each request carried. **Recorded because it is load-bearing**: a
    /// sense answer is a choice from a list and must be deterministic, and nothing else in the
    /// suite would notice it drifting back to the backend's default.
    static let temperatures = Recorder<[UUID: [Double?]]>([:])
    /// Generations running now, and the most there ever were at once — **kept per model**, not as
    /// one shared pair. These tests run in parallel, so a shared count is whatever every other test
    /// happened to be doing, and the reset that made it usable only worked while exactly one test
    /// answered slowly.
    static let running = Recorder<[UUID: (now: Int, most: Int)]>([:])
    /// The models whose one wedged request has already been taken.
    static let wedged = Recorder<Set<UUID>>([])

    init(_ behaviour: Behaviour) {
        id = UUID()
        Self.scripts.withLock { $0[id] = behaviour }
    }

    var requests: [String] { Self.heard.withLock { $0[id] ?? [] } }
    var instructions: [String] { Self.heardInstructions.withLock { $0[id] ?? [] } }
    var budgets: [Int?] { Self.budgets.withLock { $0[id] ?? [] } }
    var temperatures: [Double?] { Self.temperatures.withLock { $0[id] ?? [] } }
    /// The most generations this model ever ran at once.
    var mostAtOnce: Int { Self.running.withLock { $0[id]?.most ?? 0 } }
}

struct ScriptedExecutor: LanguageModelExecutor {
    typealias Model = ScriptedModel
    let id: UUID

    init(configuration: UUID) throws { id = configuration }

    func respond(
        to request: LanguageModelExecutorGenerationRequest, model: ScriptedModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        ScriptedModel.heard.withLock { $0[id, default: []].append(Self.text(of: request.transcript, .both)) }
        ScriptedModel.heardInstructions.withLock {
            $0[id, default: []].append(Self.text(of: request.transcript, .instructions))
        }
        ScriptedModel.budgets.withLock { $0[id, default: []].append(request.generationOptions.maximumResponseTokens) }
        ScriptedModel.temperatures.withLock { $0[id, default: []].append(request.generationOptions.temperature) }
        switch ScriptedModel.scripts.withLock({ $0[id] }) {
        case .answer(let text)?:
            await channel.send(.response(action: .appendText(text, tokenCount: 1)))
        case .answerSlowly(let text)?:
            ScriptedModel.running.withLock {
                var counts = $0[id] ?? (now: 0, most: 0)
                counts.now += 1
                counts.most = max(counts.most, counts.now)
                $0[id] = counts
            }
            try? await Task.sleep(for: .milliseconds(100))
            ScriptedModel.running.withLock {
                if var counts = $0[id] { counts.now -= 1; $0[id] = counts }
            }
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

    /// Which role of a transcript to read back. A request's instructions and its prompt are
    /// different claims about the same words, so a test has to be able to ask for one of them.
    enum Part { case instructions, prompt, both }

    /// Every text segment of the entries `part` names.
    static func text(of transcript: Transcript, _ part: Part) -> String {
        transcript.compactMap { entry -> String? in
            let segments: [Transcript.Segment]
            switch entry {
            case .instructions(let instructions) where part != .prompt: segments = instructions.segments
            case .prompt(let prompt) where part != .instructions: segments = prompt.segments
            default: return nil
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

    /// The tiny model the tests install for one size: the real one's repository and commit, with
    /// files seven bytes long. **Taken by size**, because a store holding one size cannot tell a
    /// service that picks the largest that fits from one that picks whatever is there.
    private static func manifest(_ size: LocalModelSize = .standard) -> ModelManifest {
        let body = Data("weights".utf8)
        let sha = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let real = size.manifest
        return ModelManifest(
            size: size, repository: real.repository, revision: real.revision,
            files: real.files.map {
                ModelFile(repository: $0.repository, revision: $0.revision, path: $0.path, size: Int64(body.count), sha256: sha)
            })
    }

    /// A store holding each of `sizes` whole, as the downloader would leave them — **in a directory
    /// that removes itself**, returned alongside so the test holds its lifetime.
    private static func installedStore(
        _ sizes: [LocalModelSize] = [.standard]
    ) throws -> (ModelStore, TemporaryDirectory) {
        let scratch = TemporaryDirectory(named: "xiaolaidict-service")
        let store = ModelStore(root: scratch.url)
        let body = Data("weights".utf8)
        for size in sizes {
            let manifest = Self.manifest(size)
            let directory = store.directory(for: manifest)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in manifest.files { try body.write(to: directory.appending(path: file.path)) }
            try ModelStore.markerText(for: manifest).write(
                to: directory.appending(path: ModelStore.completionMarker), atomically: true, encoding: .utf8)
        }
        return (store, scratch)
    }

    /// Waits for something to become true, **bounded by a count of looks rather than by the clock**:
    /// these tests run in parallel, so an elapsed-time bound measures how busy the runner is. The
    /// caller asserts the condition straight afterwards, so a wait that ran out fails by name
    /// instead of going quietly on to measure nothing.
    private static func waitUntil(_ condition: @Sendable () -> Bool) async {
        for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// The scratch directories these tests made, held for the life of the test instance so they are
    /// removed when it ends — 2,291 had been left behind under the system's temporary directory.
    private let scratches = Recorder<[TemporaryDirectory]>([])

    private func service(
        _ model: ScriptedModel, store: ModelStore? = nil, available: UInt64 = 40 * gigabyte,
        built: Recorder<Int> = Recorder(0), chose: Recorder<[LocalModelSize]> = Recorder([]),
        manifests: [ModelManifest] = [ModelServiceTests.manifest(.standard)],
        prewarmWait: Duration = .seconds(45)
    ) throws -> ModelService {
        let store = try store ?? {
            let (made, scratch) = try Self.installedStore()
            scratches.withLock { $0.append(scratch) }
            return made
        }()
        return ModelService(
            store: store, manifests: manifests, physicalMemory: 48 * Self.gigabyte,
            availableMemory: { available },
            makeModel: { _, size in
                built.withLock { $0 += 1 }
                chose.withLock { $0.append(size) }
                return model
            }, prewarmWait: prewarmWait)
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
        // The whole list, written out rather than re-derived from `ModelPrompt.sense` — a check that
        // asks the assembler what it should have assembled agrees with it whatever it does. One
        // candidate is not "every sense, numbered": it says nothing about the sense the model would
        // have had to choose *between*, nor about where the numbering starts.
        #expect(asked.contains("""
            Senses:
            1. an act of grasping
            2. a large space in the lower part of a ship
            Which number?
            """))
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
        // **As prompt data, not as instructions**: what a dictionary wrote must not be read as one.
        // Asked of the instructions alone, because the flattened request cannot answer it — the
        // guard that lived here forbade a byte sequence the assembly never produces, and so could
        // not fail however the two roles were mixed.
        #expect(model.instructions == [ModelPrompt.translationInstructions(for: question)])
        #expect(!model.instructions.contains { $0.contains("a large space in the lower part of a ship") },
                "the publisher's sense text was sent as an instruction")
        #expect(asked.contains("The ship's hold was full."))
    }

    /// An echo is not a translation, however confidently it arrives — **and the weights are loaded
    /// all the same.** Something came back from them; tying `loaded` to a *successful* reply had
    /// status report an empty service while it held gigabytes.
    @Test func anEchoIsAFailureNotATranslation() async throws {
        let model = ScriptedModel(.answer("The ship's hold was full."))
        let service = try service(model)
        let reply = await service.reply(
            to: .translate(TranslationQuestion(sentence: "The ship's hold was full.", target: "zh-Hans")))
        guard case .failure(.generationFailed) = reply else {
            Issue.record("an echo came back as \(reply)")
            return
        }
        guard case .status(let status) = await service.reply(to: .status) else { Issue.record("no status"); return }
        #expect(status.loaded, "an answer the service refused still loaded the weights")
    }

    /// A refusal is its own answer — never "no model here". **And the model loaded to give it**: a
    /// refusal is the model answering, so status must not report an empty service after one.
    @Test func aRefusalIsReportedAsARefusal() async throws {
        let service = try service(ScriptedModel(.refuse))
        let reply = await service.reply(to: .pickSense(Self.question))
        #expect(reply == .failure(.refused))
        guard case .status(let status) = await service.reply(to: .status) else { Issue.record("no status"); return }
        #expect(status.loaded, "an answer the service refused still loaded the weights")
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

    /// **Which size, with more than one to choose from.** The largest that fits is the one built,
    /// and the *smallest* is the figure an insufficient reply is measured against. With a single
    /// size installed neither could be wrong: a `max` and a `min` over one entry both answer it,
    /// so the two rules were untested for as long as the fixture held only 4B.
    @Test func theSizeChosenIsTheLargestThatFitsAndTheSmallestIsWhatIsMissed() async throws {
        let (store, scratch) = try Self.installedStore([.small, .standard])
        scratches.withLock { $0.append(scratch) }
        let both = [Self.manifest(.small), Self.manifest(.standard)]

        let roomy = Recorder<[LocalModelSize]>([])
        let plenty = try service(
            ScriptedModel(.answer(#"{"senseNumber": 1}"#)), store: store, available: 40 * Self.gigabyte,
            chose: roomy, manifests: both)
        #expect(await plenty.reply(to: .pickSense(Self.question)) == .sense(1))
        #expect(roomy.withLock { $0 } == [.standard], "a Mac with room for 4B was given 2B")

        // 4 GB holds 2B and its headroom (3,122 MB) and not 4B's (4,609 MB).
        let tight = Recorder<[LocalModelSize]>([])
        let little = try service(
            ScriptedModel(.answer(#"{"senseNumber": 1}"#)), store: store, available: 4 * Self.gigabyte,
            chose: tight, manifests: both)
        #expect(await little.reply(to: .pickSense(Self.question)) == .sense(1))
        #expect(tight.withLock { $0 } == [.small], "a size that does not fit in what is free was built")

        // Where neither fits, the reader is told what the *smallest* one needed — quoting 4B's
        // figure would tell a 2B-sized Mac it needs a gigabyte and a half more than it does.
        let none = try service(
            ScriptedModel(.answer(#"{"senseNumber": 1}"#)), store: store, available: Self.gigabyte,
            manifests: both)
        #expect(await none.reply(to: .pickSense(Self.question)) == .failure(.insufficientMemory(
            needed: LocalModelSize.small.peakMemory + ModelSizing.headroom, available: Self.gigabyte)))
    }

    /// Unknown free memory is not plenty.
    @Test func unknownFreeMemoryLoadsNothing() async throws {
        let built = Recorder(0)
        let service = ModelService(
            store: try { let (made, scratch) = try Self.installedStore()
                         scratches.withLock { $0.append(scratch) }
                         return made }(),
            manifests: [Self.manifest(.standard)], physicalMemory: 48 * Self.gigabyte,
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
    ///
    /// **The second has to arrive while the first is still generating**, or this is
    /// `prewarmingTwiceAsksTheModelOnce` again under another name — an answer that returns without
    /// pausing is finished before the second request is made. The first is therefore slow, and the
    /// test waits until its request is recorded, which the executor does before it pauses.
    @Test func concurrentPrewarmsAskTheModelOnce() async throws {
        let model = ScriptedModel(.answerSlowly(#"{"senseNumber": 1}"#))
        let service = try service(model)
        let first = Task { await service.reply(to: .prewarm) }
        await Self.waitUntil { !model.requests.isEmpty }
        #expect(!model.requests.isEmpty, "the prewarm's generation never started")
        let second = await service.reply(to: .prewarm)
        #expect(await first.value == .prewarmed)
        #expect(second == .prewarmed)
        #expect(model.requests.count == 1)
    }

    /// A question arriving while a prewarm runs waits for it instead of generating beside it — the
    /// prewarm is loading the weights and compiling the grammar that question needs.
    @Test func aQuestionWaitsForAPrewarmAlreadyRunning() async throws {
        let model = ScriptedModel(.answerSlowly(#"{"senseNumber": 2}"#))
        let service = try service(model)
        async let warming = service.reply(to: .prewarm)
        // Not a fixed pause: under parallel load either ordering can invert, and the question would
        // then be the one the prewarm waits behind — the opposite of what this test is about. The
        // executor records its request before it pauses, so this says the prewarm is generating.
        await Self.waitUntil { !model.requests.isEmpty }
        #expect(!model.requests.isEmpty, "the prewarm's generation never started")
        async let answer = service.reply(to: .pickSense(Self.question))
        #expect(await warming == .prewarmed)
        #expect(await answer == .sense(2))
        #expect(model.mostAtOnce == 1, "two generations ran at once")
    }

    /// …but **not for ever**. A prewarm that never comes back would otherwise hold every later
    /// question behind it for as long as the process lives. Bounded against the wedge itself rather
    /// than against the clock: the answer arrives while the prewarm is still hanging.
    @Test func aQuestionDoesNotWaitForeverOnAPrewarmThatNeverFinishes() async throws {
        let model = ScriptedModel(.wedgeOnce(#"{"senseNumber": 2}"#))
        let service = try service(model, prewarmWait: .milliseconds(50))
        let finished = Recorder(false)
        let prewarm = Task { _ = await service.reply(to: .prewarm); finished.withLock { $0 = true } }
        // The wedge is taken by whichever generation runs first, so the question must not be asked
        // until the prewarm's has it. A fixed pause only usually arranges that.
        await Self.waitUntil { !model.requests.isEmpty }
        #expect(!model.requests.isEmpty, "the prewarm's generation never started")
        #expect(await service.reply(to: .pickSense(Self.question)) == .sense(2))
        #expect(finished.withLock { $0 } == false, "the question waited for the wedged prewarm")
        prewarm.cancel()
    }

    /// A reader who closes the panel takes their question with them. Waiting on a task's value
    /// cannot be given up on, so the wait watches for cancellation itself — **and the withdrawal is
    /// checked again after the wait**, because the wait also returns when the caller gives up, and
    /// the generation then started anyway: weights loaded and the GPU spent for an answer nobody
    /// was waiting for. That is what the reply and the request count below are for; "the question
    /// did not outlive the prewarm" is true whether or not it quietly generated.
    @Test func aQuestionGivesUpOnAPrewarmWhenItsCallerDoes() async throws {
        let model = ScriptedModel(.wedgeOnce(#"{"senseNumber": 2}"#))
        let service = try service(model)
        let finished = Recorder(false)
        let prewarm = Task { _ = await service.reply(to: .prewarm); finished.withLock { $0 = true } }
        await Self.waitUntil { !model.requests.isEmpty }
        #expect(!model.requests.isEmpty, "the prewarm's generation never started")
        // The question generates nothing while it waits, so there is nothing of it to watch from
        // outside. The task says for itself that it has begun, which is the earliest moment at
        // which cancelling it means anything.
        let asking = Recorder(false)
        let question = Task { () -> ModelReply in
            asking.withLock { $0 = true }
            return await service.reply(to: .pickSense(Self.question))
        }
        await Self.waitUntil { asking.withLock { $0 } }
        #expect(asking.withLock { $0 }, "the question's task never started")
        question.cancel()
        let reply = await question.value
        guard case .failure(.generationFailed) = reply else {
            Issue.record("a withdrawn question came back as \(reply)")
            return
        }
        #expect(model.requests.count == 1, "a withdrawn question started a generation")
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

    /// **The sentence handed back is not an explanation of it**, any more than it is a translation
    /// of it — the same failure that reads as success, and the same check. Fed back re-cased and in
    /// quotation marks, so it is neither empty nor the sentence byte for byte: only the check that
    /// normalises case, spacing and quotes refuses it.
    @Test func anExplanationThatEchoesTheSentenceIsAFailure() async throws {
        let service = try service(ScriptedModel(.answer(#""the SHIP'S  hold was FULL.""#)))
        let question = SentenceQuestion(sentence: "The ship's hold was full.", term: "hold", senseText: nil)
        let reply = await service.reply(to: .explain(question))
        guard case .failure(.generationFailed) = reply else {
            Issue.record("the sentence was handed back as an explanation of itself, as \(reply)")
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
        // The mirror of the echo and the refusal: nothing came back from the weights, so nothing
        // claims they are there. A throw may have come from the load itself.
        guard case .status(let status) = await service.reply(to: .status) else { Issue.record("no status"); return }
        #expect(!status.loaded, "a generation that never came back was counted as loaded")
        guard case .failure = await service.reply(to: .prewarm) else {
            Issue.record("a prewarm over a failing model reported success")
            return
        }
        // Not kept: asked again, the model is asked again.
        _ = await service.reply(to: .prewarm)
        #expect(model.requests.count >= 3, "a failed prewarm was remembered instead of retried")
    }

    /// A list longer than the answer can name is refused before a model is woken for it. **The
    /// boundary is derived, not typed**: a hard-coded 100 stops being one past the bound the moment
    /// `maximumSenses` moves, and the refusal would then be measured somewhere it does not happen.
    @Test func moreSensesThanTheAnswerCanNameAreRefused() async throws {
        let built = Recorder(0)
        let service = try service(ScriptedModel(.answer(#"{"senseNumber": 1}"#)), built: built)
        let tooMany = ModelPrompt.maximumSenses + 1
        let long = SenseQuestion(
            sentence: "A sentence.", partOfSpeech: nil, senses: (1...tooMany).map { "sense \($0)" })
        guard case .failure(.invalidRequest) = await service.reply(to: .pickSense(long)) else {
            Issue.record("a list of \(tooMany) senses was asked")
            return
        }
        #expect(built.withLock { $0 } == 0)
    }

    /// …and a list of exactly that many **is** asked. The other half of the same boundary: with only
    /// the refusal checked, narrowing the guard from `<=` to `<` would quietly refuse the longest
    /// legal list, and every test here would still pass.
    @Test func aListAsLongAsTheAnswerCanNameIsAsked() async throws {
        let model = ScriptedModel(.answer(#"{"senseNumber": 1}"#))
        let service = try service(model)
        let full = SenseQuestion(
            sentence: "A sentence.", partOfSpeech: nil,
            senses: (1...ModelPrompt.maximumSenses).map { "sense \($0)" })
        #expect(await service.reply(to: .pickSense(full)) == .sense(1))
        #expect(model.requests.count == 1, "the longest legal list never reached the model")
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

    /// **And a long sentence is budgeted to the cap, not to itself.** The cap is the whole point of
    /// the budget: it is what a generation that stopped making sense costs the reader. Both numbers
    /// are written out rather than asked of `ModelPrompt` — a check that asks the helper what it
    /// should have answered agrees with it however the caps are taken away, which is why the
    /// budget assertions above cannot see one go.
    @Test func aLongSentenceIsBudgetedToTheCapAndNoFurther() async throws {
        // 2,520 characters: past the 480 at which a translation reaches its cap, and past the 384 at
        // which an explanation reaches its.
        let sentence = String(repeating: "The ship's hold was full of grain. ", count: 72)

        // Answering in Chinese rather than echoing, because an echo is refused before the budget is
        // read back — the test would then be measuring a request that was never made.
        let translator = ScriptedModel(.answer("这艘船的货舱装满了谷物。"))
        _ = try await service(translator).reply(to: .translate(
            TranslationQuestion(sentence: sentence, target: "zh-Hans")))
        let translationBudget = try #require(translator.budgets.first ?? nil)
        #expect(translationBudget == 1_024)

        let explainer = ScriptedModel(.answer("Here it names the cargo space of a ship."))
        _ = try await service(explainer).reply(to: .explain(
            SentenceQuestion(sentence: sentence, term: "hold")))
        let explanationBudget = try #require(explainer.budgets.first ?? nil)
        #expect(explanationBudget == 512)
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

    /// **Every field each guard requires, one row per field.** The three guards are compound — a
    /// sentence *and* a term, a sentence *and* senses, a sentence *and* a target — and the tests
    /// above blank only the sentence, so half of each guard could be deleted with nothing failing.
    /// The blanked field is the only thing wrong with each of these, and the model must not be
    /// built for any of them: a question missing what it needs is refused before any weights load.
    @Test(arguments: [
        ModelRequest.explain(SentenceQuestion(sentence: "The ship's hold was full.", term: "  ", senseText: nil)),
        .pickSense(SenseQuestion(sentence: "The ship's hold was full.", partOfSpeech: nil, senses: [])),
        .translate(TranslationQuestion(sentence: "  ", target: "zh-Hans")),
        .translate(TranslationQuestion(sentence: "The ship's hold was full.", target: " ")),
    ])
    func aRequestMissingAnyFieldItNeedsIsRefusedBeforeLoading(_ request: ModelRequest) async throws {
        let built = Recorder(0)
        let service = try service(ScriptedModel(.answer("x")), built: built)
        guard case .failure(.invalidRequest) = await service.reply(to: request) else {
            Issue.record("\(request) reached the model")
            return
        }
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
