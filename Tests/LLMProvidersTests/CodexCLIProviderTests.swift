import Foundation
@testable import LLMProviders
import ModelKit
import Testing
import XiaolaiDictTestSupport

/// **The Codex wire**: what `codex app-server` is started with, the handshake, the one reused thread and what keeps
/// the reader's own Codex setup out of it — against a fake app-server speaking the protocol its generated schema
/// describes (0.161.0). The isolation is the part measured on the real one (plan §10, 2026-10-09): hooks, plugins and
/// apps off by `-c`, and each configured MCP server disabled for the thread by name — `-c mcp_servers={}` merges and
/// removes nothing.
struct CodexCLIProviderTests {
    static func provider(_ fake: FakeCLI, model: String = "",
                         configuration: ResidentConfiguration = ResidentSessionTests.configuration(),
                         events: EventLog = EventLog()) -> CodexCLIProvider {
        CodexCLIProvider(executable: fake.executable, model: model, workingDirectory: fake.workingDirectory,
                         configuration: configuration, events: fake.holding(events.sink))
    }

    /// The requests the fake received, by method, in order.
    static func methods(_ fake: FakeCLI) throws -> [String] {
        try fake.logged("method", as: String.self)
    }

    static func params(of method: String, in fake: FakeCLI) throws -> [[String: Any]] {
        try fake.logged().filter { $0["method"] as? String == method }.compactMap { $0["params"] as? [String: Any] }
    }

