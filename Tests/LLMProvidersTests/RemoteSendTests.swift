import Foundation
@testable import LLMProviders
import ModelKit
import Testing

/// **No sense text reaches a host that is not loopback** (plan §8, P1's bar) — asserted on the bytes the provider
/// put on the wire, not on the prompt someone meant to build.
///
/// P1 has no `ProviderClient` yet (P3 composes it), so the composition here is the rule's own: the endpoint's tier
/// from `RemoteDisclosure`, whether that tier may carry the dictionary's text, and the one place the text is dropped
/// (`SentenceQuestion.prompt(for:)`). The control is the same question to a loopback server on this Mac, whose body
/// does carry the sense — so the check can fail, and fails for the reason it exists.
struct RemoteSendTests {
    static let question = SentenceQuestion(
        sentence: "She banked the fire before going to bed.", term: "bank",
        senseText: "heap (a fire) with tightly packed fuel so that it burns slowly")

    /// The request `question` becomes for an endpoint at `base`, its prompt chosen by the tier `base` has.
    static func request(for base: URL) -> (tier: ProviderTier, request: GenerationRequest) {
        let tier = RemoteDisclosure.tier(ofEndpoint: base.absoluteString)
        let prompt = question.prompt(for: RemoteDisclosure.mayCarryDictionaryText(tier) ? .onDevice : .remote)
        return (tier, GenerationRequest(instructions: ModelPrompt.explanationInstructions, prompt: prompt,
                                        maxTokens: 64, temperature: 0))
    }

    @Test func aRemoteHostIsSentTheSentenceAndNeverTheSense() async throws {
        let endpoint = StubEndpoint(always: .completion("It means to pack the fire so it burns slowly."))
        let (tier, request) = Self.request(for: endpoint.baseURL)
        #expect(tier == .remote)
        let provider = OpenAICompatibleProvider(
            endpoint: endpoint.baseURL, model: "m", credentials: InMemoryCredentials(), timeout: .seconds(10),
            sessionConfiguration: StubEndpoint.configuration(), responseByteLimit: OpenAICompatibleProvider.responseByteLimit)
        _ = try await provider.generate(request)
        let body = String(decoding: try #require(endpoint.requests.first).body, as: UTF8.self)
        #expect(body.contains("She banked the fire before going to bed."), "the reader's sentence did not go")
        #expect(!Self.question.leaksDictionaryText(body), "the dictionary's sense text reached a remote host")
    }

    /// The control: 127.0.0.1 is on this Mac, and its body carries the sense — so the assertion above can fail.
    @Test func aLoopbackHostIsSentTheSenseToo() async throws {
        let server = try LoopbackHTTPServer { _ in .respond(.completion("ok")) }
        let base = server.url("/v1")
        let (tier, request) = Self.request(for: base)
        #expect(tier == .onThisMac)
        let provider = OpenAICompatibleProvider(endpoint: base, model: "m", credentials: InMemoryCredentials(),
                                                timeout: .seconds(10))
        _ = try await provider.generate(request)
        let body = String(decoding: try #require(server.requests.first).body, as: UTF8.self)
        #expect(Self.question.leaksDictionaryText(body), "a loopback endpoint was not sent the sense")
    }
}
