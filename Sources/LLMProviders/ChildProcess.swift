import Foundation
import os
import XiaolaiDictBase

/// How a child is started: the program, its arguments — never through a shell — and the directory it runs in.
///
/// The environment is this app's, unchanged: the CLI is the reader's own and signs itself in, and nothing here adds a
/// credential to it or reads one from it (ADR-0053).
struct ChildLaunch: Sendable, Equatable {
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL
}

/// How a child ended: its exit status where it has one, and the end of what it wrote to standard error.
///
/// The diagnostics are read for a fixed marker (`CLIDiagnosis`) and never logged: a CLI's error output can echo the
/// question it was asked, which holds the reader's sentence.
struct ChildExit: Sendable, Equatable {
    let status: Int32?
    let diagnostics: String
}

/// **A CLI started as a child of this process**, spoken to in lines over its standard input and output.
///
/// - **Output is framed at LF** (`LineFraming`) and bounded: a line past `lineLimit` ends the reading, and the caller
///   ends the child.
/// - **A write to a child that has gone fails, it does not signal.** `SIGPIPE`'s default action ends the process that
///   wrote — the reader's app — so the pipe is set `F_SETNOSIGPIPE` and the write fails with `EPIPE` instead. Writes go
///   through a queue of their own, so one blocked on a full pipe holds no thread of the cooperative pool.
/// - **Ended by this process, it is ended for a reason** (`Ending`), and every read after says which: a deadline is a
///   timeout, a caller giving up is a cancellation. A child that ended by itself is unreachable.
/// - **Nothing outlives it.** Released while its process runs, the process is killed.
///
/// `@unchecked Sendable`: `Process` and the pipes' handles are used from their handlers' queues and from whichever
/// task holds the child; every field that changes is behind a lock, and `Process` answers `isRunning` from any thread.
final class ChildProcess: @unchecked Sendable {
    /// Why this process ended the child, where it did. A child that ended on its own has none.
    enum Ending: Sendable, Equatable {
        /// A question or an opening outlived its deadline.
        case deadline
        /// The caller gave up.
        case cancelled
        /// A turn could not be read to its end, so what the child writes next is unknowable.
        case abandoned
        /// Put away between questions: recycled, idle, or shut down.
        case retired
    }

    /// The longest line read: far past anything either CLI writes for one of these questions — a whole effective
    /// configuration is tens of kilobytes — and well short of a stream that does not stop.
    static let lineLimit = 1 << 20
    /// How much of the child's error output is kept for a diagnosis: its last lines, where a CLI says why it stopped.
    static let diagnosticsLimit = 8 * 1_024

    private static let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "providers")

    let pid: Int32
    private let process: Process
    private let input: FileHandle
    private let output: LineQueue
    private let diagnostics: DiagnosticsTail
    private let writes = DispatchQueue(label: "com.xiaolaidict.providers.child-input")
    private let ending = OSAllocatedUnfairLock<Ending?>(initialState: nil)

    private init(process: Process, input: FileHandle, output: LineQueue, diagnostics: DiagnosticsTail) {
        self.process = process
        self.input = input
        self.output = output
        self.diagnostics = diagnostics
        pid = process.processIdentifier
    }

    /// Starts `launch`. **Unreachable** where it cannot be started: no such program, or one this user cannot run.
    static func start(_ launch: ChildLaunch, lineLimit: Int = ChildProcess.lineLimit) throws(ProviderFailure)
        -> ChildProcess {
        let process = Process()
        process.executableURL = launch.executable
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.workingDirectory
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // A write to a child that has gone must fail, not raise SIGPIPE — whose default action ends the app.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            log.error("a child's input could not be kept from raising SIGPIPE: errno \(errno, privacy: .public)")
            throw .unreachable
        }
        let output = LineQueue(limit: lineLimit)
        let diagnostics = DiagnosticsTail(limit: diagnosticsLimit)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                output.finish()
            } else {
                output.receive(chunk)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                diagnostics.finish()
            } else {
                diagnostics.receive(chunk)
            }
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            log.error("a CLI could not be started: \(String(describing: type(of: error)), privacy: .public)")
            throw .unreachable
        }
        return ChildProcess(process: process, input: stdin.fileHandleForWriting, output: output,
                            diagnostics: diagnostics)
    }

    deinit {
        // The last resort: whoever held this child let it go without putting it away.
        if process.isRunning { kill(pid, SIGKILL) }
        output.finish()
    }

    var isRunning: Bool { process.isRunning }

    /// Writes `line` and the LF that ends it.
    func send(_ line: Data) async throws(ProviderFailure) {
        let framed = line + Data([UInt8(ascii: "\n")])
        let handle = input
        let written: Bool = await withCheckedContinuation { continuation in
            writes.async {
                do {
                    try handle.write(contentsOf: framed)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
        guard written else { throw failureAtEnd() }
    }

    /// The next line the child wrote, without its LF. **Throws once there is none** — the child ended, by itself or by
    /// this process — with the failure its ending names.
    func nextLine() async throws(ProviderFailure) -> Data {
        if let line = await output.next() { return line }
        throw failureAtEnd()
    }

    /// **Ends the child now**: `SIGKILL`, and its output finished so a read waiting on it returns. The first reason
    /// given is the one every later read reports.
    func end(_ reason: Ending) {
        ending.withLock { if $0 == nil { $0 = reason } }
        if process.isRunning { kill(pid, SIGKILL) }
        output.finish()
    }

    /// **Puts the child away and waits for it**: standard input closed first, which ends a CLI that reads to its end;
    /// `SIGTERM` only for one still there after `grace`, and `SIGKILL` after another.
    func close(grace: Duration) async {
        ending.withLock { if $0 == nil { $0 = .retired } }
        closeInput()
        guard !(await exited(within: grace)) else { return }
        if process.isRunning { process.terminate() }
        guard !(await exited(within: grace)) else { return }
        end(.retired)
        _ = await exited(within: grace)
    }

    /// **Puts the child away without waiting** — for a caller that cannot: input closed and `SIGTERM` now, `SIGKILL`
    /// after `grace` for one still there. The child is kept alive until then by the work that will end it.
    func terminate(grace: Duration) {
        ending.withLock { if $0 == nil { $0 = .retired } }
        closeInput()
        if process.isRunning { process.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace.seconds) { [self] in
            end(.retired)
        }
    }

    /// How the child ended, once it has — or as far as it got by `bound`.
    func exit(within bound: Duration) async -> ChildExit {
        _ = await exited(within: bound)
        await diagnostics.ended(within: bound)
        return ChildExit(status: process.isRunning ? nil : process.terminationStatus, diagnostics: diagnostics.text)
    }

    // MARK: -

    /// Closes the child's standard input, after any write in flight: a CLI that reads to its end then ends.
    func closeInput() {
        let handle = input
        writes.async { try? handle.close() }
    }

    /// Whether the child has exited by `bound`. Polled: `Process` reaps the child itself, and a second waiter on the
    /// same pid would race it. A caller that is cancelled stops waiting at once.
    private func exited(within bound: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: bound)
        while process.isRunning {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return !process.isRunning }
            try? await Task.sleep(for: Self.poll)
        }
        return true
    }

    private static let poll = Duration.milliseconds(10)

    private func failureAtEnd() -> ProviderFailure {
        if output.overflowed { return .badShape("a line longer than the bound") }
        switch ending.withLock({ $0 }) {
        case .deadline: return .timedOut
        case .cancelled: return .cancelled
        case .abandoned, .retired, nil: return .unreachable
        }
    }
}

