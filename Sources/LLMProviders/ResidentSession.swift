import Foundation
import ModelKit
import os
import XiaolaiDictBase

/// How a resident CLI is kept: when it is replaced, how long a question and an opening may take, when it is ended.
public struct ResidentConfiguration: Sendable, Equatable {
    /// **Questions one process answers before it is replaced** (plan §5: 6). A resident process remembers every turn,
    /// and each question must stand alone; the per-turn preface asks the model to ignore the earlier ones, and this
    /// bounds how many there can be. A soft bound: the old process answers while its replacement starts.
    public var recycleAfter: Int
    /// How long one question may take, from writing it to reading its end. Past it the process is ended.
    public var turnTimeout: Duration
    /// How long a new process may take to be ready — Codex's handshake and warm-up turn included (7–11 s measured).
    public var openTimeout: Duration
    /// How long a process is kept with nothing to answer (plan §5: the model service's `ModelIdleSeconds` default).
    /// Nil keeps it until it is shut down.
    public var idleAfter: Duration?
    /// How long a process put away is given to end by itself, and then after `SIGTERM`, before `SIGKILL`.
    public var closeGrace: Duration

    public static let standard = ResidentConfiguration()

    public init(recycleAfter: Int = 6, turnTimeout: Duration = .seconds(30), openTimeout: Duration = .seconds(45),
                idleAfter: Duration? = .seconds(ModelIdle.defaultSeconds), closeGrace: Duration = .seconds(1)) {
        self.recycleAfter = max(1, recycleAfter)
        self.turnTimeout = turnTimeout
        self.openTimeout = openTimeout
        self.idleAfter = idleAfter
        self.closeGrace = closeGrace
    }
}

/// Why a resident process was put away.
enum ResidentRetirement: Sendable, Equatable {
    /// It had answered its share and its replacement was ready.
    case recycled
    /// Nothing was asked of it for `idleAfter`.
    case idle
    /// Its session was shut down.
    case shutDown
    /// It had ended by itself between questions.
    case exited
}

/// What happened to a resident process — for the log, and for a test asserting the order.
enum ResidentEvent: Sendable, Equatable {
    case spawned(pid: Int32)
    case opened(pid: Int32)
    case retired(pid: Int32, ResidentRetirement)
    /// A turn or an opening that could not be read to its end; the process was ended.
    case abandoned(pid: Int32, ProviderFailure)
}

/// **What one CLI speaks over a resident process** — the part that differs between `claude` and `codex`.
protocol ResidentWire: Sendable {
    /// What a process holds between questions once it is open: nothing for Claude, a thread for Codex.
    associatedtype Conversation: Sendable

    var launch: ChildLaunch { get }

    /// Makes a newly started process ready for its first question. A throw ends the process.
    func open(_ child: ChildProcess) async throws(ProviderFailure) -> Conversation

    /// **One question, read to the end of its turn.** The outcome is the answer or the failure the CLI reported, and
    /// the process is intact either way. A throw means the turn could not be read to its end — the process is in a
    /// state nothing knows, and is ended.
    func ask(_ request: GenerationRequest, in conversation: Conversation, over child: ChildProcess)
        async throws(ProviderFailure) -> Result<String, ProviderFailure>
}

/// **What a resident process is told**, the same for both CLIs.
///
/// One process serves three kinds of question — a sense, an explanation, a translation — and has one system prompt, so
/// **the instructions travel in the turn** (plan §5) and the system prompt says only how to treat a turn. Measured
/// against the sense instructions in the system prompt on 2026-10-09 (plan §10): 18 of 20 right in the turn, 19 of 20
/// in the system prompt, one discordant pair — inside the noise of a panel that size.
enum ResidentTurn {
    static let systemPrompt = """
        You answer short questions for a dictionary app. Every message is a separate question that carries its own \
        instructions: follow them, and treat nothing in an earlier message as context. Answer only what the message \
        asks for.
        """

    /// The first line of every turn: a resident history is context, and each question must stand alone.
    static let preface = "This is an unrelated question; ignore earlier messages."

    static func text(for request: GenerationRequest) -> String {
        ([preface] + [request.instructions, request.prompt].filter { !$0.isEmpty }).joined(separator: "\n\n")
    }
}

