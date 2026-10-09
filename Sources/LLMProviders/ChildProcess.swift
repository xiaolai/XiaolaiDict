import Foundation
import os
import XiaolaiDictBase

/// How a child is started: the program, its arguments — never through a shell — the directory it runs in, and the
/// `PATH` it runs with.
///
/// The environment is this app's, unchanged but for `PATH` where `searchPath` names one: the CLI is the reader's own and
/// signs itself in, and nothing here adds a credential to it or reads one from it (ADR-0053).
struct ChildLaunch: Sendable, Equatable {
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL
    /// **The `PATH` the child runs with**, or nil for this app's own. A CLI a package manager installed is often a script
    /// its interpreter runs (`#!/usr/bin/env node`), and an app opened from the Dock has a `PATH` that holds neither — so
    /// the locator says where it found the program, and the child is given that (`CLILocator.searchPath`).
    var searchPath: String?
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
/// - **It runs in a process group of its own, and the group is what is signalled** — so a helper it started goes with
///   it, rather than outliving the reader's choice and holding the child's pipes open. Started with `posix_spawn`, which
///   can make the group; `Process` cannot. The group is signalled only while the child has not been reaped — after, its
///   id could be another process's — and when the child exits by itself, what is left in its group is ended with it.
/// - **Output is framed at LF** (`LineFraming`) and bounded twice: a line past `lineLimit`, and more unread lines or
///   bytes than `LineQueue.Limit` holds, end the child, and the next read says which.
/// - **A write to a child that has gone fails, it does not signal.** `SIGPIPE`'s default action ends the process that
///   wrote — the reader's app — so the pipe is set `F_SETNOSIGPIPE` and the write fails with `EPIPE` instead. **A write
///   the child will not read is given up when the child is ended**: the pipe does not block, and a write that cannot
///   proceed waits in short polls that look at whether the child was ended. Writes go through a queue of their own, so
///   one waiting holds no thread of the cooperative pool.
/// - **Ended by this process, it is ended for a reason** (`Ending`), and every read after says which: a deadline is a
///   timeout, a caller giving up is a cancellation. A child that ended on its own is unreachable. **What it wrote and
///   nobody read is discarded when this process ends it** — an answer queued before a deadline is not handed out after
///   it — and kept when it ends by itself, whose last line is still a line.
/// - **Nothing outlives it.** Released while its process runs, the process group is killed, and the child is still
///   reaped once it goes.
///
/// `@unchecked Sendable`: every field that changes is behind a lock, and the file handles are used from their handlers'
/// queues and from whichever task holds the child.
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
    private let process: ChildGroup
    private let input: ChildInput
    private let output: LineQueue
    private let diagnostics: DiagnosticsTail
    private let readers: [FileHandle]
    private let ending = OSAllocatedUnfairLock<Ending?>(initialState: nil)

    private init(process: ChildGroup, input: ChildInput, output: LineQueue, diagnostics: DiagnosticsTail,
                 readers: [FileHandle]) {
        self.process = process
        self.input = input
        self.output = output
        self.diagnostics = diagnostics
        self.readers = readers
        pid = process.pid
    }

