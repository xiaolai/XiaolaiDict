import XiaolaiDictCore


/// One conversation with the dictionary service — the seam tests replace. The real one is an XPC
/// session; `DictionaryClient` owns the policy around it.
protocol DictionaryTransport: Sendable {
    func send(_ request: ServiceRequest) async throws -> ServiceReply
    func cancel(reason: String)
}

/// Talks to the bundled dictionary service, and falls back to the public API when it cannot.
actor DictionaryClient {
    /// Opens a transport. `onCancel` is called when the transport dies on its own — the service
    /// crashed — so the client can open a fresh one next time.
    typealias Connect = @Sendable (_ onCancel: @escaping @Sendable () -> Void) throws -> any DictionaryTransport

    /// A healthy lookup takes tens of milliseconds. A service that is hung — a private API that
    /// deadlocked rather than crashed — must not hold the panel open.
    static let defaultDeadline: Duration = .seconds(3)

    private let deadline: Duration
    private let connect: Connect
    private let fallback: @Sendable (String) -> String?
    private var sessions = ServiceSessions<any DictionaryTransport>()

    init(
        deadline: Duration = defaultDeadline,
        connect: @escaping Connect = { onCancel in
            try XPCServiceTransport<ServiceRequest, ServiceReply>(
                service: XiaolaiDictIdentity.dictionaryService, onCancel: onCancel)
        },
        fallback: @escaping @Sendable (String) -> String? = PublicDictionary.definition(of:)
    ) {
        self.deadline = deadline
        self.connect = connect
        self.fallback = fallback
    }

    /// libxpc traps (`_xpc_api_misuse`) when a session is released without being cancelled first —
    /// found when `--lookup` let its client go and crashed on the way out.
    deinit {
        sessions.current?.transport.cancel(reason: "dictionary client released")
    }

    /// Throws only when the caller is cancelled — a newer lookup replaced this one — which says
    /// nothing about the service, so its session is kept.
    func lookup(_ term: String) async throws(CancellationError) -> LookupOutcome {
        let failure: String
        do {
            switch try await ask(term) {
            case .entries(let entries, let unreadable): return .entries(entries, unreadable: unreadable)
            case .notFound: return .notFound(serviceFailure: nil)
            case .failure(let reason): failure = reason.description
            }
        } catch {
            switch error {
            case .cancelled: throw CancellationError()
            case .unreachable(let why): failure = why
            }
        }
        if let text = fallback(term) { return .plainText(text, serviceFailure: failure) }
        return .notFound(serviceFailure: failure)
    }

    private enum AskError: Error {
        case cancelled
        case unreachable(String)
    }

    /// Which dictionaries are enabled, and what each can key a study item to.
    ///
    /// Nil when the service could not answer: the menu then says it does not know, rather than
    /// offering a list that is missing whatever the service would have added.
    func dictionaries(reprobing: Bool = false) async -> [DictionaryCapability]? {
        guard case .dictionaries(let found)? = try? await ask(.dictionaries(reprobing: reprobing))
        else { return nil }
        return found
    }

    private func ask(_ term: String) async throws(AskError) -> LookupReply {
        guard case .lookup(let reply) = try await ask(.lookup(LookupRequest(term: term))) else {
            throw .unreachable("the dictionary service answered a lookup with something else")
        }
        return reply
    }

    private func ask(_ request: ServiceRequest) async throws(AskError) -> ServiceReply {
        let session: ServiceSessions<any DictionaryTransport>.Open
        do {
            session = try currentSession()
        } catch {
            throw .unreachable("dictionary service could not be reached: \(error)")
        }
        do {
            return try await withDeadline(deadline) { try await session.transport.send(request) }
        } catch where Task.isCancelled {
            throw .cancelled
        } catch {
            // Crashed, hung or refused. Drop the session: the next lookup opens a fresh one, and
            // launchd relaunches a crashed service on demand.
            drop(session, reason: "lookup failed: \(error)")
            throw .unreachable("dictionary service: \(error)")
        }
    }

    private func currentSession() throws -> ServiceSessions<any DictionaryTransport>.Open {
        // Dropped the moment the service dies, so the next lookup opens a fresh session and launchd
        // relaunches the service. Kept until the next send, a dead session made the first lookup
        // after any crash fall back to plain text needlessly — measured, before this handler.
        try sessions.open { mine in
            try connect { [weak self] in
                Task { await self?.forget(generation: mine) }
            }
        }
    }

    /// Cancels the session the failed request used — which may no longer be the current one — and
    /// forgets it only if it still is.
    private func drop(_ failed: ServiceSessions<any DictionaryTransport>.Open, reason: String) {
        failed.transport.cancel(reason: reason)
        forget(generation: failed.generation)
    }

    private func forget(generation dead: Int) {
        sessions.forget(generation: dead)
    }

    /// For tests: which session is open, nil when none is.
    var openSessionGeneration: Int? { sessions.current?.generation }
}
