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
