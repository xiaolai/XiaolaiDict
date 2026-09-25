import ModelKit
import Synchronization
import Darwin
import Foundation
import XiaolaiDictBase
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
    private let servicePresence: @Sendable () -> ModelServiceProcess.Presence
    private var sessions = ServiceSessions<any ModelTransport>()
    /// The session that has been prewarmed. **Once per session, which is once per service process
    /// in the ordinary case** — a session outlives nothing the service does, so a session dropped
    /// for a failed request re-prewarms a process that may still be warm. That costs one extra
    /// prewarm after a failure and is the safe direction: the alternative is a cold model the app
    /// believes is warm.
    private var warmed: Int?
    /// An unload in flight. Nothing is asked while it runs: the point of unloading is that what is
    /// asked next reaches a *new* process, not the one on its way out.
    private var unloading: Task<Bool, Never>?

    init(
        connect: @escaping Connect = { onCancel in
            try XPCServiceTransport<ModelRequest, ModelReply>(
                service: XiaolaiDictIdentity.modelService, onCancel: onCancel)
        },
        servicePresence: @escaping @Sendable () -> ModelServiceProcess.Presence = { ModelServiceProcess.presence },
        shutdownLimit: Duration = ModelShutdown.processExit
    ) {
        self.connect = connect
        self.servicePresence = servicePresence
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
            // waiting on any more. The session is healthy and stays. What this does *not* do is
            // stop the generation: MLX's work is a Metal call nothing outside it can interrupt, so
            // the model finishes the answer and throws it away. The service's watchdog is what
            // bounds that, and a per-request cancel message would only stop this side waiting,
            // which is what returning here already does.
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
        let presence = servicePresence
        // **Asked of the process, before a session is opened.** The service is launch-on-demand, so
        // opening one starts a service that was not running — which would load nothing, be asked to
        // unload, and count as having ended something that never existed. A scan that could not
        // tell is not "gone": it is asked again below, with a session, rather than being taken as
        // proof that the old weights have been released.
        if presence() == .gone {
            // **And nothing is left pointing at it.** A session held from before the process went
            // would be handed to the next question, which would then talk to a dead peer and lose
            // an answer for it — the launch-on-demand relaunch happens on a *new* session.
            if let current = sessions.current { drop(current, reason: "the service is not running") }
            return true
        }
        // A connection that could not be made says nothing about the process; the process does.
        guard let current = try? openSession() else { return presence() == .gone }
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
            while presence() != .gone, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            // Only a scan that *saw* the process go counts. "Could not tell" is reported as still
            // holding the model, which is the answer that costs the reader nothing but a label.
            return presence() == .gone
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
    /// This Mac's memory, so "installed" means the same thing here as on the setup board.
    var physicalMemory: UInt64 = SystemMemory.physical
    /// Set while a replaced model's service is still running — see `ModelQuarantine`.
    var quarantine = ModelQuarantine()

    /// **Only a size this Mac is offered counts.** A model copied from a larger Mac is on disk and
    /// the service will refuse it for want of memory — so counting it here started a service on
    /// every lookup only to be told "not installed", and disagreed with the row the reader sees.
    var isInstalled: Bool {
        !store.installedManifests(
            among: ModelSizing.offered(physicalMemory: physicalMemory).map(\.manifest)).isEmpty
    }

    func ask(_ request: ModelRequest) async -> ModelReply? {
        guard isInstalled, !quarantine.isHeld else { return .failure(.notInstalled) }
        return await client.ask(request)
    }

    func prewarm() async {
        guard isInstalled, !quarantine.isHeld else { return }
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

    /// The sentence pane's engines: this model first, Apple's on-device model **wherever this one
    /// does not answer** — not downloaded, not enough memory, declined, a generation that failed,
    /// a reply of the wrong shape, or no service at all.
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
/// **Held while a replaced model's service is still running.** Installing a new model ends the old
/// service before the app says "ready"; where that end could not be confirmed, the process that
/// still has the old weights would go on answering — and the reader would be told, confidently, by
/// the model they had just replaced. While this is held the local rung answers nothing, so the
/// ladder falls to Apple's model and the translator to Apple's framework, labelled as they always
/// are. It lifts itself as soon as the process is seen to be gone.
final class ModelQuarantine: Sendable {
    private let held = Mutex(false)

    init() {}

    var isHeld: Bool {
        guard held.withLock({ $0 }) else { return false }
        guard ModelServiceProcess.presence == .gone else { return true }
        held.withLock { $0 = false }
        return false
    }

    func hold() { held.withLock { $0 = true } }

    /// Lifted only where the old process was *seen* to go — never on a scan that could not tell.
    func lift() { held.withLock { $0 = false } }
}

enum ModelServiceProcess {
    /// The service's executable inside this bundle, or nil outside one (`swift run`).
    static let executable: String? = Bundle(
        url: Bundle.main.bundleURL.appending(path: "Contents/XPCServices/XiaolaiDictModelService.xpc")
    )?.executableURL?.path

    /// **Three answers, not two.** "The scan failed" is not "the service is gone": read as gone, a
    /// kernel that would not enumerate processes became proof that the old model's weights had been
    /// released, and the app then told the reader a replacement was answering.
    ///
    /// There is deliberately no `isRunning` beside it. One existed, collapsed `couldNotTell` to
    /// `false` three lines under the paragraph above, and `--model-report`'s idle watch — its only
    /// reader — took that as the service having gone: a scan it could not take was filed as an
    /// unload nobody saw. Every caller asks this enum by name and answers `couldNotTell` for
    /// itself, because what it means is the caller's question and not this one's.
    enum Presence {
        case running
        case gone
        case couldNotTell
    }

    static var presence: Presence {
        guard let executable else { return .couldNotTell }
        return presence(of: executable)
    }

    static func presence(of executable: String) -> Presence {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return .couldNotTell }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return .couldNotTell }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(found)) where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            if String(decoding: bytes, as: UTF8.self) == executable { return .running }
        }
        return .gone
    }
}
