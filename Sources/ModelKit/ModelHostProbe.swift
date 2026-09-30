import Foundation

/// **Which host to ask, decided by asking both.** A reader cannot be expected to know whether
/// Hugging Face is reachable from where they are, and the answer changes when a VPN goes up or
/// down — so the program measures it instead of putting the question on a settings pane.
///
/// Measured 2026-09-30 from one Mac: ModelScope 0.38–0.71 MB/s, Hugging Face 13.8 MB/s. The same
/// probe from mainland China finds Hugging Face unreachable and answers ModelScope, which is why
/// this is safe as a default rather than a preference only the informed would find.
public protocol ModelHostProbe: Sendable {
    /// What each candidate delivered. **Measuring is all a probe does** — ranking is arithmetic
    /// on the answer, and saying what was measured belongs to whoever owns a log.
    func measure(_ file: ModelFile, among candidates: [ModelHost]) async -> [ModelHostSpeed]
}

extension ModelHostProbe {
    /// The hosts in the order they should be tried, best first. **Never empty**, and never
    /// without the canonical host, so a probe that learns nothing still yields a usable download.
    public func order(for file: ModelFile, among candidates: [ModelHost]) async -> [ModelHost] {
        ModelHost.ranked(await measure(file, among: candidates))
    }
}

extension ModelHost {
    /// **A host that delivered nothing has not been measured, it has failed.** Ranking it as
    /// "slowest" would still place it ahead of nothing; dropping it is what makes an unreachable
    /// host cost a measurement rather than a download. The canonical host is always last if it
    /// is not already somewhere, because it has every file.
    public static func ranked(_ measured: [ModelHostSpeed]) -> [ModelHost] {
        let ordered = measured.filter { $0.bytes > 0 }
            .sorted { ($0.bytes, $0.host == .modelScope ? 1 : 0) > ($1.bytes, $1.host == .modelScope ? 1 : 0) }
            .map(\.host)
        return ordered.contains(.modelScope) ? ordered : ordered + [.modelScope]
    }
}

/// What a probe measured, per host — bytes delivered inside the deadline.
public struct ModelHostSpeed: Sendable, Equatable {
    public let host: ModelHost
    public let bytes: Int
    public init(host: ModelHost, bytes: Int) {
        self.host = host
        self.bytes = bytes
    }
}

/// Reads the front of a real file from each candidate at the same moment and prefers whichever
/// delivered more.
///
/// **Bytes delivered inside a fixed window, not time to complete.** A cap both hosts can reach
/// makes them tie however different they are, and latency then decides — which is the wrong
/// question for a file measured in gigabytes.
public struct URLSessionModelHostProbe: ModelHostProbe {
    /// How long each host is given.
    ///
    /// **Long enough to out-last the handshake, because what matters is the sustained rate.**
    /// Measured 2026-09-30 on one Mac, bytes delivered inside the window:
    ///
    /// | window | ModelScope | Hugging Face |
    /// |---|---|---|
    /// | 1.5 s | 392 KB | **0** |
    /// | 3 s | 2.5 MB | 0.9 MB |
    /// | 5 s | 3.9 MB | **13.5 MB** |
    ///
    /// Hugging Face pays 0.8–2.8 s before its first byte — a VPN and a CDN redirect — and then
    /// outruns ModelScope several times over. A short window measures that handshake and answers
    /// the wrong host: at 1.5 s it chose the mirror that would have taken four hours over the one
    /// that takes seven minutes. Five seconds is paid once, against a download measured in hours.
    public static let window = Duration.seconds(5)

    /// The most that will be read from either host. **A stop, not a target**, and deliberately
    /// far above what a fast link delivers inside the window: a ceiling either host can reach
    /// makes them tie however different they are. Nothing is kept — the bytes are counted and
    /// dropped — so this bounds the transfer rather than memory.
    public static let ceiling = 256 * 1_048_576

    private let window: Duration
    private let ceiling: Int

    public init(window: Duration = URLSessionModelHostProbe.window,
                ceiling: Int = URLSessionModelHostProbe.ceiling) {
        self.window = window
        self.ceiling = ceiling
    }

    public func measure(_ file: ModelFile, among candidates: [ModelHost]) async -> [ModelHostSpeed] {
        let usable = candidates.filter { file.isServed(by: $0) }
        guard usable.count > 1 else {
            // Nothing to choose between: measuring would cost the window and decide nothing.
            return usable.map { ModelHostSpeed(host: $0, bytes: 1) }
        }
        // **Both at once, so they are measured under the same conditions.** Run in turn, the
        // second is measured on a link the first has just warmed and a network that may have
        // moved; run together they compete for the same bandwidth, which lowers both numbers
        // equally and leaves the comparison fair. What is wanted is the ratio, not the rate.
        var measured: [ModelHostSpeed] = []
        await withTaskGroup(of: ModelHostSpeed.self) { group in
            for host in usable {
                group.addTask { [window, ceiling] in
                    ModelHostSpeed(
                        host: host,
                        bytes: await Self.bytes(of: file, from: host, within: window, upTo: ceiling))
                }
            }
            for await speed in group { measured.append(speed) }
        }
        return measured
    }

    /// Bytes this host delivered inside the window. **Never written to disk** — the staged file
    /// belongs to the download, and a probe sharing it could truncate a prefix worth hours.
    static func bytes(of file: ModelFile, from host: ModelHost,
                      within window: Duration, upTo ceiling: Int) async -> Int {
        var request = URLRequest(url: file.url(from: host))
        request.setValue("bytes=0-\(ceiling - 1)", forHTTPHeaderField: "Range")
        // Its own short timeouts, so a host that accepts a connection and says nothing cannot
        // hold the probe past its window by any route.
        let seconds = Double(window.components.seconds)
            + Double(window.components.attoseconds) / 1e18
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = seconds + 1
        configuration.timeoutIntervalForResource = seconds + 1
        configuration.waitsForConnectivity = false

        // **Counted per chunk, through a delegate — never by iterating `AsyncBytes`.** A
        // `for await` over the body suspends once per *byte*, so the first version of this
        // measured the cost of its own loop and not the link: it answered ModelScope on a Mac
        // where Hugging Face was twenty times faster, because neither host could out-run the
        // suspensions. The same reason `RangeWriter` is a delegate.
        let counter = ByteCounter(ceiling: ceiling)
        let session = URLSession(configuration: configuration, delegate: counter,
                                 delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        task.resume()
        try? await Task.sleep(for: window)
        // **Cancelled, then read.** The count lives on the delegate rather than in the task, so
        // stopping the transfer does not discard what it had already delivered.
        task.cancel()
        return counter.count
    }

    /// Counts a response body as it arrives, and only for a status that means the host will
    /// actually serve this file: a fast error page is not throughput.
    private final class ByteCounter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var received = 0
        private var accepted = false
        private let ceiling: Int

        init(ceiling: Int) { self.ceiling = ceiling }

        var count: Int { lock.withLock { accepted ? received : 0 } }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 || status == 206 else {
                completionHandler(.cancel)
                return
            }
            lock.withLock { accepted = true }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let full = lock.withLock {
                received = min(received + data.count, ceiling)
                return received >= ceiling
            }
            if full { dataTask.cancel() }
        }
    }

}
