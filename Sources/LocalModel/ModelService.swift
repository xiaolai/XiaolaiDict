import Foundation
import FoundationModels
import XiaolaiDictCore

/// What the model service does with a request, against any `LanguageModel`.
///
/// **The call site does not change with the model.** Inside the service, sense picking and
/// translation are `LanguageModelSession(model:)` with the app's own instructions and a `@Generable`
/// answer — the same call the on-device rung makes of Apple's model. The executable hands in an
/// `MLXLanguageModel`; the tests hand in a scripted one, so they need no GPU and no weights.
///
/// An actor, so one model is loaded once however many requests arrive together.
public actor ModelService {
    /// Builds the model for an installed directory. Called once, before the first answer.
    public typealias MakeModel = @Sendable (URL, LocalModelSize) -> any LanguageModel

    private let store: ModelStore
    /// The models the service may load — the ones the app knows, pinned. A test hands in its own.
    private let manifests: [ModelManifest]
    private let physicalMemory: UInt64
    private let availableMemory: @Sendable () -> UInt64?
    private let makeModel: MakeModel
    private let gpu: @Sendable () -> String?
    private let footprint: @Sendable () -> UInt64?

    private var model: (size: LocalModelSize, model: any LanguageModel)?
    /// Whether the model has answered anything — which is when its weights are actually in memory.
    /// Building the `LanguageModel` maps nothing; the first generation loads.
    private var hasAnswered = false
    /// The one prewarm, shared by everyone who asks while it runs. The actor is reentrant across
    /// awaits, so a flag set after the work would let two prewarms both start it.
    private var prewarming: Task<ModelReply, Never>?
    /// Whether that prewarm is still running. A question waits on **this**, not on the task's value:
    /// `await task.value` cannot be given up on — it ignores the waiter's cancellation and has no
    /// deadline — so waiting that way puts every later question behind a prewarm that never returns.
    private var prewarmInFlight = false
    /// What the GPU probe answered, kept so it is asked once — see `gpuName()`.
    private var probedGPU: String??
    /// How many generations are running now. **A count, not a flag**: the actor is reentrant across
    /// awaits, so two answers can be in flight, and the first to finish would clear a flag while the
    /// second was still using the GPU.
    private var generating = 0
    /// How long a question waits for a prewarm already running. Long enough for a cold load and a
    /// grammar compile — measured at 1.6–2.5 s on an M4 Max — and far short of the service watchdog.
    private let prewarmWait: Duration

    public init(
        store: ModelStore, manifests: [ModelManifest] = ModelManifest.all,
        physicalMemory: UInt64 = SystemMemory.physical,
        availableMemory: @escaping @Sendable () -> UInt64? = SystemMemory.available,
        makeModel: @escaping MakeModel,
        gpu: @escaping @Sendable () -> String? = { nil },
        footprint: @escaping @Sendable () -> UInt64? = SystemMemory.footprint,
        prewarmWait: Duration = .seconds(45)
    ) {
        self.store = store
        self.manifests = manifests
        self.physicalMemory = physicalMemory
        self.availableMemory = availableMemory
        self.makeModel = makeModel
        self.gpu = gpu
        self.footprint = footprint
        self.prewarmWait = prewarmWait
    }

    public func reply(to request: ModelRequest) async -> ModelReply {
        switch request {
        case .status: return status()
        // The executable ends the process after this reply is sent; nothing here to release.
        case .unload: return .unloading
        case .prewarm: return await prewarm()
        // A prewarm already running loads the weights and compiles the grammar this question needs:
        // waited for, so the two are not generated side by side on one model.
        // **Cancellation is checked after the wait as well as inside it.** `awaitPrewarm` returns
        // when the caller gives up — and then the generation started anyway, loading weights and
        // spending the GPU for an answer nobody was waiting for.
        case .pickSense(let question):
            await awaitPrewarm()
            guard !Task.isCancelled else { return .failure(.generationFailed("the question was withdrawn")) }
            return await pickSense(question)
        case .translate(let question):
            await awaitPrewarm()
            guard !Task.isCancelled else { return .failure(.generationFailed("the question was withdrawn")) }
            return await translate(question)
        case .explain(let question):
            await awaitPrewarm()
            guard !Task.isCancelled else { return .failure(.generationFailed("the question was withdrawn")) }
            return await explain(question)
        }
    }

    // MARK: - Requests

    /// Waits for a prewarm already running — it is loading the weights and compiling the grammar
    /// this question needs — but **never unconditionally**. Two ways out besides the prewarm
    /// finishing: the caller giving up, and `prewarmWait` passing. Past either, the question goes
    /// ahead; the model is loaded once whoever asks, so the worst case is waiting again inside it.
    private func awaitPrewarm() async {
        guard prewarmInFlight else { return }
        let deadline = ContinuousClock.now.advanced(by: prewarmWait)
        while prewarmInFlight, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.prewarmPoll)
        }
    }

    /// How often the wait above looks. Short against a cold load, and a question that arrives while
    /// one is running pays at most this much after it finishes.
    static let prewarmPoll = Duration.milliseconds(20)

    /// The size it holds, or the one it **would** load. Where a model is already loaded that is the
    /// answer; otherwise the same routine the loading asks, so status cannot advertise a size the
    /// service would then refuse for want of memory.
    /// **The GPU probe runs once and is remembered.** It evaluates an MLX op, and the actor is
    /// reentrant across awaits — so a `.status` arriving mid-generation would put a second piece of
    /// GPU work beside the model's own. Asked here at most once per process, before or between
    /// answers, and reused after.
    private func gpuName() -> String? {
        if let probedGPU { return probedGPU }
        // Never while the model is generating: that is the one time a second piece of GPU work
        // costs something. Status then answers with what it knows, which is nothing yet.
        guard generating == 0 else { return nil }
        let name = gpu()
        probedGPU = name
        return name
    }

    private func status() -> ModelReply {
        let available = availableMemory()
        return .status(ModelServiceStatus(
            installed: model?.size ?? fitting(available: available ?? 0)?.size,
            loaded: hasAnswered, gpu: gpuName(), footprint: footprint(), availableMemory: available))
    }

    /// Loads the weights and compiles the sense grammar with a real answer, once per process — the
    /// first answer measured 1.6–2.5 s cold against 0.24–0.44 s warm, and it is the one the reader
    /// would otherwise wait for.
    private func prewarm() async -> ModelReply {
        if let prewarming { return await prewarming.value }
        let work = Task { () -> ModelReply in
            let warmed = await pickSense(SenseQuestion(
                sentence: "The ship's hold was full.", partOfSpeech: "noun",
                senses: ["a grip", "the cargo space of a ship"]))
            if case .failure(let failure) = warmed { return .failure(failure) }
            return .prewarmed
        }
        prewarming = work
        prewarmInFlight = true
        let reply = await work.value
        prewarmInFlight = false
        // A failed prewarm is not kept: the next one tries again.
        if reply != .prewarmed { prewarming = nil }
        return reply
    }

    private func pickSense(_ question: SenseQuestion) async -> ModelReply {
        guard !question.senses.isEmpty, !question.sentence.isBlank else {
            return .failure(.invalidRequest("a sense question needs a sentence and senses"))
        }
        // The answer's schema cannot name a sense past its bound, so a longer list is refused before
        // a model is woken for it rather than having its tail made unreachable.
        guard question.senses.count <= SenseNumber.maximum else {
            return .failure(.invalidRequest("\(question.senses.count) senses; the answer can name at most \(SenseNumber.maximum)"))
        }
        return await withModel { model in
            let session = LanguageModelSession(model: model, instructions: ModelPrompt.senseInstructions)
            // **Temperature 0.** This is a classification over a closed set, not writing: sampling
            // adds nothing a reader wants and makes the same question answerable two ways. The
            // measurement depends on it — the report runs the rung and the ladder separately over
            // one sentence, and two sampled generations can disagree by chance, which would read as
            // the ladder dropping an answer it did not drop.
            let answer = try await session.respond(
                to: ModelPrompt.sense(question), generating: SenseNumber.self,
                options: GenerationOptions(temperature: 0))
            return .sense(answer.content.senseNumber)
        }
    }

    private func translate(_ question: TranslationQuestion) async -> ModelReply {
        guard !question.sentence.isBlank, !question.target.isBlank else {
            return .failure(.invalidRequest("a translation needs a sentence and a language"))
        }
        return await withModel { model in
            let session = LanguageModelSession(
                model: model, instructions: ModelPrompt.translationInstructions(for: question))
            let text = try await session.respond(
                to: ModelPrompt.translation(question),
                options: GenerationOptions(maximumResponseTokens: ModelPrompt.translationTokens(for: question)))
                .content.trimmingCharacters(in: .whitespacesAndNewlines)
            // An echo reads as success and is not one: 9B once handed its English back untranslated.
            // **Told the target too**, so an answer still in the source's language is caught here
            // rather than only at the pane — the report and the end-to-end gate read this reply.
            guard TranslationCheck.isTranslation(text, of: question.sentence, into: question.target) else {
                return .failure(.generationFailed("the model answered with the sentence it was given"))
            }
            return .translation(text)
        }
    }

    /// How the word is used in the reader's sentence, in prose.
    ///
    /// **Sampled, unlike the sense answer.** This is writing, not a choice from a list: at
    /// temperature 0 a small model repeats itself and falls into the same three clauses for every
    /// sentence. The bound is the token budget, not the grammar.
    private func explain(_ question: SentenceQuestion) async -> ModelReply {
        guard !question.sentence.isBlank, !question.term.isBlank else {
            return .failure(.invalidRequest("an explanation needs a sentence and a word"))
        }
        return await withModel { model in
            let session = LanguageModelSession(
                model: model, instructions: ModelPrompt.explanationInstructions)
            // The local model runs on this Mac, so it may see the dictionary's own text — the same
            // boundary `ExplainerTier` draws, asked for by name rather than assembled here.
            let text = try await session.respond(
                to: ModelPrompt.explanation(question),
                options: GenerationOptions(maximumResponseTokens: ModelPrompt.explanationTokens(for: question)))
                .content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .failure(.generationFailed("the model answered with nothing"))
            }
            // **The sentence handed back is not an explanation of it**, any more than it is a
            // translation of it — the same failure that reads as success, and the same check.
            guard TranslationCheck.isTranslation(text, of: question.sentence) else {
                return .failure(.generationFailed("the model answered with the sentence it was given"))
            }
            return .explanation(text)
        }
    }

    // MARK: - The model

    /// Runs `body` against the model, loading it first if need be. A refusal is the model declining;
    /// anything else it throws — a load that failed, a generation that did — is a failure of this
    /// answer, reported as one.
    private func withModel(_ body: (any LanguageModel) async throws -> ModelReply) async -> ModelReply {
        let model: any LanguageModel
        switch loaded() {
        case .failure(let failure): return .failure(failure)
        case .success(let loaded): model = loaded
        }
        generating += 1
        defer { generating -= 1 }
        do {
            let reply = try await body(model)
            // **The weights are loaded once anything has come back from them** — including an answer
            // this service then refused, like an echo. Tying `loaded` to a *successful* reply had
            // status report an empty service while it held gigabytes.
            hasAnswered = true
            return reply
        } catch {
            let refused = ModelRefusal.isRefusal(error)
            // A refusal is the model answering; it loaded to do it. Any other throw may have come
            // from the load itself, and claims nothing.
            if refused { hasAnswered = true }
            return .failure(refused ? .refused : .generationFailed("\(error)"))
        }
    }

    /// The largest installed size that may be loaded **now** — the one question both loading and
    /// status ask, so they cannot answer it differently. Unknown free memory is not plenty: a kernel
    /// that will not say how much is free gets no model.
    private func fitting(
        installed: [ModelManifest]? = nil, available: UInt64
    ) -> ModelManifest? {
        (installed ?? store.installedManifests(among: manifests))
            .filter { ModelSizing.mayLoad($0.size, physicalMemory: physicalMemory, availableMemory: available) }
            .max(by: { $0.size < $1.size })
    }

    /// The model, building it the first time — **after** deciding it fits. Sizing is asked before
    /// every first load and never after one: once loaded, the memory is already spent.
    private func loaded() -> Result<any LanguageModel, ModelFailure> {
        // **Only a model that has answered counts as loaded.** Building an `MLXLanguageModel` maps
        // nothing — the weights arrive inside the first generation — so a cached value whose first
        // generation was cancelled or failed would let every request after it skip the sizing gate
        // and load whenever, against whatever memory was free by then. The gate is asked again
        // until something has actually come back from the weights.
        if let model, hasAnswered { return .success(model.model) }
        // **One reading of each.** Asking twice let the answer be about a different state from the
        // reason given for it — "not enough memory" quoting a figure from another moment.
        let available = availableMemory() ?? 0
        let installed = store.installedManifests(among: manifests)
        guard let smallest = installed.map(\.size).min() else { return .failure(.notInstalled) }
        guard let chosen = fitting(installed: installed, available: available) else {
            return .failure(.insufficientMemory(
                needed: smallest.peakMemory + ModelSizing.headroom, available: available))
        }
        // Gone between the two looks — removed, or replaced by a switch of size. Not a memory problem.
        guard let directory = store.installed(chosen) else { return .failure(.notInstalled) }
        let built = makeModel(directory, chosen.size)
        model = (chosen.size, built)
        return .success(built)
    }
}

/// The sense answer's shape. A number, bounded so the grammar keeps it to two digits; whether it
/// is a position that exists is checked by the app, which holds the list.
///
/// **One schema for every question**, not one sized to each list: guided generation compiles a
/// grammar per schema, and the cold compile is the expensive part of a first answer. A bound the
/// size of the list would make every entry length a new compile.
@Generable
struct SenseNumber {
    /// The largest number the schema admits — and so the longest list a question may carry. The
    /// app's own rungs read it from `ModelPrompt`, which is where both sides can see it.
    static let maximum = ModelPrompt.maximumSenses

    @Guide(description: "The number of the sense the word carries in the sentence, or 0 if none clearly fits.",
           .range(0...SenseNumber.maximum))
    var senseNumber: Int
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
