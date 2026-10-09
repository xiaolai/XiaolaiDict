import Foundation
@testable import LLMProviders
import ModelKit
import Synchronization
import Testing

/// **A provider asked what the ladders ask** — what it is sent for each tier and origin, how its answer is read, and
/// what its failures become. The provider here is in-process and records every request it is handed, so each test
/// asserts what reached it and not only what came back.
struct ProviderClientTests {
    static let sense = SenseQuestion(
        sentence: "She banked the fire before going to bed.", partOfSpeech: "verb",
        senses: ["build up (a fire) with tightly packed fuel so that it burns slowly",
                 "deposit (money or valuables) in a bank"])
    static let explanation = SentenceQuestion(
        sentence: "She banked the fire before going to bed.", term: "banked",
        senseText: "heap (a fire) with tightly packed fuel so that it burns slowly")
    static let translation = TranslationQuestion(
        sentence: "She banked the fire before going to bed.", target: "zh-Hans",
        met: .init(term: "banked", sense: "heap (a fire) with tightly packed fuel so that it burns slowly"))

    static func client(_ provider: RecordingProvider, _ tier: ProviderTier, flipped: Bool = false,
                       deadline: Duration? = nil) -> ProviderClient {
        ProviderClient(provider: provider, tier: tier, dictionaryTextMayLeave: flipped,
                       deadline: { deadline ?? ModelDeadline.of($0) })
    }

    // MARK: - The sense question: on this Mac always, remote only on a tap and only once the text may leave

    /// **On this Mac, a sense question is asked whatever asked it**, with the instructions and the prompt the local
    /// model is given, at temperature 0 — so the measured prompts carry over.
    @Test(arguments: [QuestionOrigin.lookup, .reader])
    func onThisMacTheSenseQuestionIsAskedAsTheLocalModelIsAskedIt(origin: QuestionOrigin) async throws {
        let provider = RecordingProvider { _ in "2" }
        let reply = await Self.client(provider, .onThisMac).ask(.pickSense(Self.sense), origin: origin)
        #expect(reply == .sense(2))
        let sent = try #require(provider.requests.first)
        #expect(sent.instructions == ModelPrompt.senseInstructions)
        #expect(sent.prompt == ModelPrompt.sense(Self.sense))
        #expect(sent.temperature == 0)
        #expect(provider.requests.count == 1)
    }

    /// **A remote source is never asked to pick a sense while the dictionary's text may not leave** — not for a
    /// lookup, and not for a tap either: the question *is* the publisher's text.
    @Test(arguments: [QuestionOrigin.lookup, .reader])
    func aRemoteSourceIsNotAskedToPickASense(origin: QuestionOrigin) async {
        let provider = RecordingProvider { _ in "2" }
        let reply = await Self.client(provider, .remote).ask(.pickSense(Self.sense), origin: origin)
        #expect(reply == nil)
        #expect(provider.requests.isEmpty, "a remote source was sent a sense list")
    }

    /// **The flip lets a tap ask it, and still not a lookup** (plan §6): a lookup fires a sense question every time,
    /// and a subscription's limit is shared with every other app the reader uses it in. The control is the tap, which
    /// the flip does let through — so the refusal is the origin's, not the flip failing.
    @Test func onceTheTextMayLeaveARemoteSenseQuestionFollowsTheReadersTapAndNeverALookup() async {
        let provider = RecordingProvider { _ in "1" }
        let client = Self.client(provider, .remote, flipped: true)
        #expect(await client.ask(.pickSense(Self.sense), origin: .lookup) == nil)
        #expect(provider.requests.isEmpty, "a lookup spent the reader's subscription on a sense question")
        #expect(await client.ask(.pickSense(Self.sense), origin: .reader) == .sense(1))
        #expect(provider.requests.count == 1)
    }

