import Foundation
@testable import LLMProviders
import ModelKit
import Testing
import XiaolaiDictTestSupport

/// **The Claude wire**: what `claude` is started with, where, and how each way a turn can end reads as a
/// `ProviderFailure` — against a fake `claude` whose errors are the shapes measured on the real one (2.1.294,
/// 2026-10-09: `authentication_failed` with nobody signed in, `model_not_found` for a model that does not exist).
struct ClaudeCLIProviderTests {
    static func provider(_ fake: FakeCLI, model: String = "haiku") -> ClaudeCLIProvider {
        ClaudeCLIProvider(executable: fake.executable, model: model, workingDirectory: fake.workingDirectory,
                          configuration: ResidentSessionTests.configuration(), events: fake.holding { _ in })
    }

    /// **The lean flags, exactly** (plan §1, measured: none of the reader's settings, hooks, MCP servers, slash
    /// commands or tools reach the session). Never `--bare`, which reads no OAuth and so no subscription.
    @Test func itStartsClaudeWithTheLeanFlagsInTheEmptyDirectory() async throws {
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake, model: "sonnet")
        _ = try await provider.generate(ResidentSessionTests.question())
        let started = try #require(try fake.logged().first)
        #expect(started["argv"] as? [String] == [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--model", "sonnet", "--no-session-persistence", "--tools", "", "--disable-slash-commands",
            "--setting-sources", "", "--strict-mcp-config", "--system-prompt", ResidentTurn.systemPrompt,
        ])
        let cwd = try #require(started["cwd"] as? String)
        #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
                == fake.workingDirectory.resolvingSymlinksInPath())
        #expect(!ClaudeCLIProvider.arguments(model: "haiku").contains("--bare"))
        await provider.shutDown()
    }

    /// The model is the reader's text, passed as one argument and never through a shell — and still refused where it
    /// could be read as a flag, before anything is started.
    @Test func aModelNameThatCouldBeAFlagIsRefusedWithoutStartingAnything() async throws {
        for name in ["haiku", "sonnet", "opus", "claude-haiku-4-5", "claude-sonnet-4-5-20250929", "sonnet[1m]",
                     "us.anthropic.claude-haiku-4-5-v1:0"] {
            #expect(ClaudeCLIProvider.acceptsModelName(name), "\(name)")
        }
        for name in ["", "--bare", "-p", "haiku --bare", "haiku\n--bare", " haiku"] {
            #expect(!ClaudeCLIProvider.acceptsModelName(name), "\(name)")
        }
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake, model: "--bare")
        await #expect(throws: ProviderFailure.modelNotFound) {
            try await provider.generate(ResidentSessionTests.question())
        }
        #expect(try fake.logged().isEmpty, "nothing was started")
    }

    @Test func nobodySignedInIsUnauthorised() async throws {
        let fake = try FakeCLI.claude(.signedOut)
        let provider = Self.provider(fake)
        await #expect(throws: ProviderFailure.unauthorised) { try await provider.generate(ResidentSessionTests.question()) }
        await provider.shutDown()
    }

    /// The assistant message's `error` names the kind; the CLI's own words are never read.
    @Test func eachErrorTheCLIReportsIsItsKind() async throws {
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake)
        let cases: [(String, ProviderFailure)] = [
            ("[[error:authentication_failed]]", .unauthorised),
            ("[[error:billing_error]]", .unauthorised),
            ("[[error:model_not_found]]", .modelNotFound),
            ("[[error:rate_limit]]", .rateLimited),
            ("[[error:server_error]]", .unreachable),
            ("[[error:invalid_request]]", .badShape("a request the CLI refused")),
            ("[[error:something_new]]", .unreachable),
            ("[[status:401]]", .unauthorised),
            ("[[status:404]]", .modelNotFound),
            ("[[status:429]]", .rateLimited),
            ("[[status:529]]", .unreachable),
            ("[[status:400]]", .badShape("the CLI reported an error")),
            ("[[refuse]]", .refused),
            ("[[empty]]", .badShape("an empty answer")),
        ]
        for (mark, failure) in cases {
            await #expect(throws: failure, "\(mark)") { try await provider.generate(ResidentSessionTests.question(mark)) }
        }
        await provider.shutDown()
    }

    /// **A failure the CLI reported is a turn that ended**: the process is intact, and the next question is its.
    @Test func aReportedFailureKeepsTheProcess() async throws {
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake)
        let first = try answeringPID(try await provider.generate(ResidentSessionTests.question()))
        await #expect(throws: ProviderFailure.rateLimited) {
            try await provider.generate(ResidentSessionTests.question("[[error:rate_limit]]"))
        }
        #expect(try answeringPID(try await provider.generate(ResidentSessionTests.question())) == first)
        await provider.shutDown()
    }

    // MARK: - Preflight

    @Test func aPreflightThatAnswersIsReadyWithTheVersionAndTheTime() async throws {
        let fake = try FakeCLI.claude()
        let provider = Self.provider(fake)
        guard case .ready(let version, let answeredIn) = await provider.preflight() else {
            Issue.record("not ready")
            return
        }
        #expect(version == "9.9.9")
        #expect(answeredIn > .zero)
        #expect(try fake.logged("text", as: String.self).count == 1, "one trivial question")
        #expect(await provider.residentPID != nil, "the process the preflight started is kept warm")
        await provider.shutDown()
    }

    @Test func aPreflightWithNobodySignedInSaysToSignIn() async throws {
        let provider = Self.provider(try FakeCLI.claude(.signedOut))
        let readiness = await provider.preflight()
        #expect(readiness == .notSignedIn)
        await provider.shutDown()
    }

    /// A `claude` that refuses one of the lean flags is older than they are.
    @Test func aPreflightOfACLIThatRefusesAFlagSaysItIsTooOld() async throws {
        let provider = Self.provider(try FakeCLI.claude(.unknownOption))
        let readiness = await provider.preflight()
        #expect(readiness == .tooOld(version: "9.9.9"))
        await provider.shutDown()
    }

    @Test func aPreflightOfACLIThatEndsWithoutAWordIsUnavailable() async throws {
        let provider = Self.provider(try FakeCLI.claude(.exitEarly))
        let readiness = await provider.preflight()
        #expect(readiness == .unavailable(.unreachable))
        await provider.shutDown()
    }
}
