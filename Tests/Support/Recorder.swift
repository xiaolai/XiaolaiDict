import Foundation

/// A value tests record into from `@Sendable` closures, and pass around by reference.
///
/// `Mutex` would do the locking, but it is noncopyable: it cannot be a defaulted parameter or be
/// handed to a helper that builds the closure under test, which is exactly how these tests are
/// written. A class holding a lock can.
public final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