    /// **The rule itself, every arm** — read off the plan, before the send-time assertion, which would otherwise hide a
    /// rule that let a remote sense question through behind its own refusal.
    @Test func theSenseQuestionsRuleEveryArm() {
        func asked(_ tier: ProviderTier, _ origin: QuestionOrigin, flipped: Bool) -> Bool {
            if case .ask = ProviderClient.plan(.pickSense(Self.sense), tier: tier, origin: origin,
                                               dictionaryTextMayLeave: flipped) { return true }
            return false
        }
        #expect(asked(.onThisMac, .lookup, flipped: false) && asked(.onThisMac, .reader, flipped: false))
        #expect(!asked(.remote, .lookup, flipped: false) && !asked(.remote, .reader, flipped: false))
        #expect(!asked(.remote, .lookup, flipped: true), "a lookup asked a remote source once the text may leave")
        #expect(asked(.remote, .reader, flipped: true))
    }

    /// **Only a sense question takes an answer cut off at its budget**: its number comes first, while a translation's
    /// or an explanation's end is part of what it says.
    @Test func onlyASenseQuestionTakesAnAnswerCutOffAtItsBudget() {
        func usableWhenCut(_ request: ModelRequest) -> Bool? {
            guard case .ask(let generation, _) = ProviderClient.plan(request, tier: .onThisMac, origin: .reader,
                                                                     dictionaryTextMayLeave: false) else { return nil }
            return generation.usableWhenCut
        }
        #expect(usableWhenCut(.pickSense(Self.sense)) == true)
        #expect(usableWhenCut(.translate(Self.translation)) == false)
        #expect(usableWhenCut(.explain(Self.explanation)) == false)
    }

    // MARK: - Translation and explanation: the remote tier is sent the reader's sentence only

    @Test func aRemoteTranslationIsToldNoSense() async throws {
        let provider = RecordingProvider { _ in "她睡前把炉火封好了。" }
        let reply = await Self.client(provider, .remote).ask(.translate(Self.translation), origin: .reader)
        #expect(reply == .translation("她睡前把炉火封好了。"))
        let sent = try #require(provider.requests.first)
        let bare = TranslationQuestion(sentence: Self.translation.sentence, target: Self.translation.target)
        #expect(sent.prompt == ModelPrompt.translation(bare))
        #expect(sent.instructions == ModelPrompt.translationInstructions(for: bare))
        #expect(sent.maxTokens == ModelPrompt.translationTokens(for: bare))
        #expect(!sent.prompt.contains("tightly packed"), "the sense reached a remote translation")
    }

    /// The control: on this Mac the translation is told the sense, which is what sharpened 船舱 to 货舱.
    @Test func aTranslationOnThisMacIsToldTheSense() async throws {
        let provider = RecordingProvider { _ in "她睡前把炉火封好了。" }
        _ = await Self.client(provider, .onThisMac).ask(.translate(Self.translation), origin: .reader)
        let sent = try #require(provider.requests.first)
        #expect(sent.prompt == ModelPrompt.translation(Self.translation))
        #expect(sent.prompt.contains("tightly packed"))
    }

    @Test func aRemoteExplanationIsGivenTheRemotePrompt() async throws {
        let provider = RecordingProvider { _ in "It means she covered the fire so it would burn slowly." }
        let reply = await Self.client(provider, .remote).ask(.explain(Self.explanation), origin: .reader)
        #expect(reply == .explanation("It means she covered the fire so it would burn slowly."))
        let sent = try #require(provider.requests.first)
        #expect(sent.prompt == Self.explanation.prompt(for: .remote))
        #expect(sent.instructions == ModelPrompt.explanationInstructions)
        #expect(sent.maxTokens == ModelPrompt.explanationTokens(for: Self.explanation))
        #expect(!Self.explanation.leaksDictionaryText(sent.prompt))
    }

    @Test func anExplanationOnThisMacIsGivenTheSense() async throws {
        let provider = RecordingProvider { _ in "It means she covered the fire so it would burn slowly." }
        _ = await Self.client(provider, .onThisMac).ask(.explain(Self.explanation), origin: .reader)
        let sent = try #require(provider.requests.first)
        #expect(sent.prompt == Self.explanation.prompt(for: .onDevice))
    }

