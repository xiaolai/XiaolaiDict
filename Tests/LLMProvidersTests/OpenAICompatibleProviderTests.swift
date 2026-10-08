import Foundation
@testable import LLMProviders
import ModelKit
import Synchronization
import Testing

/// **`OpenAICompatibleProvider` against a stub of the endpoint** — the request it builds, every answer it reads, and
/// every way an answer can fail, each mapped to one `ProviderFailure`. The wire itself — a kept connection, the
/// request line, a redirect — is `LoopbackWireTests`'; this is the matrix, which a stub can drive exhaustively.
struct OpenAICompatibleProviderTests {
    static let request = GenerationRequest(
        instructions: "Answer with the number of the sense.", prompt: "Sentence: She banked the fire.\nWhich number?",
        maxTokens: 16, temperature: 0)

    static func provider(_ endpoint: StubEndpoint, credentials: any CredentialStore = InMemoryCredentials(key: "sk-test"),
                         model: String = "gpt-test", endpointURL: URL? = nil,
                         limit: Int = OpenAICompatibleProvider.responseByteLimit) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(endpoint: endpointURL ?? endpoint.baseURL, model: model, credentials: credentials,
                                 timeout: .seconds(10), sessionConfiguration: StubEndpoint.configuration(),
                                 responseByteLimit: limit)
    }

    /// The failure `call` threw, or nil where it answered.
    static func failure(of provider: OpenAICompatibleProvider,
                        _ request: GenerationRequest = request) async -> ProviderFailure? {
        do {
            _ = try await provider.generate(request)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - The request

    /// **One POST to `{base}/chat/completions`**: the model, a system message holding the instructions and a user
    /// message holding the prompt, the temperature, and the token budget as `max_completion_tokens` — the name
    /// OpenAI's newer models require — with no `max_tokens` beside it.
    @Test func itSendsOneChatCompletionsRequest() async throws {
        let endpoint = StubEndpoint(always: .completion("3"))
        let answer = try await Self.provider(endpoint).generate(Self.request)
        #expect(answer == "3")
        let sent = try #require(endpoint.requests.first)
        #expect(endpoint.requests.count == 1)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://\(endpoint.host)/v1/chat/completions")
        #expect(sent.header("Content-Type") == "application/json")
        #expect(sent.header("Authorization") == "Bearer sk-test")
        let body = try #require(sent.json)
        #expect(Set(body.keys) == ["model", "messages", "temperature", "max_completion_tokens"])
        #expect(body["model"] as? String == "gpt-test")
        #expect((body["temperature"] as? NSNumber)?.doubleValue == 0)
        #expect((body["max_completion_tokens"] as? NSNumber)?.intValue == 16)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [
            ["role": "system", "content": Self.request.instructions],
            ["role": "user", "content": Self.request.prompt],
        ])
    }

    /// **Instructions are optional**: with none there is no empty system message, only the user's.
    @Test func noInstructionsSendsNoSystemMessage() async throws {
        let endpoint = StubEndpoint(always: .completion("fine"))
        let bare = GenerationRequest(instructions: "", prompt: "Translate: chat", maxTokens: 64, temperature: 0.7)
        _ = try await Self.provider(endpoint).generate(bare)
        let body = try #require(endpoint.requests.first?.json)
        #expect(body["messages"] as? [[String: String]] == [["role": "user", "content": "Translate: chat"]])
        #expect((body["temperature"] as? NSNumber)?.doubleValue == 0.7)
    }

    /// The base URL is joined as a path: a trailing slash does not double, and a query a server needs survives.
    @Test(arguments: [("/v1/", "/v1/chat/completions", nil), ("/openai", "/openai/chat/completions", "api-version=2026-01-01")]
          as [(String, String, String?)])
    func theBaseURLIsJoinedAsAPath(base: String, path: String, query: String?) async throws {
        let endpoint = StubEndpoint(always: .completion("1"))
        let url = try #require(URL(string: "https://\(endpoint.host)\(base)\(query.map { "?\($0)" } ?? "")"))
        _ = try await Self.provider(endpoint, endpointURL: url).generate(Self.request)
        let sent = try #require(endpoint.requests.first)
        #expect(sent.url.path() == path)
        #expect(sent.url.query() == query)
    }

    /// **A key is optional — a local server has none — and with none there is no `Authorization` header at all.**
    @Test func withNoKeyThereIsNoAuthorizationHeader() async throws {
        let endpoint = StubEndpoint(always: .completion("2"))
        _ = try await Self.provider(endpoint, credentials: InMemoryCredentials()).generate(Self.request)
        let sent = try #require(endpoint.requests.first)
        #expect(sent.header("Authorization") == nil)
        // An empty stored value is no key either.
        let blank = StubEndpoint(always: .completion("2"))
        _ = try await Self.provider(blank, credentials: InMemoryCredentials(key: "")).generate(Self.request)
        #expect(try #require(blank.requests.first).header("Authorization") == nil)
    }

    /// **The key is read from the store on every call, never kept**: a key changed between two calls is the one the
    /// second call sends, and each call reads the store once.
    @Test func theKeyIsReadPerCall() async throws {
        let endpoint = StubEndpoint(always: .completion("2"))
        let credentials = InMemoryCredentials(key: "sk-first")
        let provider = Self.provider(endpoint, credentials: credentials)
        _ = try await provider.generate(Self.request)
        try credentials.write("sk-second", account: OpenAICompatibleProvider.credentialAccount)
        _ = try await provider.generate(Self.request)
        #expect(endpoint.requests.map { $0.header("Authorization") } == ["Bearer sk-first", "Bearer sk-second"])
        #expect(credentials.reads == 2)
    }

    /// **A key that could break a header is never sent**: a line break in it would end the header and begin
    /// another. Refused as unauthorised before anything leaves — and a plain key, the control, is sent.
    @Test(arguments: ["sk-a\r\nX-Injected: 1", "sk-a\nb", "sk a", "sk-\u{7F}", "sk-é"])
    func aKeyThatCouldBreakAHeaderIsNeverSent(key: String) async {
        let endpoint = StubEndpoint(always: .completion("2"))
        #expect(await Self.failure(of: Self.provider(endpoint, credentials: InMemoryCredentials(key: key))) == .unauthorised)
        #expect(endpoint.requests.isEmpty, "a request left with a key that is not a header value")
        let control = StubEndpoint(always: .completion("2"))
        #expect(await Self.failure(of: Self.provider(control, credentials: InMemoryCredentials(key: "sk-a_b.c-9"))) == nil)
    }

    /// **A store that will not answer is unauthorised, and nothing is sent** — never a request without the key the
    /// reader saved, which a server would answer 401 for a reason nobody could see.
    @Test func aStoreThatWillNotAnswerSendsNothing() async {
        let endpoint = StubEndpoint(always: .completion("2"))
        let credentials = InMemoryCredentials(key: "sk-test")
        credentials.failEveryCall(with: .keychain(status: -25_308))
        #expect(await Self.failure(of: Self.provider(endpoint, credentials: credentials)) == .unauthorised)
        #expect(endpoint.requests.isEmpty)
    }

    // MARK: - The answer

    /// Content as an array of parts is read too — some servers write it so — and its text parts are joined.
    @Test func contentPartsAreJoined() async throws {
        let endpoint = StubEndpoint(always: .json("""
            {"choices":[{"index":0,"message":{"role":"assistant","content":[\
            {"type":"text","text":"The word "},{"type":"image_url","image_url":{"url":"x"}},{"type":"text","text":"is a verb."}\
            ]},"finish_reason":"stop"}]}
            """))
        #expect(try await Self.provider(endpoint).generate(Self.request) == "The word is a verb.")
    }

    /// Surrounding blank space is not part of an answer.
    @Test func surroundingBlankSpaceIsTrimmed() async throws {
        let endpoint = StubEndpoint(always: .completion("\n  4\n"))
        #expect(try await Self.provider(endpoint).generate(Self.request) == "4")
    }

    // MARK: - Failures, by status

    @Test(arguments: [
        (401, ProviderFailure.unauthorised), (403, .unauthorised),
        (404, .modelNotFound), (429, .rateLimited),
        (500, .unreachable), (502, .unreachable), (503, .unreachable), (504, .unreachable),
        (418, .badShape("HTTP 418")), (422, .badShape("HTTP 422")),
    ] as [(Int, ProviderFailure)])
    func eachStatusIsOneFailure(status: Int, expected: ProviderFailure) async {
        let endpoint = StubEndpoint(always: .error(status: status, message: "nope"))
        #expect(await Self.failure(of: Self.provider(endpoint)) == expected, "\(status)")
        #expect(endpoint.requests.count == 1, "a failure was retried: \(status)")
    }

    /// **A model the server does not have is said by its code too**: some servers answer 400 with
    /// `model_not_found` rather than 404.
    @Test func aModelNotFoundCodeIsModelNotFound() async {
        let endpoint = StubEndpoint(always: .error(status: 400, message: "The model `gpt-x` does not exist",
                                                   code: "model_not_found"))
        #expect(await Self.failure(of: Self.provider(endpoint)) == .modelNotFound)
    }

    // MARK: - Failures, by transport

    @Test(arguments: [
        (URLError.Code.cannotConnectToHost, ProviderFailure.unreachable), (.notConnectedToInternet, .unreachable),
        (.cannotFindHost, .unreachable), (.networkConnectionLost, .unreachable), (.dnsLookupFailed, .unreachable),
        (.secureConnectionFailed, .unreachable), (.timedOut, .timedOut), (.cancelled, .cancelled),
    ] as [(URLError.Code, ProviderFailure)])
    func eachTransportErrorIsOneFailure(code: URLError.Code, expected: ProviderFailure) async {
        let endpoint = StubEndpoint(always: .fail(URLError(code)))
        #expect(await Self.failure(of: Self.provider(endpoint)) == expected, "\(code)")
    }

    // MARK: - Failures, by shape

    @Test(arguments: [
        ("not json", "not a chat completion"),
        (#"{"choices":[]}"#, "no choices"),
        (#"{"choices":[{"index":0,"message":{"role":"assistant","content":null},"finish_reason":"stop"}]}"#, "no content"),
        (#"{"choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"stop"}]}"#, "an empty answer"),
        (#"{"choices":[{"index":0,"message":{"role":"assistant","content":" \n "},"finish_reason":"stop"}]}"#, "an empty answer"),
        (#"{"choices":[{"index":0,"message":{"role":"assistant","content":[]},"finish_reason":"stop"}]}"#, "an empty answer"),
        (#"{"object":"list"}"#, "not a chat completion"),
    ])
    func anAnswerOfTheWrongShapeIsBadShape(body: String, detail: String) async {
        let endpoint = StubEndpoint(always: .json(body))
        #expect(await Self.failure(of: Self.provider(endpoint)) == .badShape(detail), "\(body)")
    }

    /// **A refusal is the model's own**: a content filter's finish, a `refusal` in the message, or a 400 whose code
    /// says the content was filtered — each is `.refused`, which the ladders report as an abstention.
    @Test(arguments: [
        #"{"choices":[{"index":0,"message":{"role":"assistant","content":null,"refusal":"I can't help with that."},"finish_reason":"stop"}]}"#,
        #"{"choices":[{"index":0,"message":{"role":"assistant","content":""},"finish_reason":"content_filter"}]}"#,
        #"{"choices":[{"index":0,"message":{"role":"assistant","content":"partial"},"finish_reason":"content_filter"}]}"#,
    ])
    func aRefusalIsRefused(body: String) async {
        let endpoint = StubEndpoint(always: .json(body))
        #expect(await Self.failure(of: Self.provider(endpoint)) == .refused, "\(body)")
    }

    @Test(arguments: ["content_filter", "content_policy_violation"])
    func aFilteredRequestIsRefused(code: String) async {
        let endpoint = StubEndpoint(always: .error(status: 400, message: "The response was filtered", code: code))
        #expect(await Self.failure(of: Self.provider(endpoint)) == .refused)
    }

    /// **The answer is read up to a bound and no further**: a body past it is refused as a bad shape, and one just
    /// under it — the control — is read.
    @Test func aBodyPastTheBoundIsRefused() async throws {
        let long = String(repeating: "a", count: 4_096)
        let over = StubEndpoint(always: .completion(long))
        #expect(await Self.failure(of: Self.provider(over, limit: 1_024)) == .badShape("an answer larger than the bound"))
        let under = StubEndpoint(always: .completion(long))
        #expect(try await Self.provider(under, limit: 8_192).generate(Self.request) == long)
    }

    // MARK: - The token budget's name

    /// **A server that refuses `max_completion_tokens` is asked once more with `max_tokens`, and the instance keeps
    /// the name that worked**: the third call sends `max_tokens` first and is answered on one request.
    @Test func aRefusedTokenFieldIsRetriedOnceAndRemembered() async throws {
        let endpoint = StubEndpoint { request, _ in
            request.json?["max_completion_tokens"] != nil
                ? .error(status: 400, message: "Unrecognized request argument supplied: max_completion_tokens")
                : .completion("5")
        }
        let provider = Self.provider(endpoint)
        #expect(try await provider.generate(Self.request) == "5")
        #expect(endpoint.requests.count == 2)
        let retried = try #require(endpoint.requests.last?.json)
        #expect((retried["max_tokens"] as? NSNumber)?.intValue == 16)
        #expect(retried["max_completion_tokens"] == nil)
        #expect(try await provider.generate(Self.request) == "5")
        #expect(endpoint.requests.count == 3, "the name that worked was not remembered")
        #expect(endpoint.requests.last?.json?["max_tokens"] != nil)
    }

    /// **And the reverse**: an instance on `max_tokens` whose server comes to refuse it — OpenAI's newer models answer
    /// "Unsupported parameter: 'max_tokens' … Use 'max_completion_tokens' instead" — goes back, and remembers that.
    @Test func theReverseIsRetriedOnceAndRemembered() async throws {
        let refuseNew = Mutex(true)
        let endpoint = StubEndpoint { request, _ in
            let body = request.json ?? [:]
            if refuseNew.withLock({ $0 }), body["max_completion_tokens"] != nil {
                return .error(status: 400, message: "Unrecognized request argument supplied: max_completion_tokens")
            }
            if !refuseNew.withLock({ $0 }), body["max_tokens"] != nil {
                return .error(status: 400, message: "Unsupported parameter: 'max_tokens' is not supported with this "
                              + "model. Use 'max_completion_tokens' instead.", code: "unsupported_parameter",
                              param: "max_tokens")
            }
            return .completion("1")
        }
        let provider = Self.provider(endpoint)
        #expect(try await provider.generate(Self.request) == "1")
        refuseNew.withLock { $0 = false }
        #expect(try await provider.generate(Self.request) == "1")
        #expect(endpoint.requests.count == 4)
        #expect(try await provider.generate(Self.request) == "1")
        #expect(endpoint.requests.count == 5)
        #expect(endpoint.requests.last?.json?["max_completion_tokens"] != nil)
    }

    /// **Once, not a loop**: a server that refuses both names is asked twice and the answer is a bad shape — and the
    /// name the instance sends next is unchanged, since neither worked.
    @Test func aServerThatRefusesBothIsAskedTwice() async throws {
        let endpoint = StubEndpoint { request, _ in
            let sent = request.json?["max_tokens"] != nil ? "max_tokens" : "max_completion_tokens"
            return .error(status: 400, message: "Unrecognized request argument supplied: \(sent)")
        }
        let provider = Self.provider(endpoint)
        #expect(await Self.failure(of: provider) == .badShape("the server takes neither token budget"))
        #expect(endpoint.requests.count == 2)
        _ = await Self.failure(of: provider)
        let third = try #require(endpoint.requests.dropFirst(2).first, "the second call sent nothing")
        #expect(third.json?["max_completion_tokens"] != nil)
    }

    /// A 400 about something else is not retried, whatever it says — and a server that echoes the request back in
    /// its error (`max_completion_tokens` appears there as a field we sent, not as one refused) is not either.
    @Test func a400AboutSomethingElseIsNotRetried() async {
        let endpoint = StubEndpoint(always: .error(status: 400, message: "messages: too long", param: "messages"))
        #expect(await Self.failure(of: Self.provider(endpoint)) == .badShape("HTTP 400"))
        #expect(endpoint.requests.count == 1)
        let echoing = StubEndpoint(always: .json(#"""
            {"detail":[{"type":"missing","loc":["body","model"],"msg":"Field required",\
            "input":{"messages":[],"max_completion_tokens":16}}]}
            """#, status: 400))
        #expect(await Self.failure(of: Self.provider(echoing)) == .badShape("HTTP 400"))
        #expect(echoing.requests.count == 1)
    }

    // MARK: - Cancellation

    /// **A cancelled call ends as `.cancelled`** — the request is in flight, the task is cancelled, and the provider
    /// says so rather than waiting for a server that will never answer.
    @Test func aCancelledCallIsCancelled() async throws {
        let endpoint = StubEndpoint(always: .hang)
        let provider = Self.provider(endpoint)
        let call = Task { await Self.failure(of: provider) }
        // Wait for the request to be in flight — the work, not the call that started it.
        for _ in 0..<500 where endpoint.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!endpoint.requests.isEmpty, "the request never reached the stub")
        call.cancel()
        #expect(await call.value == .cancelled)
    }

    /// A call made from a task already cancelled sends nothing.
    @Test func aCallFromACancelledTaskSendsNothing() async {
        let endpoint = StubEndpoint(always: .completion("1"))
        let provider = Self.provider(endpoint)
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Self.failure(of: provider)
        }
        #expect(await call.value == .cancelled)
        #expect(endpoint.requests.isEmpty)
    }

    // MARK: - Nothing secret in what a failure says

    /// **No failure carries the key, a header or the body**: every way a call can fail, against a server whose body
    /// holds a marker and a request carrying a marked key — neither appears in the failure or in what it maps to.
    @Test func noFailureCarriesTheKeyOrTheBody() async {
        let key = "sk-KEY-MARKER-7f3a"
        let marker = "BODY-MARKER-91c2"
        let answers: [StubAnswer] = [
            .error(status: 401, message: marker), .error(status: 404, message: marker),
            .error(status: 400, message: marker, code: marker), .error(status: 429, message: marker),
            .error(status: 500, message: marker), .json(marker), .json(#"{"choices":[],"note":"\#(marker)"}"#),
            .json(#"{"choices":[{"message":{"content":null,"refusal":"\#(marker)"},"finish_reason":"stop"}]}"#),
            .fail(URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: marker])),
        ]
        for answer in answers {
            let endpoint = StubEndpoint(always: answer)
            let provider = Self.provider(endpoint, credentials: InMemoryCredentials(key: key))
            guard let failure = await Self.failure(of: provider) else {
                Issue.record("\(answer) answered")
                continue
            }
            for said in [String(describing: failure), String(reflecting: failure),
                         String(describing: ProviderFailure.modelFailure(for: failure))] {
                #expect(!said.contains(key) && !said.contains(marker), "\(said)")
            }
        }
    }

    /// **The provider holds no key to describe**: after a call, neither its description nor its reflection holds the
    /// key. The control: a value that does hold one is caught by the same check.
    @Test func theProviderDescribesNoKey() async throws {
        let key = "sk-KEY-MARKER-5d0e"
        let endpoint = StubEndpoint(always: .completion("1"))
        let provider = Self.provider(endpoint, credentials: InMemoryCredentials(key: key))
        _ = try await provider.generate(Self.request)
        #expect(!Self.reflects(provider, key))
        struct Holding { let key: String }
        #expect(Self.reflects(Holding(key: key), key), "the check cannot see a key a value holds")
    }

    /// Whether `value`'s description, debug description or any child its mirror lists, to any depth, holds `text`.
    static func reflects(_ value: Any, _ text: String, depth: Int = 0) -> Bool {
        if String(describing: value).contains(text) || String(reflecting: value).contains(text) { return true }
        guard depth < 4 else { return false }
        return Mirror(reflecting: value).children.contains { reflects($0.value, text, depth: depth + 1) }
    }
}
