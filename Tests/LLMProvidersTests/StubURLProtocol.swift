import Foundation
import Synchronization

/// What a stub endpoint heard: the request as `URLSession` handed it to the loading system, body included.
struct HeardRequest: Sendable {
    let method: String
    let url: URL
    /// Header names as sent; look them up with `header(_:)`, which ignores case as HTTP does.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The body as a JSON object, or nil where it is not one.
    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

/// How a stub endpoint answers one request.
enum StubAnswer: Sendable {
    case respond(status: Int, headers: [String: String], body: Data)
    case fail(URLError)
    /// Never answer: the request stays in flight until the task is cancelled or times out.
    case hang

    static func json(_ text: String, status: Int = 200) -> StubAnswer {
        .respond(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }

    /// A chat completion whose one choice says `content`.
    static func completion(_ content: String, finishReason: String = "stop") -> StubAnswer {
        let encoded = String(decoding: (try? JSONEncoder().encode(content)) ?? Data("\"\"".utf8), as: UTF8.self)
        return .json("""
            {"id":"chatcmpl-1","object":"chat.completion","model":"m",\
            "choices":[{"index":0,"message":{"role":"assistant","content":\(encoded)},"finish_reason":"\(finishReason)"}]}
            """)
    }

    /// An OpenAI-shaped error body.
    static func error(status: Int, message: String, code: String? = nil, param: String? = nil) -> StubAnswer {
        func quoted(_ value: String?) -> String {
            guard let value else { return "null" }
            return String(decoding: (try? JSONEncoder().encode(value)) ?? Data("null".utf8), as: UTF8.self)
        }
        return .json("""
            {"error":{"message":\(quoted(message)),"type":"invalid_request_error","param":\(quoted(param)),\
            "code":\(quoted(code))}}
            """, status: status)
    }
}

/// **An OpenAI-compatible endpoint that exists only in this process**, at a host of its own — so tests running in
/// parallel never answer each other's requests, and no request can leave the Mac: a host this stub does not know is
/// refused by it rather than passed to the network. Hand `configuration()` to the provider under test.
final class StubEndpoint: Sendable {
    let host: String
    private let answer: @Sendable (HeardRequest, Int) -> StubAnswer
    private let heard = Mutex<[HeardRequest]>([])

    /// `answer` is given each request and how many came before it. `host` is one of the stub's own unless a test needs
    /// an address read a particular way — one on the local network, say — and then it must be that test's alone, or
    /// tests running in parallel answer each other's requests.
    init(host: String = "stub-\(UUID().uuidString.lowercased()).example.test",
         _ answer: @escaping @Sendable (HeardRequest, Int) -> StubAnswer) {
        self.host = host
        self.answer = answer
        StubURLProtocol.register(self)
    }

    /// The same answer to every request.
    convenience init(always answer: StubAnswer) {
        self.init { _, _ in answer }
    }

    deinit { StubURLProtocol.unregister(host) }

    var baseURL: URL { URL(string: "https://\(host)/v1").unsafelyUnwrapped }
    var requests: [HeardRequest] { heard.withLock { $0 } }

    fileprivate func respond(to request: HeardRequest) -> StubAnswer {
        let earlier = heard.withLock { heard in
            heard.append(request)
            return heard.count - 1
        }
        return answer(request, earlier)
    }

    /// A session configuration whose only route is through the stub. Ephemeral, as the provider's own is.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }
}

/// The loading-system half of `StubEndpoint`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let endpoints = Mutex<[String: StubEndpoint]>([:])

    static func register(_ endpoint: StubEndpoint) {
        endpoints.withLock { $0[endpoint.host] = endpoint }
    }

    static func unregister(_ host: String) {
        _ = endpoints.withLock { $0.removeValue(forKey: host) }
    }

    /// Every request is claimed — one for a host no test registered is failed here, never sent.
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
              let endpoint = Self.endpoints.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let heard = HeardRequest(method: request.httpMethod ?? "GET", url: url,
                                 headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        switch endpoint.respond(to: heard) {
        case .respond(let status, let headers, let body):
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                 headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .hang:
            break
        }
    }

    override func stopLoading() {}

    /// A request's body reaches a protocol as a stream, not as `httpBody`, once `URLSession` has it.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}