    /// The flip's other half: once the text may leave, a remote translation and explanation are told the sense too —
    /// the whole of what flipping the constant changes besides the tapped sense question.
    @Test func onceTheTextMayLeaveTheRemoteTierIsToldTheSense() async throws {
        let provider = RecordingProvider { _ in "她睡前把炉火封好了。" }
        let client = Self.client(provider, .remote, flipped: true)
        _ = await client.ask(.translate(Self.translation), origin: .reader)
        _ = await client.ask(.explain(Self.explanation), origin: .reader)
        let sent = provider.requests
        #expect(sent.count == 2)
        #expect(sent.first?.prompt == ModelPrompt.translation(Self.translation))
        #expect(sent.last?.prompt == Self.explanation.prompt(for: .onDevice))
    }

    // MARK: - The send-time assertion

    /// **Whatever was built, a request for a remote tier that carries the publisher's text is not sent.** The builder
    /// here is wrong on purpose — it puts the sense in the remote explanation prompt — because that is the only way to
    /// reach the assertion, and the one defect it exists for. The control: the same wrong builder on this Mac sends,
    /// so the refusal is the tier's.
    @Test func aRemoteRequestCarryingTheSenseIsNotSent() async {
        let leaky: @Sendable (ModelRequest, ProviderTier, QuestionOrigin, Bool) -> ProviderClient.Plan = { request, _, _, _ in
            guard case .explain(let question) = request else { return .notAsked }
            return .ask(GenerationRequest(instructions: ModelPrompt.explanationInstructions,
                                          prompt: question.prompt(for: .onDevice), maxTokens: 64, temperature: 1),
                        .explanation(sentence: question.sentence))
        }
        let remote = RecordingProvider { _ in "an explanation" }
        let refused = ProviderClient(provider: remote, tier: .remote, dictionaryTextMayLeave: false, plan: leaky)
        #expect(await refused.ask(.explain(Self.explanation), origin: .reader) == nil)
        #expect(remote.requests.isEmpty, "a request carrying the publisher's text was handed to a remote source")

        let local = RecordingProvider { _ in "an explanation" }
        let sent = ProviderClient(provider: local, tier: .onThisMac, dictionaryTextMayLeave: false, plan: leaky)
        #expect(await sent.ask(.explain(Self.explanation), origin: .reader) == .explanation("an explanation"))
        #expect(local.requests.count == 1)
    }

    // MARK: - Reading the answer

    @Test(arguments: [("1", 1), ("0", 0), ("2. The second one, about money.", 2), ("Sense 1", 1)])
    func aSenseAnswerIsReadAsTheMeasurementReadIt(answer: String, number: Int) async {
        let provider = RecordingProvider { _ in answer }
        #expect(await Self.client(provider, .onThisMac).ask(.pickSense(Self.sense), origin: .lookup) == .sense(number))
    }

    /// A number past the list, or none at all, is not a sense — a failure the rung falls through on, never a position.
    @Test(arguments: ["7", "neither of these", ""])
    func anAnswerThatNamesNoSenseIsAFailure(answer: String) async {
        let provider = RecordingProvider { _ in answer }
        let reply = await Self.client(provider, .onThisMac).ask(.pickSense(Self.sense), origin: .lookup)
        guard case .failure(.generationFailed)? = reply else {
            Issue.record("\(answer.debugDescription) read as \(String(describing: reply))")
            return
        }
    }

    /// **The sentence handed back is not a translation of it, nor an explanation** — the failure that reads as
    /// success, refused here as the model service refuses it.
    @Test func anEchoIsNotATranslationOrAnExplanation() async {
        let provider = RecordingProvider { _ in "She banked the fire before going to bed." }
        let client = Self.client(provider, .remote)
        guard case .failure(.generationFailed)? = await client.ask(.translate(Self.translation), origin: .reader),
              case .failure(.generationFailed)? = await client.ask(.explain(Self.explanation), origin: .reader)
        else {
            Issue.record("an echo was read as an answer")
            return
        }
    }

    // MARK: - Failures

    /// Every failure is one the ladders already read, and only a refusal keeps its meaning.
    @Test(arguments: [ProviderFailure.refused, .unauthorised, .rateLimited, .unreachable, .modelNotFound])
    func aFailureIsTheModelFailureTheLaddersRead(failure: ProviderFailure) async {
        let provider = RecordingProvider { _ in throw failure }
        let reply = await Self.client(provider, .remote).ask(.explain(Self.explanation), origin: .reader)
        #expect(reply == .failure(ProviderFailure.modelFailure(for: failure)))
    }

