import Dispatch

/// Bounds synchronous work that nothing can interrupt. When `work` overruns `limit`, `onExpiry`
/// runs — from another thread, while the work is still stuck.
///
/// The dictionary service uses it on the private DictionaryServices call. A deadlock there leaves
/// the service alive but useless: every later request would queue behind the stuck one and time
/// out in the app. Exiting instead lets launchd start a clean process on the next request.
public struct Watchdog: Sendable {
    public let limit: Duration
    private let onExpiry: @Sendable () -> Void

    public init(limit: Duration, onExpiry: @escaping @Sendable () -> Void) {
        self.limit = limit
        self.onExpiry = onExpiry
    }

    public func run<T>(_ work: () throws -> T) rethrows -> T {
        let alarm = DispatchWorkItem(block: onExpiry)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit.timeInterval, execute: alarm)
        defer { alarm.cancel() }
        return try work()
    }
}

private extension Duration {
    var timeInterval: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