    /// Starts `launch`. **Unreachable** where it cannot be started: no such program, or one this user cannot run.
    static func start(_ launch: ChildLaunch, lineLimit: Int = ChildProcess.lineLimit,
                      queueLimit: LineQueue.Limit = .standard) throws(ProviderFailure) -> ChildProcess {
        let pipes: ChildPipes
        do {
            pipes = try ChildPipes()
        } catch {
            log.error("a child's pipes could not be made: errno \(error.code, privacy: .public)")
            throw .unreachable
        }
        let pid: pid_t
        do {
            pid = try ChildSpawn.spawn(launch, pipes: pipes)
        } catch {
            pipes.closeAll()
            log.error("a CLI could not be started: errno \(error.code, privacy: .public)")
            throw .unreachable
        }
        pipes.closeChildEnds()
        let process = ChildGroup(pid: pid)
        let output = LineQueue(lineLimit: lineLimit, queueLimit: queueLimit) { [process] in
            // Past a bound the child is ended at once, not at the next read: nothing it writes after can be read.
            process.signal(SIGKILL)
        }
        let diagnostics = DiagnosticsTail(limit: diagnosticsLimit)
        let stdout = FileHandle(fileDescriptor: pipes.output.read, closeOnDealloc: true)
        let stderr = FileHandle(fileDescriptor: pipes.errors.read, closeOnDealloc: true)
        stdout.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                output.finish()
            } else {
                output.receive(chunk)
            }
        }
        stderr.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                diagnostics.finish()
            } else {
                diagnostics.receive(chunk)
            }
        }
        return ChildProcess(process: process, input: ChildInput(descriptor: pipes.input.write), output: output,
                            diagnostics: diagnostics, readers: [stdout, stderr])
    }

    deinit {
        // The last resort: whoever held this child let it go without putting it away. Its group is killed, and the
        // child is reaped by its own watch whenever it goes.
        process.signal(SIGKILL)
        input.abandon()
        output.abort()
        for reader in readers { reader.readabilityHandler = nil }
    }

    var isRunning: Bool { process.isRunning }

    /// Writes `line` and the LF that ends it.
    func send(_ line: Data) async throws(ProviderFailure) {
        guard await input.deliver(line + Data([UInt8(ascii: "\n")])) else { throw failureAtEnd }
    }

    /// The next line the child wrote, without its LF. **Throws once there is none** — the child ended, by itself or by
    /// this process — with the failure its ending names.
    func nextLine() async throws(ProviderFailure) -> Data {
        if let line = await output.next() { return line }
        throw failureAtEnd
    }

    /// **Ends the child now**: its group `SIGKILL`ed, a write waiting on it given up, and what it wrote and nobody read
    /// discarded, so a read waiting on it returns the ending. The first reason given is the one every later read reports.
    func end(_ reason: Ending) {
        ending.withLock { if $0 == nil { $0 = reason } }
        input.abandon()
        process.signal(SIGKILL)
        output.abort()
    }

    /// **Puts the child away and waits for it**: standard input closed first, which ends a CLI that reads to its end;
    /// `SIGTERM` to its group only for one still there after `grace`, and `SIGKILL` after another.
    func close(grace: Duration) async {
        ending.withLock { if $0 == nil { $0 = .retired } }
        closeInput()
        guard !(await exited(within: grace)) else { return }
        process.signal(SIGTERM)
        guard !(await exited(within: grace)) else { return }
        end(.retired)
        _ = await exited(within: grace)
    }

    /// **Puts the child away without waiting** — for a caller that cannot: input closed and `SIGTERM` now, `SIGKILL`
    /// after `grace` for one still there. The child is kept alive until then by the work that will end it.
    func terminate(grace: Duration) {
        ending.withLock { if $0 == nil { $0 = .retired } }
        closeInput()
        process.signal(SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace.seconds) { [self] in
            end(.retired)
        }
    }

    /// How the child ended, once it has — or as far as it got by `bound`.
    func exit(within bound: Duration) async -> ChildExit {
        _ = await exited(within: bound)
        await diagnostics.ended(within: bound)
        return ChildExit(status: process.status, diagnostics: diagnostics.text)
    }

    /// The failure a read or a write meets once the child can give it nothing more: past a bound, the bound; ended by
    /// this process, its reason; ended by itself, unreachable.
    var failureAtEnd: ProviderFailure {
        switch output.overflow {
        case .line?: return .badShape("a line longer than the bound")
        case .queue?: return .badShape("more output than the bound")
        case nil: break
        }
        switch ending.withLock({ $0 }) {
        case .deadline: return .timedOut
        case .cancelled: return .cancelled
        case .abandoned, .retired, nil: return .unreachable
        }
    }

    // MARK: -

    /// Closes the child's standard input: a write in flight is given up, and a CLI that reads to its end then ends.
    func closeInput() {
        input.close()
    }

    /// Whether the child has exited by `bound`. Polled, and the poll reaps it. A caller that is cancelled stops waiting
    /// at once.
    private func exited(within bound: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: bound)
        while process.isRunning {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return !process.isRunning }
            try? await Task.sleep(for: Self.poll)
        }
        return true
    }

    private static let poll = Duration.milliseconds(10)
}

// MARK: - The process and its group

/// **The child's process, and the one place it is signalled and reaped.**
///
/// The child leads a process group of its own, whose id is its pid. A signal goes to the whole group, and only while
/// the child has not been reaped: a reaped child's id is free for another process, and its group's with it once the
/// group is empty. When the child is seen to have exited — by its own watch, or by a poll — it is first left a zombie,
/// so its id cannot be reused, while what is left in its group is killed; only then is it reaped.
///
/// The watch keeps this object until the child is reaped, so a child let go of while running is still reaped.
final class ChildGroup: Sendable {
    private enum State: Sendable {
        case running
        case exited(status: Int32?)
    }

