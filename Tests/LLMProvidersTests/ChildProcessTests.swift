import Foundation
@testable import LLMProviders
import Testing
import XiaolaiDictTestSupport

/// **The framing and the child underneath both CLI providers**: lines cut at LF and nowhere else, a bound on a line,
/// a write to a child that has gone, and the last line of a child that did not end it.
struct ChildProcessTests {
    // MARK: - Framing

    @Test func linesAreCutAtLineFeedsAcrossChunks() throws {
        var framing = LineFraming(limit: 64)
        #expect(try framing.append(Data("{\"a\":1}\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
        #expect(try framing.append(Data(":2}\n\n".utf8)) == [Data("{\"b\":2}".utf8), Data()])
        #expect(framing.finish() == nil)
    }

    /// U+2028 and U+2029 are legal unescaped inside a JSON string; a framing that ended lines at them — as
    /// `AsyncLineSequence` does — would cut an answer holding one into two lines that are not JSON.
    @Test func onlyALineFeedEndsALine() throws {
        var framing = LineFraming(limit: 256)
        let line = "{\"result\":\"one\u{2028}two\u{2029}three\u{85}four\rfive\"}"
        #expect(try framing.append(Data((line + "\n").utf8)) == [Data(line.utf8)])
    }

    @Test func aCarriageReturnBeforeTheLineFeedIsDropped() throws {
        var framing = LineFraming(limit: 64)
        #expect(try framing.append(Data("{}\r\n".utf8)) == [Data("{}".utf8)])
    }

    @Test func whatIsLeftAtTheEndIsTheLastLine() throws {
        var framing = LineFraming(limit: 64)
        #expect(try framing.append(Data("{}\n{\"last\":true}".utf8)) == [Data("{}".utf8)])
        #expect(framing.finish() == Data("{\"last\":true}".utf8))
        #expect(framing.finish() == nil, "the remainder is handed out once")
    }

    /// The bound holds across chunks — a line that arrives in pieces is still one line — and a line exactly at it is
    /// not refused.
    @Test func aLineLongerThanTheBoundIsRefused() throws {
        var exact = LineFraming(limit: 8)
        #expect(try exact.append(Data("12345678\n".utf8)) == [Data("12345678".utf8)])
        var framing = LineFraming(limit: 8)
        #expect(try framing.append(Data("12345".utf8)).isEmpty)
        #expect(throws: LineFraming.Overflow()) { try framing.append(Data("6789".utf8)) }
    }

    /// **A CRLF line exactly at the bound is one line wherever the chunks fall** — a CR held at the end of a chunk may be
    /// the start of the line's own ending, so it is not counted against the line until what follows says it is.
    @Test func aCarriageReturnAtTheBoundIsHeldForTheLineFeedThatEndsIt() throws {
        var framing = LineFraming(limit: 8)
        #expect(try framing.append(Data("12345678\r".utf8)).isEmpty)
        #expect(try framing.append(Data("\n".utf8)) == [Data("12345678".utf8)])
        // The control: a CR that turns out to be text is the ninth character of a line of eight.
        var text = LineFraming(limit: 8)
        #expect(try text.append(Data("12345678\r".utf8)).isEmpty)
        #expect(throws: LineFraming.Overflow()) { try text.append(Data("x".utf8)) }
        var twoReturns = LineFraming(limit: 8)
        #expect(throws: LineFraming.Overflow()) { try twoReturns.append(Data("12345678\r\r".utf8)) }
    }

    // MARK: - What the child writes, held

    /// **Short lines nobody reads are bounded too**, not only long ones: a child that writes without stopping while no
    /// question is being read is ended, and the next read says why — rather than this process's memory growing with it.
    @Test func manyShortLinesPastTheQueuesBoundEndTheChild() async throws {
        let fake = try FakeCLI.shell(printing: [])
        try Data("#!/bin/sh\ni=0\nwhile [ $i -lt 40000 ]; do echo x; i=$((i+1)); done\nexec sleep 3600\n".utf8)
            .write(to: fake.executable)
        let child = try ChildProcess.start(ChildLaunch(executable: fake.executable, arguments: [],
                                                       workingDirectory: fake.directory.url))
        defer { child.end(.retired) }
        #expect(await waitUntilGone(child.pid, within: .seconds(20)), "a child writing past the bound was not ended")
        await #expect(throws: ProviderFailure.badShape("more output than the bound")) { try await child.nextLine() }
    }

