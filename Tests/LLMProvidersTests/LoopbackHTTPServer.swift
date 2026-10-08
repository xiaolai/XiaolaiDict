import Darwin
import Foundation
import Synchronization

/// **An HTTP/1.1 server on 127.0.0.1, on real sockets, in this test process** — the wire a `URLProtocol` stub
/// cannot show: whether a connection is kept and reused, what the request line and headers really are once the
/// loading system has written them, and where a redirect actually goes.
///
/// BSD sockets rather than Network.framework because each connection is then one thread reading one request at a
/// time, which is all a test needs and leaves nothing to schedule. Bound to `127.0.0.1` only, so nothing off this
/// Mac can reach it and the firewall is never asked. It speaks just enough HTTP for one client: a request line,
/// headers, a `Content-Length` body, and a response with a `Content-Length`, the connection kept open after it.
final class LoopbackHTTPServer: Sendable {
    struct Request: Sendable {
        let method: String
        /// The request target as sent on the request line: `/v1/chat/completions`.
        let target: String
        /// Header names lowercased, as HTTP compares them.
        let headers: [String: String]
        let body: Data
        /// Which accepted connection carried it, counted from 1.
        let connection: Int

        var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data

        static func json(_ text: String, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
        }

        static func completion(_ content: String) -> Response {
            let encoded = String(decoding: (try? JSONEncoder().encode(content)) ?? Data("\"\"".utf8), as: UTF8.self)
            return .json(#"{"choices":[{"index":0,"message":{"role":"assistant","content":\#(encoded)},"finish_reason":"stop"}]}"#)
        }

        static func redirect(to location: String, status: Int = 307) -> Response {
            Response(status: status, headers: ["Location": location], body: Data())
        }
    }

    enum Reply: Sendable {
        case respond(Response)
        /// Read the request and never answer it.
        case hang
    }

    struct Failed: Error, CustomStringConvertible {
        let call: String
        let code: Int32
        var description: String { "\(call) failed: \(String(cString: strerror(code)))" }
    }

    let port: UInt16
    private let core: Core