    let pid: pid_t
    private let state = OSAllocatedUnfairLock(initialState: State.running)
    private let watch = OSAllocatedUnfairLock<DispatchSourceProcess?>(uncheckedState: nil)

    init(pid: pid_t) {
        self.pid = pid
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                      queue: .global(qos: .utility))
        // Strong on purpose: the watch is what reaps a child nobody holds any more. **The exit is reported a moment
        // before the child can be waited for**, and the report comes once — so the handler waits for that moment, on
        // the watch's own queue and without the lock, before it reaps.
        source.setEventHandler { [self] in
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
            _ = reapIfExited()
        }
        // **The watch is registered after `resume()` returns, on the system's own time**, and an exit before it is
        // registered is never reported by it — so it looks once more when it is, and once here for an exit before both.
        source.setRegistrationHandler { [self] in _ = reapIfExited() }
        watch.withLockUnchecked { $0 = source }
        source.resume()
        _ = reapIfExited()
    }

    var isRunning: Bool { !reapIfExited() }

    /// The exit status — its code, or the signal that ended it — once the child has been reaped.
    var status: Int32? {
        _ = reapIfExited()
        return state.withLock { state in
            if case .exited(let status) = state { return status }
            return nil
        }
    }

    /// Signals the child's group — the child and everything still in its group — while the child is not yet reaped.
    func signal(_ signal: Int32) {
        state.withLock { state in
            guard case .running = state else { return }
            _ = kill(-pid, signal)
            // The child itself too, where it has left its own group: it is still this process's child, and unreaped.
            _ = kill(pid, signal)
        }
    }

    /// Reaps the child where it has exited, ending what it left in its group first. True once it has been reaped.
    private func reapIfExited() -> Bool {
        let reaped = state.withLock { state -> Bool in
            if case .exited = state { return true }
            var info = siginfo_t()
            let peeked = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if peeked == -1, errno == ECHILD {
                // Not this process's to reap — nothing else here waits on it — so it is gone, status unknown.
                state = .exited(status: nil)
                return true
            }
            guard peeked == 0, info.si_pid == pid else { return false }
            // A zombie still holds its id, so its group cannot be another's yet: what it left behind goes now.
            _ = kill(-pid, SIGKILL)
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            state = .exited(status: result == pid ? Self.decoded(status) : nil)
            return true
        }
        if reaped { watch.withLockUnchecked { $0?.cancel(); $0 = nil } }
        return reaped
    }

    /// A wait status as `Process.terminationStatus` reads one: the exit code, or the signal that ended the child.
    private static func decoded(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : signal
    }
}

// MARK: - Standard input

/// **The child's standard input**: written on a queue of its own, without blocking, and given up on when the child is.
final class ChildInput: Sendable {
    private struct State: Sendable {
        var abandoned = false
        var closed = false
    }

