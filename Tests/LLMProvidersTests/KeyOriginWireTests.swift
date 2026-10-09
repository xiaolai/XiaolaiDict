import Foundation
@testable import LLMProviders
import ModelKit
import Testing
import XiaolaiDictTestSupport

/// **A key saved for one endpoint is never sent to another, however the endpoint's URL comes to change** (plan §10 P4).
///
/// The URL is a plain value in the app's defaults, and anything that can write them can point it somewhere else — not
/// the reader, not through Settings. Asserted through the path the app takes: the reader's settings read from a suite,
/// the router, the factory, the provider and the loading system — on a socket for another port of this Mac, and where
/// `URLSession` hands the request over for another host, which is HTTPS (plain HTTP off this Mac is sent nothing,
/// `RemoteSendTests`). The key is filed the way Settings files it, under `EndpointAddress.keyAccount` for the address
/// Settings shows.
///
/// Each test has its control on the same router: the origin the key was saved for **is** sent it, so the header's
/// absence afterwards is the binding and not a wire that never carries one.
struct KeyOriginWireTests {
    static let question = SentenceQuestion(sentence: "She banked the fire before going to bed.", term: "banked",
                                           senseText: nil)
    static let answer = "She covered the fire so that it would burn slowly through the night."

    /// A suite in which the reader chose an OpenAI-compatible endpoint at `url`, asking for a model.
    static func suite(endpoint url: String) -> UserDefaults {
        let suite = TemporaryDefaults.suite()
        ProviderChoiceStore(defaults: suite).save(.openAICompatible)
        ProviderSettingsStore(defaults: suite).save(ProviderSettings(endpointURL: url, endpointModel: "origin-model"))
        return suite
    }

    /// The key saved as Settings saves it: for the address the reader's settings name now.
    static func saveKey(_ key: String, in suite: UserDefaults, to credentials: InMemoryCredentials) throws {
        let address = try #require(EndpointAddress(ProviderSettingsStore(defaults: suite).load().endpointURL))
        try credentials.write(key, account: address.keyAccount)
    }

    /// The router the app builds over `suite`, reading keys from `credentials`, its endpoint session `session`.
    static func router(_ suite: UserDefaults, _ credentials: InMemoryCredentials,
                       session: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) -> ModelBackendRouter {
        let factory = ProviderFactory(
            locator: CLILocator(searchDirectories: [], loginShell: nil, shellTimeout: .seconds(1)),
            credentials: credentials, configuration: ResidentSessionTests.configuration(),
            endpointSession: session, scratch: { nil }, events: { _ in })
        return ModelBackendRouter(
            choices: ProviderChoiceStore(defaults: suite), settings: ProviderSettingsStore(defaults: suite),
            local: .init(ask: { _ in nil }, prewarm: {}), factory: factory)
    }

    static func server() throws -> LoopbackHTTPServer {
        try LoopbackHTTPServer { _ in .respond(.completion(answer)) }
    }

    /// **Another port of this Mac is another origin**: the key the reader saved for one local server is not sent to a
    /// second once the URL in the defaults is rewritten to it — and the first is asked nothing more.
    @Test func aURLRewrittenToAnotherPortSendsNoKeyThere() async throws {
        let saved = try Self.server(), rewritten = try Self.server()
        let suite = Self.suite(endpoint: saved.url("/v1").absoluteString)
        let credentials = InMemoryCredentials()
        try Self.saveKey("sk-SAVED-FOR-ONE-ORIGIN", in: suite, to: credentials)
        let router = Self.router(suite, credentials)

        // The control: the origin the key was saved for is sent it, on this router.
        #expect(await router.ask(.explain(Self.question), origin: .reader).reply == .explanation(Self.answer))
        #expect(try #require(saved.requests.first).headers["authorization"] == "Bearer sk-SAVED-FOR-ONE-ORIGIN")

        suite.set(rewritten.url("/v1").absoluteString, forKey: ProviderSettingsStore.Key.endpointURL)
        #expect(await router.ask(.explain(Self.question), origin: .reader).reply == .explanation(Self.answer))
        let request = try #require(rewritten.requests.first, "the rewritten endpoint was never asked")
        #expect(request.headers["authorization"] == nil, "the key saved for one origin was sent to another")
        #expect(!request.headers.values.contains { $0.contains("SAVED-FOR-ONE-ORIGIN") })
        #expect(!String(decoding: request.body, as: UTF8.self).contains("SAVED-FOR-ONE-ORIGIN"))
        #expect(saved.requests.count == 1, "the origin the reader left was asked again")
        await router.shutDown()
    }

    /// **And another host is another origin** — the case the binding is for: a URL rewritten to a host off this Mac.
    /// Both hosts are `StubEndpoint`s of their own, read where `URLSession` hands the request to the loading system, so
    /// no name is resolved and nothing leaves this Mac.
    @Test func aURLRewrittenToAnotherHostSendsNoKeyThere() async throws {
        let owner = StubEndpoint(always: .completion(Self.answer)), elsewhere = StubEndpoint(always: .completion(Self.answer))
        let suite = Self.suite(endpoint: owner.baseURL.absoluteString)
        let credentials = InMemoryCredentials()
        try Self.saveKey("sk-SAVED-FOR-KEY-OWNER", in: suite, to: credentials)
        let router = Self.router(suite, credentials, session: { StubEndpoint.configuration() })

        _ = await router.ask(.explain(Self.question), origin: .reader)
        let control = try #require(owner.requests.first)
        #expect(control.header("Authorization") == "Bearer sk-SAVED-FOR-KEY-OWNER",
                "the control: the origin the key was saved for was not sent it")

        suite.set(elsewhere.baseURL.absoluteString, forKey: ProviderSettingsStore.Key.endpointURL)
        _ = await router.ask(.explain(Self.question), origin: .reader)
        let request = try #require(elsewhere.requests.first, "the rewritten endpoint was never asked")
        #expect(request.url.host() == elsewhere.host)
        #expect(request.header("Authorization") == nil, "the key saved for one host went to another")
        #expect(!request.headers.values.contains { $0.contains("SAVED-FOR-KEY-OWNER") })
        #expect(owner.requests.count == 1, "the host the reader left was asked again")
        await router.shutDown()
    }
}