    @Test func itStartsTheAppServerOnStandardIOWithTheIsolationOverrides() async throws {
        let fake = try FakeCLI.codex()
        let provider = Self.provider(fake)
        _ = try await provider.generate(ResidentSessionTests.question())
        let started = try #require(try fake.logged().first)
        let argv = try #require(started["argv"] as? [String])
        #expect(Array(argv.prefix(3)) == ["app-server", "--listen", "stdio://"])
        var overrides: [String] = []
        for (index, argument) in argv.enumerated() where argument == "-c" && index + 1 < argv.count {
            overrides.append(argv[index + 1])
        }
        #expect(overrides == CodexCLIProvider.isolation)
        for measured in ["features.hooks=false", "features.plugins=false", "features.apps=false"] {
            #expect(overrides.contains(measured), "\(measured)")
        }
        #expect(!overrides.contains { $0.hasPrefix("mcp_servers") }, "merges, so it removes nothing (measured)")
        let cwd = try #require(started["cwd"] as? String)
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
                == fake.workingDirectory.resolvingSymlinksInPath())
        await provider.shutDown()
    }

    /// **The handshake, in order**: who is signed in is asked of the server, the configured MCP servers' names are
    /// read from it, the default model from its list, and the thread is started ephemeral, read-only, never asking for
    /// approval, with every configured MCP server disabled — then warmed with one turn before any question.
    @Test func theHandshakeStartsAnIsolatedEphemeralThreadAndWarmsIt() async throws {
        let fake = try FakeCLI.codex()
        let provider = Self.provider(fake)
        _ = try await provider.generate(ResidentSessionTests.question())
        #expect(try Self.methods(fake) == ["initialize", "initialized", "account/read", "config/read", "model/list",
                                           "thread/start", "turn/start", "turn/start"])
        let start = try #require(try Self.params(of: "thread/start", in: fake).first)
        #expect(start["ephemeral"] as? Bool == true)
        #expect(start["approvalPolicy"] as? String == "never")
        #expect(start["sandbox"] as? String == "read-only")
        #expect(start["model"] as? String == "fake-default")
        #expect(start["baseInstructions"] as? String == ResidentTurn.systemPrompt)
        let cwd = try #require(start["cwd"] as? String)
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
                == fake.workingDirectory.resolvingSymlinksInPath())
        let config = try #require(start["config"] as? [String: Any])
        let servers = try #require(config["mcp_servers"] as? [String: [String: Bool]])
        #expect(servers == ["alpha": ["enabled": false], "beta.gamma": ["enabled": false]])
        await provider.shutDown()
    }

    /// The reader's own model, where they named one, is used as named and the list is not asked.
    @Test func aNamedModelIsUsedAndTheListIsNotAsked() async throws {
        let fake = try FakeCLI.codex()
        let provider = Self.provider(fake, model: "fake-small")
        _ = try await provider.generate(ResidentSessionTests.question())
        #expect(!(try Self.methods(fake)).contains("model/list"))
        #expect(try Self.params(of: "thread/start", in: fake).first?["model"] as? String == "fake-small")
        await provider.shutDown()
    }

    /// **One thread, reused** — a new thread's first turn costs ~7–9 s (measured) — at low effort, each question in
    /// its own turn, and the answer read from the thread's own deltas alone.
    @Test func questionsReuseTheWarmThread() async throws {
        let fake = try FakeCLI.codex()
        let provider = Self.provider(fake)
        let first = try await provider.generate(ResidentSessionTests.question("[[echo:one]]"))
        let second = try await provider.generate(ResidentSessionTests.question("[[echo:two]]"))
        #expect(first.hasPrefix("pid=") && first.hasSuffix("echo=one"))
        #expect(second.hasSuffix("echo=two"))
        #expect(!first.contains("not this thread"))
        let turns = try Self.params(of: "turn/start", in: fake)
        #expect(turns.count == 3, "a warm-up and two questions")
        #expect(Set(turns.compactMap { $0["threadId"] as? String }).count == 1)
        #expect(turns.allSatisfy { $0["effort"] as? String == "low" })
        let texts = turns.compactMap { (($0["input"] as? [[String: Any]])?.first?["text"]) as? String }
        #expect(texts.last == ResidentTurn.text(for: ResidentSessionTests.question("[[echo:two]]")))
        await provider.shutDown()
    }

    @Test func anAnswerWithNoDeltasIsReadFromTheCompletedTurn() async throws {
        let fake = try FakeCLI.codex()
        let provider = Self.provider(fake)
        #expect(try await provider.generate(ResidentSessionTests.question("[[no-delta]] [[echo:items]]"))
            .hasSuffix("echo=items"))
        await provider.shutDown()
    }

    /// **The answer is the turn's final message, not everything it wrote.** A model that narrates writes `commentary`
    /// messages beside its `final_answer`, each its own item; read by turn alone, they ran together and the narration was
    /// shown as part of a translation. The phase decides, not the order: a narration can come after the answer.
    @Test(arguments: ["[[commentary]]", "[[commentary-after]]", "[[commentary]] [[commentary-after]]"])
    func aCommentaryIsNotPartOfTheAnswer(marks: String) async throws {
        let fake = try FakeCLI.codex()
        let provider = Self.provider(fake)
        let answer = try await provider.generate(ResidentSessionTests.question("\(marks) [[echo:final]]"))
        #expect(answer.hasPrefix("pid=") && answer.hasSuffix("echo=final"), "\(answer)")
        #expect(!answer.contains("Let me look") && !answer.contains("settle it"))
        await provider.shutDown()
    }

    /// **Where no message says its phase, the last one is the answer** — an older model's turn — and where the server
    /// completes no item at all, the last message's own deltas are, never every message's run together.
    @Test(arguments: ["[[no-phase]]", "[[no-item-completed]]"])
    func withoutAPhaseTheLastMessageIsTheAnswer(mark: String) async throws {
        let fake = try FakeCLI.codex()
        let provider = Self.provider(fake)
        let answer = try await provider.generate(ResidentSessionTests.question("[[commentary]] \(mark) [[echo:last]]"))
        #expect(answer.hasPrefix("pid=") && answer.hasSuffix("echo=last"), "\(answer)")
        await provider.shutDown()
    }

    /// **What a turn streams is bounded** — in bytes, and in the messages kept apart — so a server that writes without
    /// stopping cannot grow this process: past either bound the turn is not an answer, and the process is ended.
    @Test(arguments: ["[[flood]]", "[[many-items]]"])
    func aTurnPastItsBoundIsRefusedAndItsProcessEnded(mark: String) async throws {
        let fake = try FakeCLI.codex()
        let events = EventLog()
        let provider = Self.provider(fake, events: events)
        let first = try answeringPID(try await provider.generate(ResidentSessionTests.question()))
        await #expect(throws: ProviderFailure.badShape("an answer larger than the bound"), "\(mark)") {
            try await provider.generate(ResidentSessionTests.question(mark))
        }
        #expect(await waitUntilGone(first))
        await provider.shutDown()
    }

    /// The pid of every process the session reported spawning, in order.
    static func spawned(_ events: EventLog) -> [Int32] {
        events.all.compactMap { record -> Int32? in
            if case .spawned(let pid) = record.event { pid } else { nil }
        }
    }

    /// **Shutting down ends a process still being opened** — a server whose handshake has not answered — and returns
    /// once it has gone, not once the opening's own deadline has passed; the question it was opened for fails.
    @Test func shuttingDownEndsAProcessStillBeingOpened() async throws {
        let fake = try FakeCLI.codex(.stall)
        let events = EventLog()
        let provider = Self.provider(fake, events: events)
        let asking = Settling { () async throws(ProviderFailure) in
            try await provider.generate(ResidentSessionTests.question())
        }
        #expect(await events.wait { if case .spawned = $0 { true } else { false } })
        let opening = try #require(Self.spawned(events).first)
        await provider.shutDown()
        #expect(!isAlive(opening), "the shutdown returned with the process it was opening still running")
        #expect(await asking.outcome() == .failure(.unreachable))
    }

    /// **And a replacement still being opened** — started while the first process answered, and hanging in its own
    /// handshake.
    @Test func shuttingDownEndsAReplacementStillBeingOpened() async throws {
        let fake = try FakeCLI.codex(.stallAfterFirst)
        let events = EventLog()
        let provider = Self.provider(fake, configuration: ResidentSessionTests.configuration(recycleAfter: 1),
                                     events: events)
        let first = try answeringPID(try await provider.generate(ResidentSessionTests.question()))
        #expect(await events.wait { if case .spawned(let pid) = $0 { pid != first } else { false } })
        let replacement = try #require(Self.spawned(events).last)
        await provider.shutDown()
        #expect(!isAlive(replacement), "the shutdown returned with the replacement it was opening still running")
        #expect(!isAlive(first))
    }

    /// **A request for approval is refused, never left unanswered** — an unanswered one would hold the turn until the
    /// deadline — and the turn goes on to its answer.
    @Test func aRequestForApprovalIsRefusedAndTheTurnCompletes() async throws {
        let fake = try FakeCLI.codex()
        let provider = Self.provider(fake)
        #expect(try await provider.generate(ResidentSessionTests.question("[[approval]] [[echo:done]]"))
            .hasSuffix("echo=done"))
        let reply = try #require(try fake.logged("approvalReply", as: [String: Any].self).first)
        #expect(reply["id"] as? String == "approve-1")
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(reply["result"] == nil)
        await provider.shutDown()
    }

    @Test func nobodySignedInIsUnauthorisedAndNoThreadIsStarted() async throws {
        let fake = try FakeCLI.codex(.signedOut)
        let provider = Self.provider(fake)
        await #expect(throws: ProviderFailure.unauthorised) { try await provider.generate(ResidentSessionTests.question()) }
        #expect(!(try Self.methods(fake)).contains("thread/start"))
        await provider.shutDown()
    }

    @Test func eachWayATurnFailsIsItsKind() async throws {
        let fake = try FakeCLI.codex()
        let provider = Self.provider(fake)
        let cases: [(String, ProviderFailure)] = [
            ("[[fail:usageLimitExceeded]]", .rateLimited),
            ("[[fail:rateLimitExceeded]]", .rateLimited),
            ("[[fail:sessionBudgetExceeded]]", .rateLimited),
            ("[[fail:unauthorized]]", .unauthorised),
            ("[[fail:serverOverloaded]]", .unreachable),
            ("[[fail:internalServerError]]", .unreachable),
            ("[[fail:http]]", .unreachable),
            ("[[fail:cyberPolicy]]", .refused),
            ("[[fail:contextWindowExceeded]]", .badShape("a question longer than the model's context")),
            ("[[fail:somethingNew]]", .unreachable),
            ("[[interrupt]]", .unreachable),
        ]
        for (mark, failure) in cases {
            await #expect(throws: failure, "\(mark)") { try await provider.generate(ResidentSessionTests.question(mark)) }
        }
        #expect(try await provider.generate(ResidentSessionTests.question("[[retrying]] [[echo:retried]]"))
            .hasSuffix("echo=retried"), "an error the server will retry is not the turn's end")
        await provider.shutDown()
    }

    @Test func aLineThatIsNotJSONIsPassedOverAndACrashStartsAgain() async throws {
        let fake = try FakeCLI.codex()
        let provider = Self.provider(fake)
        let first = try answeringPID(try await provider.generate(ResidentSessionTests.question("[[garbage]]")))
        await #expect(throws: ProviderFailure.unreachable) {
            try await provider.generate(ResidentSessionTests.question("[[crash]]"))
        }
        #expect(await waitUntilGone(first))
        #expect(try answeringPID(try await provider.generate(ResidentSessionTests.question())) != first)
        await provider.shutDown()
    }

    @Test func aSilentServerIsEndedAtTheDeadline() async throws {
        let fake = try FakeCLI.codex()
        let provider = Self.provider(fake, configuration: ResidentSessionTests.configuration(turnTimeout: .seconds(2)))
        let first = try answeringPID(try await provider.generate(ResidentSessionTests.question()))
        let silent = Settling { () async throws(ProviderFailure) in
            try await provider.generate(ResidentSessionTests.question("[[silent]]"))
        }
        try #require(await silent.outcome(within: .seconds(8)) == .failure(.timedOut), "the deadline held")
        #expect(await waitUntilGone(first))
        await provider.shutDown()
    }

    /// Recycled, the replacement is a new process with a new thread, warmed before it answers anything.
    @Test func aRecycledServerAnswersOnANewThread() async throws {
        let fake = try FakeCLI.codex()
        let events = EventLog()
        let provider = Self.provider(fake, configuration: ResidentSessionTests.configuration(recycleAfter: 1),
                                     events: events)
        let first = try await provider.generate(ResidentSessionTests.question())
        let firstPID = try answeringPID(first)
        #expect(await events.wait { $0 == .retired(pid: firstPID, .recycled) })
        let second = try await provider.generate(ResidentSessionTests.question())
        #expect(try answeringPID(second) != firstPID)
        let threads = try Self.params(of: "turn/start", in: fake).compactMap { $0["threadId"] as? String }
        #expect(Set(threads).count == 2)
        await provider.shutDown()
    }

    // MARK: - Preflight

    @Test func aPreflightThatAnswersIsReady() async throws {
        let provider = Self.provider(try FakeCLI.codex())
        guard case .ready(let version, _) = await provider.preflight() else {
            Issue.record("not ready")
            return
        }
        #expect(version == "9.9.9")
        await provider.shutDown()
    }

    @Test func aPreflightWithNobodySignedInSaysToSignIn() async throws {
        let provider = Self.provider(try FakeCLI.codex(.signedOut))
        let readiness = await provider.preflight()
        #expect(readiness == .notSignedIn)
        await provider.shutDown()
    }

    /// Older than the protocol this speaks: an argument it does not know, or a method it does not have.
    @Test func aPreflightOfAnOlderServerSaysItIsTooOld() async throws {
        for startup in [FakeCLI.CodexStartup.unexpectedArgument, .noThreadStart] {
            let provider = Self.provider(try FakeCLI.codex(startup))
            let readiness = await provider.preflight()
            #expect(readiness == .tooOld(version: "9.9.9"), "\(startup)")
            await provider.shutDown()
        }
    }
}