    private let descriptor: Int32
    private let writes = DispatchQueue(label: "com.xiaolaidict.providers.child-input")
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How long one wait for room in the pipe lasts before it looks again at whether to give up.
    private static let pollMilliseconds: Int32 = 50

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        let descriptor = descriptor, alreadyClosed = state.withLock { $0.closed }
        if !alreadyClosed { closeDescriptor(descriptor) }
    }

    /// Writes all of `data`, or answers false: the child stopped reading for good, or was given up on, or the input
    /// was closed.
    func deliver(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            writes.async { [self] in
                continuation.resume(returning: writeAll(data))
            }
        }
    }

    /// Gives up any write in flight or to come: the child has been ended.
    func abandon() {
        state.withLock { $0.abandoned = true }
    }

    /// Closes the pipe after giving up any write in flight; a write after it fails.
    func close() {
        let first = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.abandoned = true
            return true
        }
        guard first else { return }
        writes.async { [self] in
            let closing = state.withLock { state -> Bool in
                guard !state.closed else { return false }
                state.closed = true
                return true
            }
            if closing { closeDescriptor(descriptor) }
        }
    }

    private var givenUp: Bool { state.withLock { $0.abandoned || $0.closed } }

    /// On the writes queue: the bytes written in turn, waiting for room in short polls, until all are written or the
    /// write is given up.
    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return !givenUp }
            var offset = 0
            while offset < buffer.count {
                if givenUp { return false }
                let written = writeDescriptor(descriptor, base + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EAGAIN {
                    waitUntilWritable(descriptor, milliseconds: Self.pollMilliseconds)
                } else if written == -1, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

// MARK: - Starting it

/// The three pipes a child is spoken to over, each end marked close-on-exec so no other child this process starts
/// inherits it; the child's ends are made its standard input, output and error by the spawn.
private struct ChildPipes {
    struct Ends {
        let read: Int32
        let write: Int32
    }

    let input: Ends
    let output: Ends
    let errors: Ends

    init() throws(ChildSpawn.Failure) {
        let input = try Self.pipe()
        let output: Ends
        do { output = try Self.pipe() } catch { Self.close(input); throw error }
        let errors: Ends
        do { errors = try Self.pipe() } catch { Self.close(input); Self.close(output); throw error }
        self.input = input
        self.output = output
        self.errors = errors
        // A write to a child that has gone must fail, not raise SIGPIPE — whose default action ends the app — and must
        // never block: a write that cannot proceed waits in polls that can be given up.
        guard fcntl(input.write, F_SETNOSIGPIPE, 1) == 0 else {
            let code = errno
            closeAll()
            throw ChildSpawn.Failure(code: code)
        }
        let flags = fcntl(input.write, F_GETFL)
        guard flags != -1, fcntl(input.write, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno
            closeAll()
            throw ChildSpawn.Failure(code: code)
        }
    }

    func closeChildEnds() {
        closeDescriptor(input.read)
        closeDescriptor(output.write)
        closeDescriptor(errors.write)
    }

    func closeAll() {
        Self.close(input)
        Self.close(output)
        Self.close(errors)
    }

    private static func pipe() throws(ChildSpawn.Failure) -> Ends {
        var ends: [Int32] = [-1, -1]
        guard makePipe(&ends) == 0 else { throw ChildSpawn.Failure(code: errno) }
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        return Ends(read: ends[0], write: ends[1])
    }

    private static func close(_ ends: Ends) {
        closeDescriptor(ends.read)
        closeDescriptor(ends.write)
    }
}

/// `posix_spawn`, set up as a CLI is started here: a process group of its own, every signal at its default and none
/// blocked — this app ignores `SIGTERM` to handle it on a queue, and an ignored signal is inherited across an exec — and
/// no descriptor but the three pipes.
private enum ChildSpawn {
    struct Failure: Error {
        let code: Int32
    }

    static func spawn(_ launch: ChildLaunch, pipes: ChildPipes) throws(Failure) -> pid_t {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure(code: errno) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw Failure(code: errno) }
        defer { posix_spawnattr_destroy(&attributes) }

        for (descriptor, standard) in [(pipes.input.read, STDIN_FILENO), (pipes.output.write, STDOUT_FILENO),
                                       (pipes.errors.write, STDERR_FILENO)] {
            try check(posix_spawn_file_actions_adddup2(&actions, descriptor, standard))
        }
        try check(posix_spawn_file_actions_addchdir(&actions, launch.workingDirectory.path))

        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        try check(posix_spawnattr_setsigmask(&attributes, &unblocked))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)))

        var environment = ProcessInfo.processInfo.environment
        if let searchPath = launch.searchPath { environment["PATH"] = searchPath }
        let argv = CStrings([launch.executable.path] + launch.arguments)
        let envp = CStrings(environment.map { "\($0.key)=\($0.value)" })
        var pid: pid_t = 0
        try check(posix_spawn(&pid, launch.executable.path, &actions, &attributes, argv.pointers, envp.pointers))
        return pid
    }

    private static func check(_ result: Int32) throws(Failure) {
        guard result == 0 else { throw Failure(code: result) }
    }
}

/// C strings for `posix_spawn`'s argument and environment vectors, NULL-terminated, freed with this.
private final class CStrings {
    let pointers: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) {
        pointers = strings.map { strdup($0) } + [nil]
    }

    deinit {
        for pointer in pointers { free(pointer) }
    }
}

// The system calls, at file scope: inside the types above, `close` and `write` would name their own members.
private func closeDescriptor(_ descriptor: Int32) {
    _ = close(descriptor)
}

private func writeDescriptor(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    write(descriptor, bytes, count)
}

private func makePipe(_ ends: inout [Int32]) -> Int32 {
    pipe(&ends)
}

private func waitUntilWritable(_ descriptor: Int32, milliseconds: Int32) {
    var request = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    _ = poll(&request, 1, milliseconds)
}