    /// Listens on an ephemeral port of 127.0.0.1; `handler` answers each request.
    init(_ handler: @escaping @Sendable (Request) -> Reply) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failed(call: "socket", code: errno) }
        var one: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(listener)
            throw Failed(call: "bind", code: code)
        }
        guard listen(listener, 16) == 0 else {
            let code = errno
            close(listener)
            throw Failed(call: "listen", code: code)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard named == 0 else {
            let code = errno
            close(listener)
            throw Failed(call: "getsockname", code: code)
        }
        port = UInt16(bigEndian: address.sin_port)
        core = Core(listener: listener, handler: handler)
        let core = core
        Thread { core.acceptLoop() }.start()
    }

    deinit { core.stop() }

    /// A port of 127.0.0.1 that was free a moment ago and has nothing listening on it now: bound, then closed
    /// before this returns — so a connection to it is refused, which is what "unreachable" looks like on the wire.
    static func unusedPort() throws -> UInt16 {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        guard probe >= 0 else { throw Failed(call: "socket", code: errno) }
        defer { close(probe) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                guard bind(probe, pointer, length) == 0 else { return -1 }
                return getsockname(probe, pointer, &length)
            }
        }
        guard named == 0 else { throw Failed(call: "bind", code: errno) }
        return UInt16(bigEndian: address.sin_port)
    }

    /// `http://127.0.0.1:<port><path>`.
    func url(_ path: String = "") -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)").unsafelyUnwrapped
    }

    var acceptedConnections: Int { core.state.withLock { $0.accepted } }
    var requests: [Request] { core.state.withLock { $0.requests } }

    /// Stops listening and ends every connection. The threads see it within one poll interval.
    func stop() { core.stop() }

    /// What the threads share. Its own object, so the threads hold it and not the server — whose `deinit` stops them.
    private final class Core: Sendable {
        struct State {
            var accepted = 0
            var requests: [Request] = []
            var stopped = false
        }

        let listener: Int32
        let handler: @Sendable (Request) -> Reply
        let state = Mutex(State())

        /// How long a thread waits before looking at `stopped` again.
        static let pollMilliseconds: Int32 = 50
        /// A request larger than this is not one this server was written for.
        static let largestRequest = 1 << 20

        init(listener: Int32, handler: @escaping @Sendable (Request) -> Reply) {
            self.listener = listener
            self.handler = handler
        }

        var stopped: Bool { state.withLock { $0.stopped } }

        /// Each loop closes its own descriptor once it sees this, so no thread is ever left polling a descriptor
        /// number another socket may already have been given.
        func stop() {
            state.withLock { $0.stopped = true }
        }

        func acceptLoop() {
            defer { close(listener) }
            while !stopped {
                guard Self.wait(for: listener) else { continue }
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { continue }
                var one: Int32 = 1
                // A write to a client that has gone must fail, not raise SIGPIPE and end the test process.
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                let number = state.withLock { state -> Int in
                    state.accepted += 1
                    return state.accepted
                }
                Thread { [self] in self.serve(connection, number: number) }.start()
            }
        }

        /// Whether `descriptor` is readable within one poll interval.
        static func wait(for descriptor: Int32) -> Bool {
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            return poll(&request, 1, pollMilliseconds) > 0
        }

        /// One connection: request after request until the client closes it or the server stops.
        func serve(_ connection: Int32, number: Int) {
            defer { close(connection) }
            var buffer = Data()
            while !stopped {
                guard let request = read(from: connection, into: &buffer, number: number) else { return }
                state.withLock { $0.requests.append(request) }
                switch handler(request) {
                case .respond(let response):
                    guard write(response, to: connection) else { return }
                case .hang:
                    // Wait for the client to give up — it closes the connection — or for the server to stop.
                    var scratch = [UInt8](repeating: 0, count: 512)
                    while !stopped {
                        guard Self.wait(for: connection) else { continue }
                        if recv(connection, &scratch, scratch.count, 0) <= 0 { return }
                    }
                    return
                }
            }
        }

        /// The next request on `connection`, reading more into `buffer` as needed; nil when the client closed it,
        /// the server stopped, or what arrived is not a request this server can read.
        func read(from connection: Int32, into buffer: inout Data, number: Int) -> Request? {
            let separator = Data("\r\n\r\n".utf8)
            while true {
                if let end = buffer.range(of: separator) {
                    let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                    var lines = head.components(separatedBy: "\r\n")
                    let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
                    guard requestLine.count == 3 else { return nil }
                    var headers: [String: String] = [:]
                    for line in lines {
                        guard let colon = line.firstIndex(of: ":") else { return nil }
                        let name = line[..<colon].lowercased()
                        headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    }
                    let length = Int(headers["content-length"] ?? "0") ?? 0
                    let bodyStart = end.upperBound
                    while buffer.distance(from: bodyStart, to: buffer.endIndex) < length {
                        guard fill(&buffer, from: connection) else { return nil }
                    }
                    let bodyEnd = buffer.index(bodyStart, offsetBy: length)
                    let body = Data(buffer[bodyStart..<bodyEnd])
                    buffer = Data(buffer[bodyEnd...])
                    return Request(method: requestLine[0], target: requestLine[1], headers: headers, body: body,
                                   connection: number)
                }
                guard buffer.count < Self.largestRequest, fill(&buffer, from: connection) else { return nil }
            }
        }

        /// Reads what has arrived into `buffer`; false when the client closed the connection or the server stopped.
        func fill(_ buffer: inout Data, from connection: Int32) -> Bool {
            var chunk = [UInt8](repeating: 0, count: 16_384)
            while !stopped {
                guard Self.wait(for: connection) else { continue }
                let count = recv(connection, &chunk, chunk.count, 0)
                guard count > 0 else { return false }
                buffer.append(chunk, count: count)
                return true
            }
            return false
        }

        func write(_ response: Response, to connection: Int32) -> Bool {
            var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
            for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
            head += "Content-Length: \(response.body.count)\r\nConnection: keep-alive\r\n\r\n"
            var bytes = Data(head.utf8)
            bytes.append(response.body)
            return bytes.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let sent = send(connection, raw.baseAddress.unsafelyUnwrapped + offset, raw.count - offset, 0)
                    guard sent > 0 else { return false }
                    offset += sent
                }
                return true
            }
        }

        static func reason(_ status: Int) -> String {
            switch status {
            case 200: "OK"
            case 307: "Temporary Redirect"
            case 308: "Permanent Redirect"
            case 400: "Bad Request"
            case 401: "Unauthorized"
            default: "Status"
            }
        }
    }
}
