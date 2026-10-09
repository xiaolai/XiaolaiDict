import Foundation
@testable import LLMProviders
import ModelKit
import Testing
import XiaolaiDictTestSupport

/// **No dictionary text reaches a source that is not on this Mac** (plan §3, §8) — asserted on the bytes that reached
/// the wire, through the path the app takes: the reader's settings, the router, the client that decides what the tier
/// may see, and the provider that sends it.
///
/// **The remote host is real to the code and never reached.** A remote endpoint is HTTPS — plain HTTP off this Mac is
/// not sent at all (`EndpointAddress`), which `aPlainHTTPEndpointOffThisMacIsSentNothing` asserts on a real socket — so
/// it is a `StubEndpoint` at a host of its own, `RemoteDisclosure` reading it as remote as it reads every host that is
/// not loopback: the request is read where `URLSession` hands it to the loading system, body and headers whole, which is
/// what TLS would carry to that host. No name is resolved and nothing leaves this Mac.
///
/// The control is the same question to an endpoint on 127.0.0.1, which is on this Mac and **is** sent the sense — on a
/// real socket — so each check can fail, and fails for the reason it exists.
struct RemoteSendTests {
    static let sentence = "She banked the fire before going to bed."
    static let sense = "heap (a fire) with tightly packed fuel so that it burns slowly"
    static let explanation = SentenceQuestion(sentence: sentence, term: "banked", senseText: sense)
    static let translation = TranslationQuestion(sentence: sentence, target: "zh-Hans",
                                                 met: .init(term: "banked", sense: sense))
    static let senses = SenseQuestion(sentence: sentence, partOfSpeech: "verb",
                                      senses: [sense, "deposit (money or valuables) in a bank"])
    static let remoteHost = "dictionary-host.example"

    /// A loopback server that answers as a chat completions endpoint would: a translation for a translation, a number
    /// for a sense list, prose for the rest.
    static func endpoint() throws -> LoopbackHTTPServer {
        try LoopbackHTTPServer { request in
            let messages = request.json?["messages"] as? [[String: String]] ?? []
            let instructions = messages.first { $0["role"] == "system" }?["content"] ?? ""
            if instructions.hasPrefix("Translate") { return .respond(.completion("她睡前把炉火封好了。")) }
            if instructions == ModelPrompt.senseInstructions { return .respond(.completion("1")) }
            return .respond(.completion("She covered the fire so that it would burn slowly through the night."))
        }
    }

    /// What the stub of a remote endpoint answers: as `endpoint()` does.
    static func remote() -> StubEndpoint {
        StubEndpoint { request, _ in
            let messages = request.json?["messages"] as? [[String: String]] ?? []
            let instructions = messages.first { $0["role"] == "system" }?["content"] ?? ""
            if instructions.hasPrefix("Translate") { return .completion("她睡前把炉火封好了。") }
            if instructions == ModelPrompt.senseInstructions { return .completion("1") }
            return .completion("She covered the fire so that it would burn slowly through the night.")
        }
    }