    /// **A child ended by this process is ended mid-sentence**: what it wrote and nobody read yet is not read after —
    /// an answer queued before a deadline or a cancellation is not handed out as though neither had happened. The
    /// control is a child that ends by itself, whose last lines are still read (`theLastLineOfAChildThatDidNotEndItIsRead`).
    @Test func aChildEndedByThisProcessHasNothingLeftToRead() async throws {
        let fake = try FakeCLI.shell(printing: [])
        // One write, well under PIPE_BUF, so both lines arrive in the chunk the first read is answered from.
        try Data("#!/bin/sh\nprintf 'first\\nsecond\\n'\nexec sleep 3600\n".utf8).write(to: fake.executable)
        let child = try ChildProcess.start(ChildLaunch(executable: fake.executable, arguments: [],
                                                       workingDirectory: fake.directory.url))
        #expect(try await child.nextLine() == Data("first".utf8))
        child.end(.cancelled)
        await #expect(throws: ProviderFailure.cancelled) { try await child.nextLine() }
        #expect(await waitUntilGone(child.pid))
    }

    // MARK: - What the child started

    /// A child that starts a process of its own, which keeps the child's standard input and sleeps: the shape of a CLI
    /// that runs a helper. `escapes` puts that process in a session of its own, out of the child's process group.
    static func parent(of descendant: TemporaryDirectory, escapes: Bool) throws -> URL {
        let script = descendant.appending("parent")
        try Data("""
            #!/usr/bin/python3 -I
            import os, sys, time
            pid = os.fork()
            if pid == 0:
                if \(escapes ? "True" : "False"):
                    os.setsid()
                with open(sys.argv[1] + ".partial", "w") as f:
                    f.write(str(os.getpid()))
                os.rename(sys.argv[1] + ".partial", sys.argv[1])
                time.sleep(3600)
                os._exit(0)
            time.sleep(3600)
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// The pid `parent(of:escapes:)`'s descendant wrote, once it has.
    static func descendant(writtenTo file: URL) async throws -> Int32 {
        for _ in 0..<500 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the child's own process never started")
        throw ProviderFailure.unreachable
    }

    /// **Ending a child ends what it started**: it runs in a process group of its own, and the group is what is
    /// signalled — a helper left running would keep the child's pipes open and outlive the app's choice.
    @Test func endingAChildEndsTheProcessesItStarted() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-child")
        let file = scratch.appending("descendant.pid")
        let child = try ChildProcess.start(ChildLaunch(
            executable: try Self.parent(of: scratch, escapes: false), arguments: [file.path],
            workingDirectory: scratch.url))
        let descendant = try await Self.descendant(writtenTo: file)
        defer { kill(descendant, SIGKILL) }
        child.end(.abandoned)
        #expect(await waitUntilGone(child.pid))
        #expect(await waitUntilGone(descendant), "a process the child started outlived it")
    }

    /// **A write the child will never read is given up when the child is ended** — even where a process the child
    /// started has left its group and still holds the pipe, so no signal reaches it and the write would otherwise wait
    /// for ever, holding the turn — and the session's gate — with it.
    @Test func aWriteNobodyWillReadIsGivenUpWhenTheChildIsEnded() async throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-child")
        let file = scratch.appending("descendant.pid")
        let child = try ChildProcess.start(ChildLaunch(
            executable: try Self.parent(of: scratch, escapes: true), arguments: [file.path],
            workingDirectory: scratch.url))
        let descendant = try await Self.descendant(writtenTo: file)
        defer { kill(descendant, SIGKILL) }
        // Far past what a pipe holds, so the write is still waiting when the child is ended.
        let writing = Settling { () async throws(ProviderFailure) in
            try await child.send(Data(String(repeating: "x", count: 4 << 20).utf8))
        }
        child.end(.abandoned)
        guard case .failure(let failure)? = await writing.outcome(within: .seconds(10)) else {
            Issue.record("the write was still waiting after the child was ended")
            return
        }
        #expect(failure == .unreachable)
    }

    // MARK: - The child

    /// **A write to a child that has gone fails as a `ProviderFailure` and this process carries on.** Without
    /// `F_SETNOSIGPIPE` the write raises `SIGPIPE`, whose default action ends the process that wrote — the reader's
    /// app, or here the test runner, which is the evidence: a red run of this test is a run that stopped.
    @Test func writingToAChildThatHasGoneFailsAndDoesNotEndThisProcess() async throws {
        let fake = try FakeCLI.claude(.exitEarly)
        let child = try ChildProcess.start(ChildLaunch(executable: fake.executable, arguments: [],
                                                       workingDirectory: fake.workingDirectory))
        #expect(await waitUntilGone(child.pid))
        await #expect(throws: ProviderFailure.unreachable) {
            try await child.send(Data(String(repeating: "x", count: 200_000).utf8))
        }
        await #expect(throws: ProviderFailure.unreachable) { try await child.nextLine() }
    }

    @Test func aChildThatCannotStartIsUnreachable() throws {
        let scratch = TemporaryDirectory(named: "xiaolaidict-child")
        #expect(throws: ProviderFailure.unreachable) {
            try ChildProcess.start(ChildLaunch(executable: scratch.appending("no-such-program"), arguments: [],
                                               workingDirectory: scratch.url))
        }
    }

    /// A child that writes its last line without an LF and exits has still written that line.
    @Test func theLastLineOfAChildThatDidNotEndItIsRead() async throws {
        let fake = try FakeCLI.shell(printing: [])
        try Data("#!/bin/sh\nprintf 'first\\nlast'\n".utf8).write(to: fake.executable)
        let child = try ChildProcess.start(ChildLaunch(executable: fake.executable, arguments: [],
                                                       workingDirectory: fake.directory.url))
        #expect(try await child.nextLine() == Data("first".utf8))
        #expect(try await child.nextLine() == Data("last".utf8))
        await #expect(throws: ProviderFailure.unreachable) { try await child.nextLine() }
    }

    /// **The child's error output is kept, bounded, for a diagnosis** — what an older CLI says about a flag it does
    /// not know — and its exit status with it.
    @Test func whatAChildSaidOnItsWayOutIsKept() async throws {
        let fake = try FakeCLI.claude(.unknownOption)
        let child = try ChildProcess.start(ChildLaunch(executable: fake.executable, arguments: [],
                                                       workingDirectory: fake.workingDirectory))
        let exit = await child.exit(within: .seconds(5))
        #expect(exit.status == 1)
        #expect(exit.diagnostics.contains("unknown option '--tools'"))
    }

    /// Ended by this process for a reason, a child's reads fail with that reason's failure — a deadline is a timeout,
    /// a caller giving up is a cancellation — and the process is gone.
    @Test func aChildEndedForAReasonFailsWithThatReason() async throws {
        for (ending, failure) in [(ChildProcess.Ending.deadline, ProviderFailure.timedOut),
                                  (.cancelled, .cancelled), (.abandoned, .unreachable)] {
            let fake = try FakeCLI.claude()
            let child = try ChildProcess.start(ChildLaunch(executable: fake.executable, arguments: [],
                                                           workingDirectory: fake.workingDirectory))
            #expect(child.isRunning)
            child.end(ending)
            await #expect(throws: failure) { try await child.nextLine() }
            #expect(await waitUntilGone(child.pid), "\(ending)")
        }
    }

    /// **Closing asks politely first**: standard input is closed, which ends a CLI that reads to the end of it, and
    /// only a child that is still there after the grace is signalled.
    @Test func closingEndsTheChildAndWaitsForIt() async throws {
        let fake = try FakeCLI.claude()
        let child = try ChildProcess.start(ChildLaunch(executable: fake.executable, arguments: [],
                                                       workingDirectory: fake.workingDirectory))
        await child.close(grace: .seconds(2))
        #expect(!child.isRunning)
        #expect(!isAlive(child.pid))
    }
}
