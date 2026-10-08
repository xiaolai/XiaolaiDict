import Foundation
@testable import LLMProviders
import Testing
import XiaolaiDictTestSupport

/// **One CLI kept running, asked one question at a time** — `ResidentSession` through the Claude wire, the simpler of
/// the two, against a fake `claude`. What is asserted is the process: which one answered (each answer names its pid),
/// whether it is still there (`kill(pid, 0)`), and in what order the session started and put processes away.
struct ResidentSessionTests {
    /// A configuration whose bounds a test can wait out: short deadlines, no idle end unless a test sets one.
    static func configuration(recycleAfter: Int = 6, turnTimeout: Duration = .seconds(10),
                              idleAfter: Duration? = nil) -> ResidentConfiguration {
        ResidentConfiguration(recycleAfter: recycleAfter, turnTimeout: turnTimeout, openTimeout: .seconds(10),
                              idleAfter: idleAfter, closeGrace: .milliseconds(500))
    }

    static func question(_ marks: String = "") -> GenerationRequest {
        GenerationRequest(instructions: "Answer briefly.", prompt: "Which number? \(marks)", maxTokens: 8, temperature: 0)
    }

    static func provider(_ fake: FakeCLI, _ configuration: ResidentConfiguration = configuration(),
                         events: EventLog = EventLog()) -> ClaudeCLIProvider {
        ClaudeCLIProvider(executable: fake.executable, model: "haiku", workingDirectory: fake.workingDirectory,
                          configuration: configuration, events: fake.holding(events.sink))
    }