/// **One CLI kept running and asked one question at a time** (plan §5).
///
/// - **Started on the first question**, and again after one that ended it: a process that crashed, overran its
///   deadline or was given up on is ended, never written to again, because its next line could be the last turn's.
/// - **One turn at a time** (`TurnGate`), each with its deadline. A deadline or a cancellation ends the process — it
///   cannot be talked out of a turn — and that is how the waiting read returns.
/// - **Recycled after `recycleAfter` turns, the replacement first**: it is started and opened while the old one still
///   answers, then swapped in, and only then is the old one put away. A replacement that cannot start leaves the old
///   one answering, and is tried again after the next turn.
/// - **Ended when idle**, when shut down, and when nothing holds the session any more — so no process outlives it.
actor ResidentSession<Wire: ResidentWire> {
    private struct Resident: Sendable {
        let child: ChildProcess
        let conversation: Wire.Conversation
    }

    /// A launch that failed, and the process it started where it started one — kept for its diagnosis.
    private struct LaunchFailure: Error {
        let failure: ProviderFailure
        let child: ChildProcess?
    }

    private static var log: Logger { Logger(subsystem: XiaolaiDictIdentity.app, category: "providers") }

    private let wire: Wire
    private let configuration: ResidentConfiguration
    private let events: @Sendable (ResidentEvent) -> Void
    private let gate = TurnGate()

    private var current: Resident?
    private var turnsOnCurrent = 0
    /// A replacement opened while a turn was in flight, swapped in when the turn ends.
    private var ready: Resident?
    private var replacing: (id: Int, task: Task<Void, Never>)?
    private var replacements = 0
    /// Why the last replacement in flight was called off, for the one that finishes starting after it was.
    private var calledOff = ResidentRetirement.shutDown
    private var turnInFlight = false
    /// Bumped by every question, so an idle timer set before one knows it is stale.
    private var activity = 0
    private var idle: Task<Void, Never>?
    /// The last process that ended unasked, kept until a diagnosis has read it.
    private var lastEnded: ChildProcess?

    init(wire: Wire, configuration: ResidentConfiguration,
         events: @escaping @Sendable (ResidentEvent) -> Void = { _ in }) {
        self.wire = wire
        self.configuration = configuration
        self.events = events
    }

    deinit {
        replacing?.task.cancel()
        idle?.cancel()
        // Nobody can wait for these any more: each is closed and signalled now, and killed after the grace.
        current?.child.terminate(grace: configuration.closeGrace)
        ready?.child.terminate(grace: configuration.closeGrace)
    }

    /// Asks the resident process `request`, starting one where there is none.
    func ask(_ request: GenerationRequest) async throws(ProviderFailure) -> String {
        guard !Task.isCancelled else { throw .cancelled }
        try await gate.enter()
        defer { gate.leave() }
        // Admitted by a `leave()` that raced this caller's cancellation: holding the gate is not a reason to ask.
        guard !Task.isCancelled else { throw .cancelled }
        activity += 1
        idle?.cancel()
        adoptReady()
        turnInFlight = true
        var asked: Resident?
        let outcome: Result<String, ProviderFailure>
        do throws(ProviderFailure) {
            let resident = try await usableResident()
            asked = resident
            let wire = wire
            outcome = try await Self.bounded(resident.child, within: configuration.turnTimeout) {
                () async throws(ProviderFailure) -> Result<String, ProviderFailure> in
                try await wire.ask(request, in: resident.conversation, over: resident.child)
            }
            turnsOnCurrent += 1
        } catch {
            turnInFlight = false
            if let asked { abandon(asked, because: error) }
            scheduleIdleEnd()
            throw error
        }
        turnInFlight = false
        adoptReady()
        if turnsOnCurrent >= configuration.recycleAfter { beginReplacement() }
        scheduleIdleEnd()
        return try outcome.get()
    }

    /// Puts every process away and waits for them to end — each within its grace, so this is bounded.
    func shutDown() async {
        idle?.cancel()
        idle = nil
        for closing in retireAll(.shutDown) { await closing.value }
    }

    /// How each process is started.
    nonisolated var launch: ChildLaunch { wire.launch }

    /// The resident process's id, where there is one running.
    var residentPID: Int32? {
        guard let current, current.child.isRunning else { return nil }
        return current.child.pid
    }

    /// How the last process that ended unasked ended — for a preflight's diagnosis of a CLI that will not start.
    func lastExit() async -> ChildExit? {
        guard let lastEnded else { return nil }
        return await lastEnded.exit(within: configuration.closeGrace)
    }

    // MARK: - The resident process

    /// The process to ask: the current one while it runs, else a new one, started and opened.
    private func usableResident() async throws(ProviderFailure) -> Resident {
        if let current {
            if current.child.isRunning { return current }
            Self.log.info("a resident CLI (pid \(current.child.pid, privacy: .public)) had ended; starting another")
            lastEnded = current.child
            self.current = nil
            events(.retired(pid: current.child.pid, .exited))
        }
        switch await Self.launch(wire, configuration, events) {
        case .success(let fresh):
            current = fresh
            turnsOnCurrent = 0
            return fresh
        case .failure(let launch):
            lastEnded = launch.child
            throw launch.failure
        }
    }

    /// Starts a process and opens it, within the opening's deadline.
    private static func launch(_ wire: Wire, _ configuration: ResidentConfiguration,
                               _ events: @Sendable (ResidentEvent) -> Void) async -> Result<Resident, LaunchFailure> {
        let child: ChildProcess
        do {
            child = try ChildProcess.start(wire.launch)
        } catch {
            return .failure(LaunchFailure(failure: error, child: nil))
        }
        events(.spawned(pid: child.pid))
        log.info("started a resident CLI, pid \(child.pid, privacy: .public)")
        do {
            let conversation = try await bounded(child, within: configuration.openTimeout) {
                () async throws(ProviderFailure) -> Wire.Conversation in
                try await wire.open(child)
            }
            events(.opened(pid: child.pid))
            return .success(Resident(child: child, conversation: conversation))
        } catch {
            child.end(.abandoned)
            events(.abandoned(pid: child.pid, error))
            log.error("""
                a resident CLI (pid \(child.pid, privacy: .public)) could not be opened: \
                \(String(describing: error), privacy: .public)
                """)
            return .failure(LaunchFailure(failure: error, child: child))
        }
    }

    /// Ends `resident`, whose turn could not be read to its end.
    private func abandon(_ resident: Resident, because failure: ProviderFailure) {
        resident.child.end(.abandoned)
        lastEnded = resident.child
        if current?.child === resident.child { current = nil }
        events(.abandoned(pid: resident.child.pid, failure))
        if failure != .cancelled {
            Self.log.error("""
                a resident CLI (pid \(resident.child.pid, privacy: .public)) was ended mid-turn: \
                \(String(describing: failure), privacy: .public)
                """)
        }
    }

    // MARK: - Recycling

    private func beginReplacement() {
        guard replacing == nil, ready == nil else { return }
        replacements += 1
        let id = replacements
        let wire = wire, configuration = configuration, events = events
        let task = Task { [weak self] in
            let launched = await Self.launch(wire, configuration, events)
            // With the session gone, `launched` is dropped here, and a process it started is killed with it.
            await self?.replacementLaunched(launched, id: id)
        }
        replacing = (id, task)
    }

    private func replacementLaunched(_ launched: Result<Resident, LaunchFailure>, id: Int) {
        guard replacing?.id == id else {
            // Called off — the session went idle or was shut down while this one started.
            if case .success(let fresh) = launched { _ = retire(fresh, calledOff) }
            return
        }
        replacing = nil
        switch launched {
        case .success(let fresh):
            ready = fresh
            if !turnInFlight { adoptReady() }
        case .failure(let launch):
            lastEnded = launch.child
            Self.log.error("a replacement CLI could not be started; the current one answers until the next try")
        }
    }

    /// Swaps in a replacement that is ready, and only then puts the one it replaces away.
    private func adoptReady() {
        guard let fresh = ready else { return }
        ready = nil
        let old = current
        current = fresh
        turnsOnCurrent = 0
        if let old { _ = retire(old, .recycled) }
    }

    // MARK: - Putting processes away

    @discardableResult
    private func retire(_ resident: Resident, _ reason: ResidentRetirement) -> Task<Void, Never> {
        let child = resident.child, grace = configuration.closeGrace, events = events
        return Task {
            await child.close(grace: grace)
            events(.retired(pid: child.pid, reason))
        }
    }

    private func retireAll(_ reason: ResidentRetirement) -> [Task<Void, Never>] {
        calledOff = reason
        replacing?.task.cancel()
        replacing = nil
        var closing: [Task<Void, Never>] = []
        if let ready { closing.append(retire(ready, reason)) }
        if let current { closing.append(retire(current, reason)) }
        ready = nil
        current = nil
        turnsOnCurrent = 0
        return closing
    }

    private func scheduleIdleEnd() {
        idle?.cancel()
        guard let after = configuration.idleAfter, current != nil || ready != nil || replacing != nil else { return }
        let seen = activity
        idle = Task { [weak self] in
            do { try await Task.sleep(for: after) } catch { return }
            await self?.idleExpired(seen)
        }
    }

    private func idleExpired(_ seen: Int) {
        guard seen == activity, !turnInFlight else { return }
        Self.log.info("a resident CLI was idle; ending it")
        _ = retireAll(.idle)
    }

    // MARK: - Deadlines

    /// Runs `body` against `child` within `limit`. **The deadline and a cancellation end the child**, which ends the
    /// read `body` is waiting on — with `.timedOut` or `.cancelled`, which the child's ending names.
    private static func bounded<T: Sendable>(
        _ child: ChildProcess, within limit: Duration,
        _ body: @Sendable () async throws(ProviderFailure) -> T
    ) async throws(ProviderFailure) -> T {
        let timer = Task {
            do { try await Task.sleep(for: limit) } catch { return }
            child.end(.deadline)
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler { () async throws(ProviderFailure) -> T in
            try await body()
        } onCancel: {
            child.end(.cancelled)
        }
    }
}
