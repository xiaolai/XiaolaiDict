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
///   **A shutdown reaches every process the session started** (`ChildRegistry`): the one answering, a replacement, one
///   being put away, and one still being opened — whose handshake can take the opening's whole deadline — and returns
///   once each has gone. A second shutdown waits for the first.
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
    private let children = ChildRegistry()

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
    /// **Set by `shutDown`, and never cleared**: the session is over, and a question that arrives after it — one racing
    /// the app's quit — starts nothing, because nothing would be left to end what it started.
    private var isShutDown = false
    /// The shutdown, once one has begun — what a second caller waits for.
    private var shuttingDown: Task<Void, Never>?

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
        guard !isShutDown else { throw .unreachable }
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

    /// Puts every process away and waits for them to end — each within its grace, side by side, so this is bounded.
    /// **The end of the session**: nothing is started after it, and a process being started now is ended as it starts.
    func shutDown() async {
        if let shuttingDown { return await shuttingDown.value }
        isShutDown = true
        idle?.cancel()
        idle = nil
        let replacement = replacing?.task
        let retiring = retireAll(.shutDown)
        // Every process started and not seen to go — the one being opened for a question too, which nothing else here
        // holds — and nothing started after this.
        let started = children.seal()
        let grace = configuration.closeGrace
        let shutdown = Task {
            await withTaskGroup(of: Void.self) { group in
                for child in started { group.addTask { await child.close(grace: grace) } }
            }
            for retirement in retiring { await retirement.value }
            await replacement?.value
        }
        shuttingDown = shutdown
        await shutdown.value
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
        switch await Self.launch(wire, configuration, events, children) {
        case .success(let fresh):
            // Shut down while it was starting: it is put away with the rest, never answered from.
            guard !isShutDown else {
                await retire(fresh, .shutDown).value
                throw .unreachable
            }
            current = fresh
            turnsOnCurrent = 0
            return fresh
        case .failure(let launch):
            lastEnded = launch.child
            throw launch.failure
        }
    }

    /// Starts a process, registered in `children` as it starts, and opens it within the opening's deadline. A process
    /// started once the session has been shut down is ended at once: the shutdown has already been through `children`.
    private static func launch(_ wire: Wire, _ configuration: ResidentConfiguration,
                               _ events: @Sendable (ResidentEvent) -> Void,
                               _ children: ChildRegistry) async -> Result<Resident, LaunchFailure> {
        let child: ChildProcess
        do {
            child = try ChildProcess.start(wire.launch)
        } catch {
            return .failure(LaunchFailure(failure: error, child: nil))
        }
        events(.spawned(pid: child.pid))
        guard children.admit(child) else {
            child.end(.retired)
            events(.abandoned(pid: child.pid, .unreachable))
            return .failure(LaunchFailure(failure: .unreachable, child: child))
        }
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
        let wire = wire, configuration = configuration, events = events, children = children
        let task = Task { [weak self] in
            let launched = await Self.launch(wire, configuration, events, children)
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
    ///
    /// **One of the three settles the turn, and only one** (`TurnRace`): `body` finishing, the deadline, the caller
    /// giving up. An answer `body` returns after the child was ended for either of the others is that ending's failure,
    /// never an answer — and a deadline or a cancellation after `body` finished ends nothing.
    private static func bounded<T: Sendable>(
        _ child: ChildProcess, within limit: Duration,
        _ body: @Sendable () async throws(ProviderFailure) -> T
    ) async throws(ProviderFailure) -> T {
        let race = TurnRace()
        let timer = Task {
            do { try await Task.sleep(for: limit) } catch { return }
            if race.end() { child.end(.deadline) }
        }
        defer { timer.cancel() }
        let value = try await withTaskCancellationHandler { () async throws(ProviderFailure) -> T in
            try await body()
        } onCancel: {
            if race.end() { child.end(.cancelled) }
        }
        guard race.settle() else { throw child.failureAtEnd }
        return value
    }
}

/// **Which came first to a turn**: its answer, or what ended it — the deadline, or the caller giving up. Whichever asks
/// first wins, under a lock, so an answer and an ending cannot both be taken for one turn.
final class TurnRace: Sendable {
    private enum State: Sendable {
        case running
        case settled
        case ended
    }

    private let state = OSAllocatedUnfairLock(initialState: State.running)

    /// The turn is to be ended: true where nothing has settled it yet, and then nothing else will.
    func end() -> Bool {
        state.withLock { state in
            guard case .running = state else { return false }
            state = .ended
            return true
        }
    }

    /// The turn has its answer: true where nothing has ended it first.
    func settle() -> Bool {
        state.withLock { state in
            switch state {
            case .running:
                state = .settled
                return true
            case .settled:
                return true
            case .ended:
                return false
            }
        }
    }
}

/// **Every process a session started and has not seen go** — the one answering, a replacement, one being put away, one
/// still being opened — so a shutdown reaches all of them. Sealed by the shutdown: a process started after it is not
/// admitted, and its starter ends it. Processes that have gone are dropped as new ones come, so it holds a handful.
final class ChildRegistry: Sendable {
    private struct State: Sendable {
        var children: [ObjectIdentifier: ChildProcess] = [:]
        var sealed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Holds `child` until the shutdown, unless the session has been shut down already.
    func admit(_ child: ChildProcess) -> Bool {
        state.withLock { state in
            guard !state.sealed else { return false }
            state.children = state.children.filter { $0.value.isRunning }
            state.children[ObjectIdentifier(child)] = child
            return true
        }
    }

    /// Every process still held, and none admitted after.
    func seal() -> [ChildProcess] {
        state.withLock { state in
            state.sealed = true
            return Array(state.children.values)
        }
    }
}
