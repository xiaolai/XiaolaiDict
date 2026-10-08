import Foundation
import ModelKit
import XiaolaiDictBase
import os

/// **An OpenAI-compatible endpoint, asked one question at a time** (ADR-0053, plan §5): OpenAI itself, Gemini's and
/// xAI's compatible endpoints, DeepSeek, and a local Ollama, LM Studio or `mlx_lm.server`.
///
/// `POST {endpoint}/chat/completions`, not streamed: a system message holding the instructions, a user message
/// holding the prompt, the temperature, and the token budget — sent as `max_completion_tokens` and, where a server
/// answers 400 naming it, once more as `max_tokens` (or the reverse), the instance then keeping the name that worked.
///
/// - **One `URLSession` for the instance's life, never one per call.** A new TCP and TLS connection per call cost
///   1.5–2 s on a warm endpoint (measured, plan §1); a kept session reuses one. `LoopbackWireTests` counts the
///   connections on a real socket.
/// - **The key is read from the `CredentialStore` on every call** and kept nowhere — not in a property, not in a
///   log, not in a failure — so this type has nothing to describe. A key is optional: a local server has none, and
///   then no `Authorization` header is sent at all.
/// - **The key read is the one filed for this endpoint's origin** (`EndpointAddress.keyAccount`), so an instance made
///   for another host — the reader's URL changed, or rewritten in the defaults by something else — finds no key and
///   sends none.
/// - **A redirect is followed only within the endpoint's own origin.** Following one elsewhere would send the body —
///   the reader's sentence, and for an endpoint on this Mac the dictionary's text — to a host `RemoteDisclosure` never
///   judged, and the key with it.
/// - **The answer is read up to `responseByteLimit` and no further.**
/// - **It fails in `ProviderFailure` alone**, and no failure carries what the server said.
public actor OpenAICompatibleProvider: TextGenerating {
    /// How long a request may go without the server sending anything, and how long it may take in all.
    public static let defaultTimeout = Duration.seconds(30)
    /// The most of an answer that is read. A completion of the budgets `ModelPrompt` sets is a few kilobytes; a
    /// quarter of a megabyte is a server that is not answering the question it was asked.
    public static let responseByteLimit = 256 * 1_024

    private static let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "providers")

    private let completions: URL
    private let model: String
    private let credentials: any CredentialStore
    /// The account this endpoint's key is filed under — its origin's — or nil where the URL names no origin, for which
    /// no key is read at all.
    private let keyAccount: String?
    private let session: URLSession
    private let responseByteLimit: Int
    /// The name the token budget goes under next. Starts with the newer name, which OpenAI's newer models require.
    private var tokenField = ChatCompletionsWire.TokenField.maxCompletionTokens

    /// A provider for the endpoint whose base URL is `endpoint` — `https://api.openai.com/v1`, say — asking for
    /// `model`, its key read from `credentials` on every call, under the account of `endpoint`'s origin.
    public init(endpoint: URL, model: String, credentials: any CredentialStore,
                timeout: Duration = OpenAICompatibleProvider.defaultTimeout) {
        self.init(endpoint: endpoint, model: model, credentials: credentials, timeout: timeout,
                  sessionConfiguration: .ephemeral, responseByteLimit: Self.responseByteLimit)
    }

    /// The same, over `sessionConfiguration` — which the provider takes over and sets up as its own — and with a
    /// bound of the caller's: how a test routes the session through a stub and reaches the bound with a small body.
    init(endpoint: URL, model: String, credentials: any CredentialStore, timeout: Duration,
         sessionConfiguration: URLSessionConfiguration, responseByteLimit: Int) {
        completions = endpoint.appending(path: "chat/completions")
        self.model = model
        self.credentials = credentials
        keyAccount = EndpointAddress(url: endpoint)?.keyAccount
        self.responseByteLimit = responseByteLimit
        let seconds = Self.seconds(timeout)
        sessionConfiguration.timeoutIntervalForRequest = seconds
        sessionConfiguration.timeoutIntervalForResource = seconds
        // Nothing kept between calls but the connection: no cookies, no cached answers holding a reader's sentence,
        // no credentials remembered by the loading system — the key travels in a header this type sets, per call.
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCredentialStorage = nil
        session = URLSession(configuration: sessionConfiguration, delegate: SameOriginRedirects(endpoint: endpoint),
                             delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    /// Cancels every request in flight and closes the kept connection, for a source the reader has left — after which
    /// a question fails as unreachable, and the router asks this instance nothing more.
    func invalidate() {
        session.invalidateAndCancel()
    }

    public func generate(_ request: GenerationRequest) async throws(ProviderFailure) -> String {
        guard !Task.isCancelled else { throw .cancelled }
        let key = try readKey()
        let field = tokenField
        do throws(ProviderFailure) {
            switch try await attempt(request, key: key, field: field) {
            case .answer(let text):
                return text
            case .tokenFieldRefused:
                Self.log.info("""
                    the endpoint refused \(field.rawValue, privacy: .public); asking once more with \
                    \(field.other.rawValue, privacy: .public)
                    """)
            }
            switch try await attempt(request, key: key, field: field.other) {
            case .answer(let text):
                tokenField = field.other
                return text
            case .tokenFieldRefused:
                throw ProviderFailure.badShape("the server takes neither token budget")
            }
        } catch {
            // A cancellation is a reader moving on — hover makes them constantly — and not a failure worth an error.
            if error == .cancelled {
                Self.log.debug("a chat completion was cancelled")
            } else {
                Self.log.error("a chat completion failed: \(String(describing: error), privacy: .public)")
            }
            throw error
        }
    }

    // MARK: - One request

    /// What one request came back as: an answer, or the server refusing the token budget's name.
    private enum Outcome {
        case answer(String)
        case tokenFieldRefused
    }

    private func attempt(_ generation: GenerationRequest, key: String?,
                         field: ChatCompletionsWire.TokenField) async throws(ProviderFailure) -> Outcome {
        var request = URLRequest(url: completions)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        do {
            request.httpBody = try encoder.encode(ChatCompletionsWire.Request(model: model, generation: generation,
                                                                              field: field))
        } catch {
            throw .badShape("a request that would not encode")
        }
        let (status, body) = try await exchange(request)
        return try Self.outcome(status: status, body: body, field: field)
    }

    /// The key filed for this endpoint's origin, or nil where there is none — and none is legal: a local server takes
    /// no key. A key that is not a plain run of visible ASCII is never sent: a line break in it would end the header
    /// and start another.
    private func readKey() throws(ProviderFailure) -> String? {
        guard let keyAccount else { return nil }
        let stored: String?
        do {
            stored = try credentials.read(account: keyAccount)
        } catch {
            Self.log.error("the endpoint's key could not be read: \(String(describing: error), privacy: .public)")
            throw .unauthorised
        }
        guard let stored, !stored.isEmpty else { return nil }
        guard Self.canSend(key: stored) else {
            Self.log.error("the endpoint's key holds a character a header cannot carry; nothing was sent")
            throw .unauthorised
        }
        return stored
    }

    /// **Whether `key` can travel in a request header**: one run of visible ASCII and nothing else — a line break in it
    /// would end the header and start another. The one spelling of the rule: Settings refuses to save what this refuses
    /// to send, so a key the reader saved never fails every question for a reason they cannot see.
    public static func canSend(key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    /// Sends `request` on the kept session and reads the answer, up to the bound.
    private func exchange(_ request: URLRequest) async throws(ProviderFailure) -> (status: Int, body: Data) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw ProviderFailure.badShape("not an HTTP response")
            }
            if http.expectedContentLength > Int64(responseByteLimit) {
                bytes.task.cancel()
                throw ProviderFailure.badShape("an answer larger than the bound")
            }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > responseByteLimit {
                    bytes.task.cancel()
                    throw ProviderFailure.badShape("an answer larger than the bound")
                }
            }
            return (http.statusCode, body)
        } catch let failure as ProviderFailure {
            throw failure
        } catch {
            throw Self.failure(for: error)
        }
    }

    // MARK: - Reading what came back

    /// What a response says, by its status first and then its body.
    private static func outcome(status: Int, body: Data,
                                field: ChatCompletionsWire.TokenField) throws(ProviderFailure) -> Outcome {
        switch status {
        case 200..<300: return .answer(try answer(in: body))
        // Only a redirect the session declined reaches here: one to another origin (`SameOriginRedirects`).
        case 300..<400: throw .badShape("a redirect not followed")
        default: break
        }
        let error = try? JSONDecoder().decode(ChatCompletionsWire.ErrorBody.self, from: body)
        if error?.code == "model_not_found" { throw .modelNotFound }
        if let code = error?.code, code == "content_filter" || code == "content_policy_violation" { throw .refused }
        switch status {
        case 401, 403: throw .unauthorised
        case 404: throw .modelNotFound
        case 429: throw .rateLimited
        case 500..<600: throw .unreachable
        case 400 where error?.refuses(field) == true: return .tokenFieldRefused
        default: throw .badShape("HTTP \(status)")
        }
    }

    /// The first choice's text, trimmed — or the failure that says why there is none.
    private static func answer(in body: Data) throws(ProviderFailure) -> String {
        guard let completion = try? JSONDecoder().decode(ChatCompletionsWire.Completion.self, from: body) else {
            throw .badShape("not a chat completion")
        }
        guard let choice = completion.choices.first else { throw .badShape("no choices") }
        if choice.finishReason == "content_filter" { throw .refused }
        if let refusal = choice.message?.refusal, !refusal.isEmpty { throw .refused }
        guard let content = choice.message?.content else { throw .badShape("no content") }
        let answer = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw .badShape("an empty answer") }
        return answer
    }

    /// What a loading-system error means for the reader: a cancelled task is cancelled whatever the error says, a
    /// timeout is a timeout, and every other way a connection fails is unreachable. The code is logged, the
    /// description is not — it can name the URL.
    private static func failure(for error: any Error) -> ProviderFailure {
        if Task.isCancelled || error is CancellationError { return .cancelled }
        guard let loading = error as? URLError else { return .unreachable }
        switch loading.code {
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        default:
            log.error("the endpoint could not be reached: URLError \(loading.code.rawValue, privacy: .public)")
            return .unreachable
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// **A redirect is followed only where it stays in the endpoint's own origin** — scheme, host and port. One anywhere
/// else is declined, and the session hands back the redirect itself, which the provider reports as a bad shape.
///
/// Not merely "without the key": the body is the reader's sentence, and for an endpoint on this Mac the dictionary's
/// text too, and `RemoteDisclosure` judged the endpoint's host, not wherever it points next.
final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    private let origin: Origin?

    init(endpoint: URL) {
        origin = Origin(endpoint)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let origin, let target = request.url, Origin(target) == origin else { return nil }
        // **The loading system drops `Authorization` on every redirect, the same origin included** — measured on the
        // loopback wire (2026-10-09): a 307 kept its body and lost the key. Within the origin the key may go where the
        // request goes, so it is carried over from the request this task was made with, and from nowhere else.
        var next = request
        if next.value(forHTTPHeaderField: "Authorization") == nil,
           let key = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            next.setValue(key, forHTTPHeaderField: "Authorization")
        }
        return next
    }

    /// A URL's scheme, host and port, the port filled in from the scheme where it is not written.
    struct Origin: Equatable, Sendable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: true)?.lowercased(),
                  !host.isEmpty else { return nil }
            guard let port = url.port ?? Self.standardPort(of: scheme) else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = port
        }

        /// The port a URL of `scheme` means where it writes none.
        static func standardPort(of scheme: String) -> Int? {
            ["http": 80, "https": 443][scheme]
        }
    }
}
