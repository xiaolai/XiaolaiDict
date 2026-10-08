import Foundation
@testable import LLMProviders
import Testing

/// **The real wire, on a socket of this Mac** — what a `URLProtocol` stub cannot show: the request line and headers
/// as the loading system writes them, a connection kept and reused across calls (a new TCP and TLS connection per
/// call measured +1.5–2 s, plan §5), where a redirect is allowed to take the request, and the timeout the provider
/// was given. Every server here listens on 127.0.0.1 alone, in this process.
struct LoopbackWireTests {
    static let request = GenerationRequest(instructions: "Answer with a number.", prompt: "Which number?",
                                           maxTokens: 8, temperature: 0)

    static func provider(_ base: URL, key: String? = "sk-loopback",
                         timeout: Duration = .seconds(10)) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(endpoint: base, model: "loopback-model",
                                 credentials: key.map { InMemoryCredentials(key: $0) } ?? InMemoryCredentials(),
                                 timeout: timeout)
    }

    /// The failure a call threw, or nil where it answered.
    static func failure(of provider: OpenAICompatibleProvider) async -> ProviderFailure? {
        do {
            _ = try await provider.generate(request)
            return nil
        } catch {
            return error
        }
    }

    /// **Three calls, one connection**, and each request exactly as written: the request line, the headers that
    /// matter, and the body. The control: three providers — three sessions — open three connections, so the count
    /// can tell a kept session from a session per call.
    @Test func threeCallsShareOneConnectionAndTheRequestIsWhatWasMeant() async throws {
        let server = try LoopbackHTTPServer { _ in .respond(.completion("2")) }
        let provider = Self.provider(server.url("/v1"))
        for _ in 0..<3 { #expect(try await provider.generate(Self.request) == "2") }
        #expect(server.acceptedConnections == 1, "\(server.acceptedConnections) connections for three calls")
        let requests = server.requests
        #expect(requests.count == 3)
        #expect(Set(requests.map(\.connection)) == [1])
        for request in requests {
            #expect(request.method == "POST")
            #expect(request.target == "/v1/chat/completions")
            #expect(request.headers["host"] == "127.0.0.1:\(server.port)")
            #expect(request.headers["authorization"] == "Bearer sk-loopback")
            #expect(request.headers["content-type"] == "application/json")
            #expect(request.headers["content-length"] == String(request.body.count))
            let body = try #require(request.json)
            #expect(body["model"] as? String == "loopback-model")
            #expect((body["max_completion_tokens"] as? NSNumber)?.intValue == 8)
            #expect(body["messages"] as? [[String: String]] == [
                ["role": "system", "content": "Answer with a number."], ["role": "user", "content": "Which number?"],
            ])
        }

        let separate = try LoopbackHTTPServer { _ in .respond(.completion("2")) }
        for _ in 0..<3 { _ = try await Self.provider(separate.url("/v1")).generate(Self.request) }
        #expect(separate.acceptedConnections == 3, "the control: a session per call opens a connection per call")
    }

    /// **No key, no header** — on the wire, where a header the loading system added would show.
    @Test func withNoKeyNoAuthorizationReachesTheWire() async throws {
        let server = try LoopbackHTTPServer { _ in .respond(.completion("1")) }
        _ = try await Self.provider(server.url("/v1"), key: nil).generate(Self.request)
        let request = try #require(server.requests.first)
        #expect(request.headers["authorization"] == nil)
    }

    /// **A redirect to another origin is not followed, so neither the key nor the request reaches it.** Following
    /// one would send the body — the reader's sentence, and on this Mac's tier the dictionary's text — to a host the
    /// tier was never decided for, and the key with it. Another port of 127.0.0.1 is another origin, and is enough
    /// to show the rule; it is refused as a bad shape. The control: a redirect within the endpoint's own origin is
    /// followed, with the key, and answers.
    @Test func aRedirectToAnotherOriginCarriesNothingThere() async throws {
        let elsewhere = try LoopbackHTTPServer { _ in .respond(.completion("9")) }
        let target = elsewhere.url("/v1/chat/completions").absoluteString
        let server = try LoopbackHTTPServer { _ in .respond(.redirect(to: target)) }
        #expect(await Self.failure(of: Self.provider(server.url("/v1"))) == .badShape("a redirect not followed"))
        #expect(server.requests.count == 1)
        #expect(elsewhere.requests.isEmpty, "the redirect was followed: \(elsewhere.requests.map(\.headers))")
        #expect(elsewhere.acceptedConnections == 0)

        let same = try LoopbackHTTPServer { request in
            request.target == "/v1/chat/completions"
                ? .respond(.redirect(to: "/v2/chat/completions"))
                : .respond(.completion("4"))
        }
        #expect(try await Self.provider(same.url("/v1")).generate(Self.request) == "4")
        #expect(same.requests.map(\.target) == ["/v1/chat/completions", "/v2/chat/completions"])
        #expect(same.requests.last?.headers["authorization"] == "Bearer sk-loopback")
        #expect(same.requests.last?.json?["model"] as? String == "loopback-model", "a 307 kept its body")
    }

    /// **The timeout is the one the provider was given**: a server that reads the request and never answers ends
    /// the call as `.timedOut`. Asserted by what it ends as, never by how long that took.
    @Test func aServerThatNeverAnswersTimesOut() async throws {
        let server = try LoopbackHTTPServer { _ in .hang }
        #expect(await Self.failure(of: Self.provider(server.url("/v1"), timeout: .milliseconds(500))) == .timedOut)
        #expect(server.requests.count == 1)
    }

    /// **Nothing listening is unreachable** — a refused connection on the wire, not a stub's say-so.
    @Test func nothingListeningIsUnreachable() async throws {
        let port = try LoopbackHTTPServer.unusedPort()
        let base = try #require(URL(string: "http://127.0.0.1:\(port)/v1"))
        #expect(await Self.failure(of: Self.provider(base)) == .unreachable)
    }
}