// MARK: - Standard output

/// The child's output as lines, handed to one reader at a time.
///
/// The pipe's handler appends and the reader takes; a reader with nothing to take waits, and is answered by the next
/// line or by the end. **One reader**: the session asks one question at a time, so a second would be a defect here —
/// logged, and the first answered with the end rather than left waiting for ever.
///
/// **Bounded in lines and in bytes**, not only per line: a child writing short lines nobody reads — between questions,
/// say — would otherwise grow this process without end. Past either bound everything queued is dropped, the reading
/// ends, and `onOverflow` ends the child. Taken from the front by an index, so reading n lines is linear in n.
final class LineQueue: Sendable {
    /// How much unread output is held.
    struct Limit: Sendable, Equatable {
        let lines: Int
        let bytes: Int

        /// Far past what a turn writes between two reads — a Codex turn writes a delta a token — and short of a child
        /// that does not stop.
        static let standard = Limit(lines: 16_384, bytes: 4 * ChildProcess.lineLimit)
    }

    /// Which bound was passed.
    enum Overflow: Sendable, Equatable {
        case line
        case queue
    }

    private struct State {
        var framing: LineFraming
        var lines: [Data] = []
        var head = 0
        var bytes = 0
        var finished = false
        var overflow: Overflow?
        var waiter: CheckedContinuation<Data?, Never>?

        var queued: Int { lines.count - head }

        mutating func take() -> Data {
            let line = lines[head]
            head += 1
            bytes -= line.count
            // Compacted once the front taken is most of the array, so the array holds what is unread, give or take.
            if head >= Self.compaction, head * 2 >= lines.count {
                lines.removeFirst(head)
                head = 0
            }
            return line
        }

        mutating func discard() {
            lines = []
            head = 0
            bytes = 0
        }

        static let compaction = 64
    }

    private let limit: Limit
    private let onOverflow: @Sendable () -> Void
    private let state: OSAllocatedUnfairLock<State>

    init(lineLimit: Int, queueLimit: Limit = .standard, onOverflow: @escaping @Sendable () -> Void = {}) {
        limit = queueLimit
        self.onOverflow = onOverflow
        state = OSAllocatedUnfairLock(uncheckedState: State(framing: LineFraming(limit: lineLimit)))
    }

    /// Which bound the output passed, where it passed one.
    var overflow: Overflow? { state.withLockUnchecked { $0.overflow } }

    func receive(_ chunk: Data) {
        var overflowed = false
        let handOff: (CheckedContinuation<Data?, Never>, Data?)? = state.withLockUnchecked { state in
            guard !state.finished else { return nil }
            do {
                for line in try state.framing.append(chunk) {
                    state.lines.append(line)
                    state.bytes += line.count
                }
            } catch {
                state.overflow = .line
            }
            let handOff = Self.answerWaiter(&state)
            if state.overflow == nil, state.queued > limit.lines || state.bytes > limit.bytes {
                state.overflow = .queue
            }
            guard state.overflow != nil else { return handOff }
            overflowed = true
            state.finished = true
            state.discard()
            if handOff != nil { return handOff }
            return Self.answerWaiter(&state)
        }
        if let (waiter, line) = handOff { waiter.resume(returning: line) }
        if overflowed { onOverflow() }
    }

    /// The child stopped writing: the last unterminated line, if any, is the last line, and a waiting reader is
    /// answered. What is queued is still read.
    func finish() {
        let handOff: (CheckedContinuation<Data?, Never>, Data?)? = state.withLockUnchecked { state in
            guard !state.finished else { return nil }
            state.finished = true
            if let last = state.framing.finish() {
                state.lines.append(last)
                state.bytes += last.count
            }
            return Self.answerWaiter(&state)
        }
        if let (waiter, line) = handOff { waiter.resume(returning: line) }
    }

    /// The child was ended: nothing queued is read, and a waiting reader is answered with the end.
    func abort() {
        let waiter: CheckedContinuation<Data?, Never>? = state.withLockUnchecked { state in
            state.finished = true
            state.discard()
            _ = state.framing.finish()
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    /// The next line, or nil once there will be none.
    func next() async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let now: (answer: Data?, displaced: CheckedContinuation<Data?, Never>?)? = state.withLockUnchecked { state in
                if state.queued > 0 { return (state.take(), nil) }
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
        if state.queued > 0 {
            state.waiter = nil
            return (waiter, state.take())
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
