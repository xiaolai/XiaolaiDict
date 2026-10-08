import Foundation
@testable import LLMProviders
import ModelKit
import Testing
import XiaolaiDictTestSupport
@testable import XiaolaiDict

/// `--provider-status`: **kinds and numbers, never the reader's text, a path, a URL, a model's name or a key** — and
/// what it started is put away before it returns. Driven through the router the app builds, over a suite of the test's
/// own, with a provider in this process.
@MainActor
struct ProviderReportTests {
    /// The reader's settings, each field holding something the report must never print.
    static func suite(choosing choice: ProviderChoice, endpoint: String) -> UserDefaults {
        let suite = TemporaryDefaults.suite()
        ProviderChoiceStore(defaults: suite).save(choice)
        ProviderSettingsStore(defaults: suite).save(ProviderSettings(
            endpointURL: endpoint, endpointModel: "private-endpoint-model",
            claudeCLIPath: "/Users/someone-private/.local/bin/claude", claudeCLIModel: "private-claude-model",
            subscriptionCLIsEnabled: true))
        return suite
    }

    static func report(_ suite: UserDefaults, _ factory: ProviderFactory) async throws
        -> (CommandStatus, String, [String: Any]) {
        let router = ModelBackendRouter(
            choices: ProviderChoiceStore(defaults: suite), settings: ProviderSettingsStore(defaults: suite),
            local: .init(ask: { _ in nil }, prewarm: {}), factory: factory)
        var lines: [String] = []
        let status = await ProviderReport.status(router: router) { lines.append($0); return true }
        let line = try #require(lines.first)
        #expect(lines.count == 1)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return (status, line, json)
    }

    static let secrets = ["someone-private", "private-claude-model", "private-endpoint-model", "sk-PRIVATE",
                          "api.example.com", FakeProvider.explanation, "9.9.9 (Fake"]

    @Test func aRemoteCLIIsReportedByKindAndNumberAndPutAway() async throws {
        let backend = FakeProvider()
        let (status, line, json) = try await Self.report(
            Self.suite(choosing: .claudeCLI, endpoint: "https://api.example.com/v1?key=sk-PRIVATE"),
            ProviderFactory { _ in ProviderBuild(backend: backend) })
        #expect(status == .success)
        #expect(json["source"] as? String == "claudeCLI")
        #expect(json["tier"] as? String == "remote")
        #expect(json["sendsDictionaryText"] as? Bool == false)
        #expect(json["asksSenseOnLookup"] as? Bool == false)
        #expect(json["asksSenseOnTap"] as? Bool == false)
        #expect(json["readiness"] as? String == "ready")
        #expect(json["version"] as? String == "9.9.9")
        #expect(json["answeredInSeconds"] is NSNumber)
        for secret in Self.secrets { #expect(!line.contains(secret), "the report printed \(secret)") }
        #expect(backend.shutDowns == 1, "the instrument left what it started running")
    }

    /// **What it says a source may be sent is what the client does** — read by asking the real client, so the report
    /// cannot describe a rule the client does not follow. On this Mac the sense goes, and a lookup asks it.
    @Test func aSourceOnThisMacIsReportedAsSentTheSense() async throws {
        let (status, _, json) = try await Self.report(
            Self.suite(choosing: .openAICompatible, endpoint: "http://127.0.0.1:11434/v1"),
            ProviderFactory { _ in ProviderBuild(backend: FakeProvider()) })
        #expect(status == .success)
        #expect(json["source"] as? String == "endpoint")
        #expect(json["tier"] as? String == "onThisMac")
        #expect(json["sendsDictionaryText"] as? Bool == true)
        #expect(json["asksSenseOnLookup"] as? Bool == true)
        #expect(json["asksSenseOnTap"] as? Bool == true)
    }

    /// A source that is not there is a failure, and says what the reader must do — by kind.
    @Test func aSourceThatIsNotThereIsAFailureThatSaysWhy() async throws {
        let (status, _, json) = try await Self.report(
            Self.suite(choosing: .codexCLI, endpoint: "https://api.example.com/v1"),
            ProviderFactory { _ in ProviderBuild(refusal: .cli(.notInstalled)) })
        #expect(status == .failure)
        #expect(json["readiness"] as? String == "notInstalled")
    }

    @Test func anUnreachableEndpointSaysWhichFailure() async throws {
        let (status, _, json) = try await Self.report(
            Self.suite(choosing: .openAICompatible, endpoint: "https://api.example.com/v1"),
            ProviderFactory { _ in ProviderBuild(backend: Unreachable()) })
        #expect(status == .failure)
        #expect(json["readiness"] as? String == "endpointFailed")
        #expect(json["failure"] as? String == "rateLimited")
    }

    /// The local model is `--model-status`'s: nothing is asked, and nothing failed.
    @Test func theLocalSourceIsAskedNothing() async throws {
        let (status, _, json) = try await Self.report(
            Self.suite(choosing: .none, endpoint: "https://api.example.com/v1"),
            ProviderFactory { _ in
                Issue.record("a provider was made for the local source")
                return ProviderBuild(refusal: .endpointUnusable)
            })
        #expect(status == .success)
        #expect(json["source"] as? String == "local")
        #expect(json["readiness"] == nil)
    }

    /// **A test build is not a development bundle**: without the define the instrument refuses, as a release does.
    @Test func withoutTheDefineTheInstrumentRefuses() async {
        #expect(await ProviderReport.status() == .usage)
    }

    private final class Unreachable: ProviderBackend {
        let warmsByAsking = false
        func generate(_ request: GenerationRequest) async throws(ProviderFailure) -> String { throw .rateLimited }
        func readiness() async -> ProviderReadiness { .endpointFailed(.rateLimited) }
        func shutDown() async {}
    }
}
