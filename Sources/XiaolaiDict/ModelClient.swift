import Darwin
import Foundation
import XiaolaiDictCore

/// One conversation with the model service — the seam tests replace.
protocol ModelTransport: Sendable {
    func send(_ request: ModelRequest) async throws -> ModelReply
    func cancel(reason: String)
}

/// Talks to the bundled model service.
///
/// **Nil means the service could not be reached** — not running, crashed, or past its deadline —
/// and callers read nil exactly as they read "not installed": the model is not here, and the next
/// engine answers. A crashed service is dropped and a fresh session opened next time; launchd
/// relaunches the service on demand, and it ends itself when idle, which is how the model unloads.
actor ModelClient {
    typealias Connect = @Sendable (_ onCancel: @escaping @Sendable () -> Void) throws -> any ModelTransport

    /// How long each kind of question may take. A sense answer measured 0.24–0.44 s warm and 1.6–
    /// 2.5 s cold on an M4 Max, and a base chip is estimated at a quarter of its GPU: the deadline is
    /// set well past a cold answer on a slow Mac, because the mark fills in when it arrives and
    /// giving up early only hands the sentence to a weaker rung.
    static func deadline(for request: ModelRequest) -> Duration {
        switch request {
        case .pickSense: .seconds(12)
        case .translate: .seconds(30)
        // Prose rather than a number, and a slow Mac writes it a token at a time.
        case .explain: .seconds(45)
        case .prewarm: .seconds(60)
        case .status: .seconds(10)
        // Longer than the service's own drain, because unloading *is* that wait: bounded shorter,
        // a service doing exactly what it was asked times out and reads as one that failed.
        case .unload: ModelShutdown.ask
        }
    }

    /// How long to wait for the service's process to go after it says it is unloading. A test
    /// hands in a shorter one; nothing else does.
    let shutdownLimit: Duration

    private let connect: Connect
    private let serviceIsRunning: @Sendable () -> Bool
    private var sessions = ServiceSessions<any ModelTransport>()
    /// The session that has been prewarmed, so a prewarm is sent once per service process rather
    /// than once per lookup.
    private var warmed: Int?
    /// An unload in flight. Nothing is asked while it runs: the point of unloading is that what is
    /// asked next reaches a *new* process, not the one on its way out.
    private var unloading: Task<Bool, Never>?

    init(
        connect: @escaping Connect = { onCancel in
            try XPCServiceTransport<ModelRequest, ModelReply>(
                service: XiaolaiDictIdentity.modelService, onCancel: onCancel)
        },
        serviceIsRunning: @escaping @Sendable () -> Bool = { ModelServiceProcess.isRunning },
        shutdownLimit: Duration = ModelShutdown.processExit
    ) {
        self.connect = connect
        self.serviceIsRunning = serviceIsRunning
        self.shutdownLimit = shutdownLimit
    }

    deinit {
        sessions.current?.transport.cancel(reason: "model client released")
    }

    func ask(_ request: ModelRequest) async -> ModelReply? {
        // An unload can take as long as the service's drain. A caller that gave up while waiting is
        // not then given a session: it would be opened for an answer nobody is waiting for, which
        // on a launch-on-demand service means starting one.
        if let unloading { _ = await unloading.value }
        guard !Task.isCancelled, let current = try? openSession() else { return nil }
        do {
            return try await withDeadline(Self.deadline(for: request)) {
                try await current.transport.send(request)
            }
        } catch is CancellationError where Task.isCancelled {
            // **The caller was superseded, not the service.** Dropping the session here would cancel
            // whatever else is in flight on it — a prewarm, another lookup — for a lookup nobody is
            // waiting on any more. The session is healthy and stays.
            //
            // Asked of the *thrown error*, never of `Task.isCancelled`: a transport failure or a
            // deadline that lands in the same moment the caller gives up would otherwise be read as
            // this harmless case, and a wedged session would be kept for every question after it.
            return nil
        } catch {
            // Crashed, hung or refused. The next question opens a fresh session.
            drop(current, reason: "model request failed: \(error)")
            return nil
        }
    }

    /// Ends the service, and **waits until its process has gone**. Answering "unloading" is not the
    /// same as having unloaded: the service replies first and exits a moment later, so a question
    /// asked in between would reach the process on its way out — with the weights the caller is
    /// replacing. Says whether the process was seen to go.
    @discardableResult
    func unload() async -> Bool {
        if let unloading { return await unloading.value }
        let isRunning = serviceIsRunning
        // **Asked of the process, before a session is opened.** The service is launch-on-demand, so
        // opening one starts a service that was not running — which would load nothing, be asked to
        // unload, and count as having ended something that never existed.
        guard isRunning() else { return true }
        // A connection that could not be made says nothing about the process; the process does.
        guard let current = try? openSession() else { return !isRunning() }
        let work = Task { () -> Bool in
            // The reply is not what decides — the process is — so it is not kept. What asking
            // buys is the service stopping cleanly rather than being outlived.
            _ = try? await withDeadline(Self.deadline(for: .unload), {
                try await current.transport.send(.unload)
            })
            // **Cancelled the moment the reply is in hand**, because that cancellation is what tells
            // the service its answer arrived — waiting first would leave it counting out its own
            // deadline instead.
            drop(current, reason: "the service was asked to unload")
            // **The process decides, whatever was said.** A request that timed out or failed on the
            // way may still have reached a service that is draining and about to go; waiting only
            // on the word "unloading" reported those as still holding the old weights.
            let deadline = ContinuousClock.now.advanced(by: shutdownLimit)
            while isRunning(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            return !isRunning()
        }
        unloading = work
        let gone = await work.value
        unloading = nil
        return gone
    }

    /// Loads the model ahead of the question that needs it — once per service process. The first
    /// answer measured 1.6–2.5 s cold against 0.24–0.44 s warm.
    func prewarmOnce() async {
        // **After any unload, never through one.** Opening a session here while the service is on
        // its way out starts the next one early — which makes the unload it is racing look as
        // though it timed out, and records a prewarm against a generation that is already gone.
        if let unloading { _ = await unloading.value }
        guard !Task.isCancelled, let current = try? openSession(), warmed != current.generation
        else { return }
        warmed = current.generation
        if case .prewarmed? = await ask(.prewarm) { return }
        // It did not take: let the next lookup try again.
        if warmed == current.generation { warmed = nil }
    }

    private func openSession() throws -> ServiceSessions<any ModelTransport>.Open {
        try sessions.open { mine in
            try connect { [weak self] in
                Task { await self?.forget(generation: mine) }
            }
        }
    }

    /// Cancels the session before forgetting it — a session released uncancelled traps in libxpc —
    /// and forgets it only if it is still the current one.
    private func drop(_ failed: ServiceSessions<any ModelTransport>.Open, reason: String) {
        failed.transport.cancel(reason: reason)
        forget(generation: failed.generation)
    }

    private func forget(generation dead: Int) {
        guard sessions.forget(generation: dead) else { return }
        if warmed == dead { warmed = nil }
    }

    /// For tests: which session is open, nil when none is.
    var openSessionGeneration: Int? { sessions.current?.generation }
}

/// The model service as the rest of the app uses it: **nothing is asked of a service that has no
/// model to answer with.** Every lookup would otherwise start a process only to hear "not
/// installed"; the store answers that from a few file sizes, in-process.
struct LocalModelAccess: Sendable {
    let client: ModelClient
    let store: ModelStore

    var isInstalled: Bool { !store.installedSizes().isEmpty }

    func ask(_ request: ModelRequest) async -> ModelReply? {
        guard isInstalled else { return .failure(.notInstalled) }
        return await client.ask(request)
    }

    func prewarm() async {
        guard isInstalled else { return }
        await client.prewarmOnce()
    }

    /// The top rung of the sense ladder.
    var senseSelector: LocalModelSenseSelector {
        LocalModelSenseSelector { question in await ask(.pickSense(question)) }
    }

    /// **The shipped ladder, in one place.** `--sense-report` measures this very value, so the
    /// measurement cannot drift from what readers get.
    var senseLadder: (ladder: LadderSenseSelector, rungs: [(name: String, selector: any SenseSelecting)]) {
        let rungs: [(name: String, selector: any SenseSelecting)] = [
            ("localModel", senseSelector),
            ("onDevice", FoundationModelsSenseSelector()),
            ("embedding", EmbeddingSenseSelector()),
        ]
        return (LadderSenseSelector(rungs: rungs.map(\.selector)), rungs)
    }

    /// The sentence pane's engines: this model first, Apple's on-device model where it is not here.
    var explainer: LadderSentenceExplainer {
        LadderSentenceExplainer(local: { question in await ask(.explain(question)) })
    }

    /// The translation pane's engines: this model first, Apple's framework where it is not here.
    var translator: SentenceTranslator {
        SentenceTranslator(
            local: { question in await ask(.translate(question)) },
            apple: { sentence, source, target in await AppleTranslation.translate(sentence, from: source, to: target) })
    }
}

/// The embedded model service's own process, found the way `build-bundle.sh` finds its processes:
/// by the exact executable path, never by name.
enum ModelServiceProcess {
    /// The service's executable inside this bundle, or nil outside one (`swift run`).
    static let executable: String? = Bundle(
        url: Bundle.main.bundleURL.appending(path: "Contents/XPCServices/XiaolaiDictModelService.xpc")
    )?.executableURL?.path

    static var isRunning: Bool {
        guard let executable else { return false }
        return isRunning(executable)
    }

    static func isRunning(_ executable: String) -> Bool {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return false }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(found)) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            if String(decoding: bytes, as: UTF8.self) == executable { return true }
        }
        return false
    }
}
