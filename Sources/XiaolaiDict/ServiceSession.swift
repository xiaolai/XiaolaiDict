import DictionaryModel
import ModelKit
import XiaolaiDictCore
import XPC

/// One XPC service's session, as both clients keep it: opened on demand, numbered, and forgotten
/// when the service dies — but only if it is still the current one, because a failure reported late
/// must not drop a newer session. Letting a session go is the client's job, and it **cancels before
/// it forgets**: libxpc traps (`_xpc_api_misuse`) on a session released uncancelled, which is how
/// `--lookup` once crashed on its way out.
///
/// Shared because the two clients had each kept their own copy, and the copies had drifted: the
/// model client's handled a caller's cancellation as a dead service.
struct ServiceSessions<Transport: Sendable> {
    struct Open {
        let transport: Transport
        /// Which session this is, so a death reported late can be matched to the one that died.
        let generation: Int
    }

    private(set) var current: Open?
    private var generation = 0

    /// The open session, or a new one from `connect` — which is handed the new session's generation,
    /// for the callback that reports its death.
    mutating func open(_ connect: (Int) throws -> Transport) rethrows -> Open {
        if let current { return current }
        generation += 1
        let fresh = Open(transport: try connect(generation), generation: generation)
        current = fresh
        return fresh
    }

    /// Forgets session `dead` if it is still the current one; says whether it was.
    @discardableResult
    mutating func forget(generation dead: Int) -> Bool {
        guard current?.generation == dead else { return false }
        current = nil
        return true
    }
}

/// The real transport, for either service: a typed XPC session to a service embedded in the bundle.
struct XPCServiceTransport<Request: Encodable & Sendable, Reply: Decodable & Sendable>: Sendable {
    let session: XPCSession

    /// `onCancel` runs when the session ends on its own — the service crashed or exited — so the
    /// client opens a fresh one next time and launchd relaunches the service.
    init(service: String, onCancel: @escaping @Sendable () -> Void) throws {
        session = try XPCSession(xpcService: service, cancellationHandler: { _ in onCancel() })
    }

    func send(_ request: Request) async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try session.send(request) { (result: Result<Reply, any Error>) in
                    continuation.resume(with: result)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel(reason: String) {
        session.cancel(reason: reason)
    }
}

extension XPCServiceTransport: DictionaryTransport where Request == ServiceRequest, Reply == ServiceReply {}
extension XPCServiceTransport: ModelTransport where Request == ModelRequest, Reply == ModelReply {}
