import Foundation

/// **Which host to ask, decided by asking both.** A reader cannot be expected to know whether
/// Hugging Face is reachable from where they are, and the answer changes when a VPN goes up or
/// down — so the program measures it instead of putting the question on a settings pane.
///
/// Measured 2026-09-30 from one Mac: ModelScope 0.38–0.71 MB/s, Hugging Face 13.8 MB/s. The same
/// probe from mainland China finds Hugging Face unreachable and answers ModelScope, which is why
/// this is safe as a default rather than a preference only the informed would find.
public protocol ModelHostProbe: Sendable {
    /// The hosts in the order they should be tried, best first. **Never empty**, and never
    /// without the canonical host, so a probe that learns nothing still yields a usable download.
    func order(for file: ModelFile, among candidates: [ModelHost]) async -> [ModelHost]
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
    /// How long each host is given. Short: this is paid before every download, and a host that
    /// has not sent anything in this long is not the one to spend two hours with.
    public static let window = Duration.milliseconds(1_500)

    /// The most that will be read from either host. A ceiling on memory, not a target — reaching
    /// it early is what winning looks like.
    public static let ceiling = 4 * 1_048_576

    private let window: Duration
    private let ceiling: Int

    public init(window: Duration = URLSessionModelHostProbe.window,
                ceiling: Int = URLSessionModelHostProbe.ceiling) {
        self.window = window
        self.ceiling = ceiling
    }

    public func order(for file: ModelFile, among candidates: [ModelHost]) async -> [ModelHost] {
        let usable = candidates.filter { file.isServed(by: $0) }
        guard usable.count > 1 else { return Self.completing(usable) }
        var measured: [ModelHostSpeed] = []
        // `async let` rather than a task group: cancellation propagates, and each measurement is
        // independent, so the slower host does not hold the faster one's answer.
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
        // **A host that delivered nothing has not been measured, it has failed.** Ranking it as
        // "slowest" would still put it in the order ahead of nothing; dropping it is what makes
        // an unreachable Hugging Face cost 1.5 seconds and not a download.
        let ranked = measured.filter { $0.bytes > 0 }
            .sorted { ($0.bytes, $0.host == .modelScope ? 1 : 0) > ($1.bytes, $1.host == .modelScope ? 1 : 0) }
            .map(\.host)
        return Self.completing(ranked)
    }

    /// The canonical host is always last if it is not already somewhere: every file has its bytes,
    /// and a probe that failed on every host must still hand back a download that can be tried.
    static func completing(_ hosts: [ModelHost]) -> [ModelHost] {
        hosts.contains(.modelScope) ? hosts : hosts + [.modelScope]
    }

    /// Bytes this host delivered inside the window. **Never written to disk** — the staged file
    /// belongs to the download, and a probe sharing it could truncate a prefix worth hours.
    static func bytes(of file: ModelFile, from host: ModelHost,
                      within window: Duration, upTo ceiling: Int) async -> Int {
        var request = URLRequest(url: file.url(from: host))
        request.setValue("bytes=0-\(ceiling - 1)", forHTTPHeaderField: "Range")
        // Its own short timeouts, so a host that accepts a connection and says nothing cannot
        // hold the probe past its window by any route.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Double(window.components.seconds) + 1
        configuration.timeoutIntervalForResource = Double(window.components.seconds) + 1
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let counted = Counter()
        let work = Task {
            let (bytes, response) = try await session.bytes(for: request)
            // **An error page is not throughput.** Counting raw bytes would rank a fast 403 as
            // the winner; only a success says the host will serve this file at all.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 || status == 206 else { return }
            var seen = 0
            for try await _ in bytes {
                seen += 1
                if seen % 65_536 == 0 { await counted.set(seen) }
                if seen >= ceiling { break }
            }
            await counted.set(seen)
        }
        // **The deadline cancels and waits.** Letting a timer win a race leaves the request
        // running, and `invalidateAndCancel` then races the task rather than following it.
        let deadline = Task {
            try? await Task.sleep(for: window)
            work.cancel()
        }
        _ = try? await work.value
        deadline.cancel()
        return await counted.value
    }

    /// What the probe has counted so far, readable after cancellation.
    private actor Counter {
        private(set) var value = 0
        func set(_ seen: Int) { value = max(value, seen) }
    }
}