    /// A session sent through `proxy`, a server on 127.0.0.1, for every plain-HTTP request.
    static func proxied(through proxy: LoopbackHTTPServer) -> @Sendable () -> URLSessionConfiguration {
        let port = Int(proxy.port)
        return {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: port,
            ]
            return configuration
        }
    }

    /// The router the app builds, over `source`, its endpoint session `session`, with a key filed for `keyFor`.
    static func router(_ source: ProviderSource,
                       session: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral },
                       keyFor: URL = URL(string: "http://\(remoteHost)/v1").unsafelyUnwrapped) -> ModelBackendRouter {
        let factory = ProviderFactory(
            locator: CLILocator(searchDirectories: [], loginShell: nil, shellTimeout: .seconds(1)),
            credentials: InMemoryCredentials(key: "sk-remote-send", for: keyFor),
            configuration: ResidentSessionTests.configuration(),
            endpointSession: session, scratch: { nil }, events: { _ in })
        return ModelBackendRouter(
            source: { source }, local: .init(ask: { _ in nil }, prewarm: {}), factory: factory,
            dictionaryTextMayLeave: RemoteDisclosure.dictionaryTextMayLeave)
    }

    static func body(_ request: LoopbackHTTPServer.Request) -> String {
        String(decoding: request.body, as: UTF8.self)
    }

    // MARK: - An endpoint that is not on this Mac

    /// **The remote host is sent the reader's sentence, and none of the dictionary's text** — an explanation and a
    /// translation each reach it, and a sense question does not reach it at all, whether a lookup or a tap asked.
    @Test func aRemoteEndpointIsSentTheSentenceAndNothingOfTheDictionarys() async throws {
        let server = Self.remote()
        let router = Self.router(.endpoint(url: server.baseURL.absoluteString, model: "m"),
                                 session: { StubEndpoint.configuration() }, keyFor: server.baseURL)

        let explained = await router.ask(.explain(Self.explanation), origin: .reader)
        #expect(explained.tier == .remote)
        #expect(explained.reply == .explanation("She covered the fire so that it would burn slowly through the night."))
        let translated = await router.ask(.translate(Self.translation), origin: .reader)
        #expect(translated.reply == .translation("她睡前把炉火封好了。"))
        for origin in [QuestionOrigin.lookup, .reader] {
            #expect(await router.ask(.pickSense(Self.senses), origin: origin).reply == nil)
        }

        let requests = server.requests
        #expect(requests.count == 2, "\(requests.count) requests reached the wire; a sense question must send none")
        for request in requests {
            // What the loading system was handed for the remote host: what TLS would carry there, byte for byte.
            #expect(request.url.absoluteString == "https://\(server.host)/v1/chat/completions")
            #expect(request.header("Authorization") == "Bearer sk-remote-send", "the control: the key went with it")
            let body = String(decoding: request.body, as: UTF8.self)
            #expect(body.contains(Self.sentence), "the reader's sentence did not go")
            #expect(!body.contains("tightly packed fuel"), "the dictionary's sense reached a remote host: \(body)")
            #expect(!RemoteDisclosure.leaks(body, of: .explain(Self.explanation)))
            #expect(!RemoteDisclosure.leaks(body, of: .translate(Self.translation)))
        }
        await router.shutDown()
    }

    /// **A plain-HTTP endpoint off this Mac is sent nothing** — not the sentence, and not the key filed for it — since it
    /// would cross the network unencrypted. Asserted on the proxy's socket, where the request would have arrived; and
    /// the reader's check says the address cannot be used.
    @Test func aPlainHTTPEndpointOffThisMacIsSentNothing() async throws {
        let server = try Self.endpoint()
        let router = Self.router(.endpoint(url: "http://\(Self.remoteHost)/v1", model: "m"),
                                 session: Self.proxied(through: server))
        #expect(await router.ask(.explain(Self.explanation), origin: .reader).reply == nil)
        #expect(await router.ask(.translate(Self.translation), origin: .reader).reply == nil)
        #expect(server.requests.isEmpty, "\(server.requests.count) requests went out unencrypted")
        #expect(await router.check()?.readiness == .endpointUnusable)
        await router.shutDown()
    }

    /// **The control**: an endpoint on 127.0.0.1 is on this Mac, is sent the sense with each question, and is asked
    /// to pick one — so the assertions above can fail, and would fail for the reason they exist.
    @Test func anEndpointOnThisMacIsSentTheSenseToo() async throws {
        let server = try Self.endpoint()
        let router = Self.router(.endpoint(url: server.url("/v1").absoluteString, model: "m"))
        #expect(await router.ask(.explain(Self.explanation), origin: .reader).tier == .onThisMac)
        _ = await router.ask(.translate(Self.translation), origin: .reader)
        #expect(await router.ask(.pickSense(Self.senses), origin: .lookup).reply == .sense(1))

        let bodies = server.requests.map(Self.body)
        #expect(bodies.count == 3)
        #expect(bodies.allSatisfy { $0.contains("tightly packed fuel") }, "a source on this Mac was not sent the sense")
        await router.shutDown()
    }

    // MARK: - A CLI, which is remote wherever it is installed

    /// **The reader's CLI is sent the sentence and nothing of the dictionary's** — read off what the fake `claude`
    /// received on its standard input, which is what the real one would put on its wire. A sense question is not
    /// written to it at all.
    @Test func aCLIIsSentTheSentenceAndNothingOfTheDictionarys() async throws {
        let fake = try FakeCLI.claude()
        let router = ModelBackendRouter(
            source: { .claudeCLI(path: nil, model: "haiku") }, local: .init(ask: { _ in nil }, prewarm: {}),
            factory: ModelBackendRouterTests.factory(finding: fake, events: EventLog()),
            dictionaryTextMayLeave: RemoteDisclosure.dictionaryTextMayLeave)
        #expect(await router.ask(.explain(Self.explanation), origin: .reader).tier == .remote)
        _ = await router.ask(.translate(Self.translation), origin: .reader)
        for origin in [QuestionOrigin.lookup, .reader] { _ = await router.ask(.pickSense(Self.senses), origin: origin) }

        let turns = try fake.logged("text", as: String.self)
        #expect(turns.count == 2, "\(turns.count) turns reached the CLI; a sense question must send none")
        for turn in turns {
            #expect(turn.contains(Self.sentence))
            #expect(!turn.contains("tightly packed fuel"), "the dictionary's sense reached the CLI: \(turn)")
        }
        await router.shutDown()
    }
}