/// The child's output as lines, handed to one reader at a time.
///
/// The pipe's handler appends and the reader takes; a reader with nothing to take waits, and is answered by the next
/// line or by the end. **One reader**: the session asks one question at a time, so a second would be a defect here —
/// logged, and the first answered with the end rather than left waiting for ever.
final class LineQueue: Sendable {
    private struct State {
        var framing: LineFraming
        var lines: [Data] = []
        var finished = false
        var overflowed = false
        var waiter: CheckedContinuation<Data?, Never>?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(limit: Int) {
        state = OSAllocatedUnfairLock(initialState: State(framing: LineFraming(limit: limit)))
    }

    var overflowed: Bool { state.withLock { $0.overflowed } }

    func receive(_ chunk: Data) {
        let handOff: (CheckedContinuation<Data?, Never>, Data?)? = state.withLock { state in
            guard !state.finished else { return nil }
            do {
                state.lines += try state.framing.append(chunk)
            } catch {
                state.overflowed = true
                state.finished = true
                state.lines.removeAll()
            }
            return Self.answerWaiter(&state)
        }
        if let (waiter, line) = handOff { waiter.resume(returning: line) }
    }

    /// No more output: the last unterminated line, if any, is the last line, and a waiting reader is answered.
    func finish() {
        let handOff: (CheckedContinuation<Data?, Never>, Data?)? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            if let last = state.framing.finish() { state.lines.append(last) }
            return Self.answerWaiter(&state)
        }
        if let (waiter, line) = handOff { waiter.resume(returning: line) }
    }

    /// The next line, or nil once there will be none.
    func next() async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let now: (answer: Data?, displaced: CheckedContinuation<Data?, Never>?)? = state.withLock { state in
                if !state.lines.isEmpty { return (state.lines.removeFirst(), nil) }
                if state.finished { return (nil, nil) }
                let displaced = state.waiter
                state.waiter = continuation
                return displaced.map { (nil, $0) }
            }
            guard let now else { return }
            if let displaced = now.displaced {
                Logger(subsystem: XiaolaiDictIdentity.app, category: "providers")
                    .fault("two readers waited on one child's output; the first was answered with its end")
                displaced.resume(returning: nil)
            } else {
                continuation.resume(returning: now.answer)
            }
        }
    }

    /// The waiter and what it is owed — a line, or nil at the end — where both are there to hand over.
    private static func answerWaiter(_ state: inout State) -> (CheckedContinuation<Data?, Never>, Data?)? {
        guard let waiter = state.waiter else { return nil }
        if !state.lines.isEmpty {
            state.waiter = nil
            return (waiter, state.lines.removeFirst())
        }
        if state.finished {
            state.waiter = nil
            return (waiter, nil)
        }
        return nil
    }
}

/// The last `limit` bytes the child wrote to standard error, and whether it has stopped writing.
final class DiagnosticsTail: Sendable {
    private struct State {
        var bytes = Data()
        var ended = false
    }

    private let limit: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(limit: Int) {
        self.limit = limit
    }

    func receive(_ chunk: Data) {
        state.withLock { state in
            state.bytes.append(chunk)
            if state.bytes.count > limit { state.bytes = Data(state.bytes.suffix(limit)) }
        }
    }

    func finish() {
        state.withLock { $0.ended = true }
    }

    var text: String { String(decoding: state.withLock { $0.bytes }, as: UTF8.self) }

    /// Waits until the child has stopped writing, up to `bound`.
    func ended(within bound: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: bound)
        while !state.withLock({ $0.ended }), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