    @Test func oneProcessAnswersEveryQuestion() async throws {
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake)
        var pids: Set<Int32> = []
        for _ in 0..<3 { pids.insert(try answeringPID(try await provider.generate(Self.question()))) }
        #expect(pids.count == 1)
        #expect(try fake.logged("argv", as: [String].self).count == 1, "started once")
        await provider.shutDown()
    }

    /// The answer is the `result`, trimmed — the fake pads it with line breaks.
    @Test func theAnswerIsTheResultTrimmed() async throws {
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake)
        let answer = try await provider.generate(Self.question("[[echo:seven]]"))
        #expect(answer.hasPrefix("pid=") && answer.hasSuffix("echo=seven"))
        await provider.shutDown()
    }

    @Test func aSlowAnswerWithinTheDeadlineIsAnAnswer() async throws {
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake)
        #expect(try await provider.generate(Self.question("[[slow:0.4]] [[echo:late]]")).hasSuffix("echo=late"))
        await provider.shutDown()
    }

    /// **The deadline ends the process** — a CLI that never answers cannot be talked out of a turn, and the next
    /// question must not inherit its unread answer — and the next question starts a new one.
    @Test func aCLIThatNeverAnswersIsEndedAtTheDeadline() async throws {
        let fake = try FakeCLI.claude()
        let events = EventLog()
        // Long enough for a first question under a parallel test run, which starts the process too.
        let provider = Self.provider(fake, Self.configuration(turnTimeout: .seconds(2)), events: events)
        let first = try answeringPID(try await provider.generate(Self.question()))
        let silent = Settling { () async throws(ProviderFailure) in
            try await provider.generate(Self.question("[[silent]]"))
        }
        // Required, not expected: past a deadline that did not hold, the next question would wait behind this one.
        try #require(await silent.outcome(within: .seconds(8)) == .failure(.timedOut), "the deadline held")
        #expect(await waitUntilGone(first))
        #expect(events.all.contains { $0.event == .abandoned(pid: first, .timedOut) })
        let second = try answeringPID(try await provider.generate(Self.question()))
        #expect(second != first)
        await provider.shutDown()
    }

    @Test func aCrashMidTurnIsUnreachableAndTheNextQuestionStartsAgain() async throws {
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake)
        let first = try answeringPID(try await provider.generate(Self.question()))
        await #expect(throws: ProviderFailure.unreachable) { try await provider.generate(Self.question("[[crash]]")) }
        #expect(await waitUntilGone(first))
        #expect(try answeringPID(try await provider.generate(Self.question())) != first)
        await provider.shutDown()
    }

    /// A line that is not JSON is passed over — a CLI may print one — and the turn still reads to its result.
    @Test func aLineThatIsNotJSONIsPassedOver() async throws {
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake)
        #expect(try await provider.generate(Self.question("[[garbage]] [[echo:after]]")).hasSuffix("echo=after"))
        await provider.shutDown()
    }

    /// A line past the bound is refused, and the process that wrote it is ended: what it writes next cannot be read
    /// as the start of a line.
    @Test func aLineLongerThanTheBoundIsRefusedAndItsProcessEnded() async throws {
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake)
        let first = try answeringPID(try await provider.generate(Self.question()))
        await #expect(throws: ProviderFailure.badShape("a line longer than the bound")) {
            try await provider.generate(Self.question("[[overlong]]"))
        }
        #expect(await waitUntilGone(first))
        await provider.shutDown()
    }

    /// A CLI that exits before reading anything fails the question at once rather than at the deadline.
    @Test func aCLIThatExitsAtOnceFailsWithoutWaitingForTheDeadline() async throws {
        let fake = try FakeCLI.claude(.exitEarly)
        let provider = Self.provider(fake, Self.configuration(turnTimeout: .seconds(20)))
        let start = ContinuousClock.now
        await #expect(throws: ProviderFailure.unreachable) { try await provider.generate(Self.question()) }
        #expect(ContinuousClock.now - start < .seconds(5))
        await provider.shutDown()
    }

    /// **A caller who gives up ends the turn and its process**, at once and not at the deadline.
    @Test func cancellingAQuestionEndsItsProcess() async throws {
        let fake = try FakeCLI.claude()
        let events = EventLog()
        let provider = Self.provider(fake, Self.configuration(turnTimeout: .seconds(30)), events: events)
        let asking = Task { try await provider.generate(Self.question("[[slow:20]]")) }
        #expect(await events.wait { if case .opened = $0 { true } else { false } })
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        asking.cancel()
        await #expect(throws: ProviderFailure.cancelled) { try await asking.value }
        #expect(ContinuousClock.now - start < .seconds(5))
        let spawned = try #require(events.all.compactMap { record -> Int32? in
            if case .spawned(let pid) = record.event { pid } else { nil }
        }.first)
        #expect(await waitUntilGone(spawned))
        await provider.shutDown()
    }

    /// **One question at a time, each with its own answer.** Two asked together must not share a turn: a second
    /// question written before the first's answer is read would be answered as the first.
    @Test func questionsAskedTogetherAreAnsweredInTurnEachWithItsOwnAnswer() async throws {
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake)
        async let first = provider.generate(Self.question("[[slow:0.5]] [[echo:first]]"))
        try await Task.sleep(for: .milliseconds(100))
        async let second = provider.generate(Self.question("[[echo:second]]"))
        let answers = try await (first, second)
        #expect(answers.0.hasSuffix("echo=first"))
        #expect(answers.1.hasSuffix("echo=second"))
        let turns = try fake.logged("turn", as: Int.self)
        #expect(turns == [1, 2])
        await provider.shutDown()
    }

    /// A question waiting its turn that the caller gives up on leaves at once, without waiting for the one ahead.
    @Test func aWaitingQuestionThatIsCancelledLeavesAtOnce() async throws {
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake)
        let ahead = Settling { () async throws(ProviderFailure) in
            try await provider.generate(Self.question("[[slow:3]] [[echo:ahead]]"))
        }
        try await Task.sleep(for: .milliseconds(300))
        let waiting = Settling { () async throws(ProviderFailure) in
            try await provider.generate(Self.question("[[echo:waiting]]"))
        }
        try await Task.sleep(for: .milliseconds(100))
        waiting.task.cancel()
        try #require(await waiting.outcome(within: .seconds(1)) == .failure(.cancelled),
                     "it left at once, without waiting for the question ahead")
        #expect(try #require(await ahead.outcome()).get().hasSuffix("echo=ahead"))
        #expect(try fake.logged("text", as: String.self).allSatisfy { !$0.contains("echo:waiting") })
        await provider.shutDown()
    }

    /// **Recycled after N turns, the replacement started first**: every process that had been started was still
    /// running when the replacement was spawned, the old one is put away only after, and the next question is the
    /// replacement's.
    @Test func afterNTurnsAReplacementIsStartedFirstAndTheOldOneEnded() async throws {
        let fake = try FakeCLI.claude()
        let events = EventLog()
        let provider = Self.provider(fake, Self.configuration(recycleAfter: 2), events: events)
        let first = try answeringPID(try await provider.generate(Self.question()))
        #expect(try answeringPID(try await provider.generate(Self.question())) == first)
        #expect(await events.wait { $0 == .retired(pid: first, .recycled) })
        let spawns = events.all.filter { if case .spawned = $0.event { true } else { false } }
        try #require(spawns.count == 2)
        #expect(spawns[1].aliveAtThisMoment[first] == true, "the old process was running when its replacement started")
        let order = events.all.map(\.event)
        let replacement = try #require(order.firstIndex { if case .spawned(let pid) = $0 { pid != first } else { false } })
        let retirement = try #require(order.firstIndex(of: .retired(pid: first, .recycled)))
        #expect(replacement < retirement)
        #expect(await waitUntilGone(first))
        let next = try answeringPID(try await provider.generate(Self.question()))
        #expect(next != first)
        #expect(spawns[1].event == .spawned(pid: next))
        await provider.shutDown()
    }

    @Test func anIdleProcessIsEndedAndTheNextQuestionStartsAnother() async throws {
        let fake = try FakeCLI.claude()
        let events = EventLog()
        let provider = Self.provider(fake, Self.configuration(idleAfter: .milliseconds(300)), events: events)
        let first = try answeringPID(try await provider.generate(Self.question()))
        #expect(await events.wait { $0 == .retired(pid: first, .idle) })
        #expect(await waitUntilGone(first))
        #expect(try answeringPID(try await provider.generate(Self.question())) != first)
        await provider.shutDown()
    }

    /// Questions keep a process from going idle: the clock starts again at each.
    @Test func questionsKeepAProcessFromGoingIdle() async throws {
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake, Self.configuration(idleAfter: .milliseconds(800)))
        let first = try answeringPID(try await provider.generate(Self.question()))
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(300))
            #expect(try answeringPID(try await provider.generate(Self.question())) == first)
        }
        await provider.shutDown()
    }

    @Test func shuttingDownEndsTheProcess() async throws {
        let fake = try FakeCLI.claude()
        let events = EventLog()
        let provider = Self.provider(fake, events: events)
        let first = try answeringPID(try await provider.generate(Self.question()))
        await provider.shutDown()
        #expect(!isAlive(first))
        #expect(events.all.contains { $0.event == .retired(pid: first, .shutDown) })
    }

    /// **Nothing outlives the provider**: dropped without a shutdown, its process is ended, and no orphan survives.
    @Test func droppingTheProviderEndsItsProcess() async throws {
        let fake = try FakeCLI.claude()
        var pid: Int32 = 0
        do {
            let provider = Self.provider(fake)
            pid = try answeringPID(try await provider.generate(Self.question()))
            #expect(isAlive(pid))
        }
        #expect(await waitUntilGone(pid), "the child outlived the provider that started it")
    }

    /// A process that died between questions — the CLI ends itself after some errors — is replaced, not written to.
    @Test func aProcessThatDiedBetweenQuestionsIsReplaced() async throws {
        let fake = try FakeCLI.claude()
        let events = EventLog()
        let provider = Self.provider(fake, events: events)
        let first = try answeringPID(try await provider.generate(Self.question("[[exit-after]]")))
        #expect(await waitUntilGone(first))
        #expect(try answeringPID(try await provider.generate(Self.question())) != first)
        #expect(events.all.contains { $0.event == .retired(pid: first, .exited) })
        await provider.shutDown()
    }

    /// **Every turn says it is unrelated to the last, and carries its own instructions** — one process serves three
    /// kinds of question, so instructions cannot live in its one system prompt (plan §5).
    @Test func everyTurnCarriesThePrefaceItsInstructionsAndItsPrompt() async throws {
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake)
        _ = try await provider.generate(Self.question())
        let text = try #require(try fake.logged("text", as: String.self).first)
        #expect(text == "\(ResidentTurn.preface)\n\nAnswer briefly.\n\nWhich number? ")
        await provider.shutDown()
    }

    @Test func aTurnWithoutInstructionsCarriesThePrefaceAndThePrompt() {
        let request = GenerationRequest(instructions: "", prompt: "Reply with OK.", maxTokens: 4, temperature: 0)
        #expect(ResidentTurn.text(for: request) == "\(ResidentTurn.preface)\n\nReply with OK.")
        #expect(!ResidentTurn.preface.isEmpty && !ResidentTurn.systemPrompt.isEmpty)
    }
}