    /// A caller that gave up is answered nil, as `ModelClient` answers it — not a failure of the source.
    @Test func aCancelledQuestionIsAnsweredNil() async {
        let provider = RecordingProvider { _ in throw ProviderFailure.cancelled }
        #expect(await Self.client(provider, .remote).ask(.explain(Self.explanation), origin: .reader) == nil)
    }

    /// **Every question has its deadline**: a provider that never answers is a timed-out generation, which falls
    /// through. Asserted by what it ends as, never by how long that took.
    @Test func aProviderThatNeverAnswersTimesOut() async {
        let provider = RecordingProvider { _ in
            try? await Task.sleep(for: .seconds(60))
            return "too late"
        }
        let reply = await Self.client(provider, .remote, deadline: .milliseconds(50))
            .ask(.explain(Self.explanation), origin: .reader)
        #expect(reply == .failure(ProviderFailure.modelFailure(for: .timedOut)))
    }

    /// **The table is the model service's own**: one deadline per kind of question, whichever source answers it.
    @Test func theDeadlinesAreTheModelServicesTable() {
        #expect(ModelDeadline.of(.pickSense(Self.sense)) == .seconds(12))
        #expect(ModelDeadline.of(.translate(Self.translation)) == .seconds(30))
        #expect(ModelDeadline.of(.explain(Self.explanation)) == .seconds(45))
    }

    /// What only the model service answers is a defect to route here, said as one.
    @Test(arguments: [ModelRequest.prewarm, .status, .unload])
    func aServiceRequestIsRefusedAsInvalid(request: ModelRequest) async {
        let provider = RecordingProvider { _ in "x" }
        guard case .failure(.invalidRequest)? = await Self.client(provider, .onThisMac).ask(request, origin: .reader)
        else {
            Issue.record("\(request) was not refused as invalid")
            return
        }
        #expect(provider.requests.isEmpty)
    }

    /// A question no model can be asked is refused before anything is sent, as the service refuses it.
    @Test func anEmptyQuestionIsRefusedAsInvalid() async {
        let provider = RecordingProvider { _ in "1" }
        let client = Self.client(provider, .onThisMac)
        let noSenses = SenseQuestion(sentence: "A sentence.", partOfSpeech: nil, senses: [])
        let tooMany = SenseQuestion(sentence: "A sentence.", partOfSpeech: nil,
                                    senses: Array(repeating: "a sense", count: ModelPrompt.maximumSenses + 1))
        for request in [ModelRequest.pickSense(noSenses), .pickSense(tooMany),
                        .explain(SentenceQuestion(sentence: " ", term: "x")),
                        .translate(TranslationQuestion(sentence: "A sentence.", target: ""))] {
            guard case .failure(.invalidRequest)? = await client.ask(request, origin: .reader) else {
                Issue.record("\(request) was not refused")
                continue
            }
        }
        #expect(provider.requests.isEmpty)
    }
}

/// **A provider in this process**: it answers each request with what `answer` makes of it, and keeps every request.
final class RecordingProvider: ProviderBackend {
    private let answer: @Sendable (GenerationRequest) async throws -> String
    private let state = Mutex<(requests: [GenerationRequest], shutDowns: Int, checks: Int)>(([], 0, 0))
    let warmsByAsking: Bool

    init(warmsByAsking: Bool = false, _ answer: @escaping @Sendable (GenerationRequest) async throws -> String) {
        self.answer = answer
        self.warmsByAsking = warmsByAsking
    }

    var requests: [GenerationRequest] { state.withLock { $0.requests } }
    var shutDowns: Int { state.withLock { $0.shutDowns } }
    var checks: Int { state.withLock { $0.checks } }

    func generate(_ request: GenerationRequest) async throws(ProviderFailure) -> String {
        state.withLock { $0.requests.append(request) }
        do {
            return try await answer(request)
        } catch let failure as ProviderFailure {
            throw failure
        } catch {
            throw .unreachable
        }
    }

    func readiness() async -> ProviderReadiness {
        state.withLock { $0.checks += 1 }
        return .endpointReady(answeredIn: .milliseconds(1))
    }

    func shutDown() async {
        state.withLock { $0.shutDowns += 1 }
    }
}
