import Foundation
import LLMProviders
import ModelKit
import os
import XiaolaiDictBase

/// `--provider-status`: **the language-model source the reader chose, where it runs, what it may be sent, and what it
/// said when asked one trivial question** (ADR-0053) — `--model-status`'s counterpart for a provider.
///
/// It starts the reader's CLI, or asks their endpoint, exactly as the app does — through the router the app builds,
/// over the reader's own settings — and ends what it started before it exits. **What it prints is kinds and numbers
/// only**: no sentence, no answer, no model name, no path, no URL and no key. A URL can carry a key in its query, a path
/// names the reader's home, and an answer is a model's text.
///
/// **Compiled out of a release**, as `--reminder-report` is: a reader has its words in Settings, and a release that,
/// run from a shell, started their CLI or sent their key to whatever endpoint the defaults named would be a capability
/// shipped for nobody. `verify_bundle` checks both directions.
@MainActor
enum ProviderReport {
    static func status() async -> CommandStatus {
#if !XIAOLAIDICT_CAPTURE_INSTRUMENTS
        LookupCommand.writeError("--provider-status is a development instrument and is not built into a release")
        return .usage
#else
        // The witness `verify_bundle` looks for in a development bundle: a sentence only this branch has.
        LookupCommand.writeError("provider-status: asking the chosen language-model source one trivial question")
        // **The app's own suite**: inside the bundle `.standard` is the reader's domain, where the choice is kept. The
        // local model is not this instrument's — `--model-status` asks it — so it is asked nothing here.
        let router = ModelBackendRouter(
            choices: ProviderChoiceStore(defaults: .standard), settings: ProviderSettingsStore(defaults: .standard),
            local: .init(ask: { _ in nil }, prewarm: {}))
        return await status(router: router, write: LookupCommand.writeLine)
#endif
    }

    /// The report for `router`'s source, written through `write`. Ends whatever it started before it returns.
    static func status(router: ModelBackendRouter, write: (String) -> Bool) async -> CommandStatus {
        let source = await router.currentSource
        var report: [String: Any] = ["source": name(of: source), "tier": source.tier.rawValue]
        // **What the source may be sent, read off the client itself** — asked, with a provider that records and
        // answers nothing — so the report cannot describe a rule the client does not follow.
        let disclosure = await disclosure(at: source.tier)
        report["sendsDictionaryText"] = disclosure.sendsDictionaryText
        report["asksSenseOnLookup"] = disclosure.asksSenseOnLookup
        report["asksSenseOnTap"] = disclosure.asksSenseOnTap
        let readiness = await router.check()?.readiness
        // **Put away before the line is written**, so a report that could not be written still leaves nothing running.
        await router.shutDown()
        if let readiness { describe(readiness, into: &report) }
        guard Instrument.write(report, to: write) else { return .internalError }
        return readiness.map(isReady) ?? true ? .success : .failure
    }

    /// Whether the source answered its trivial question.
    private static func isReady(_ readiness: ProviderReadiness) -> Bool {
        switch readiness {
        case .cli(.ready), .endpointReady: true
        case .cli, .endpointUnusable, .endpointFailed: false
        }
    }

    /// The source's kind — never its path, URL or model's name.
    private static func name(of source: ProviderSource) -> String {
        switch source {
        case .local: "local"
        case .claudeCLI: "claudeCLI"
        case .codexCLI: "codexCLI"
        case .endpoint: "endpoint"
        }
    }

    /// What a source at `tier` is sent, by asking a `ProviderClient` over a provider that only notes what it was handed.
    private static func disclosure(at tier: ProviderTier) async
        -> (sendsDictionaryText: Bool, asksSenseOnLookup: Bool, asksSenseOnTap: Bool) {
        let marker = "xiaolaidict-provider-status-sense-marker"
        let senses = SenseQuestion(sentence: "A sentence to ask about.", partOfSpeech: nil, senses: [marker, "another"])
        let explained = SentenceQuestion(sentence: "A sentence to ask about.", term: "sentence", senseText: marker)
        func sent(_ request: ModelRequest, _ origin: QuestionOrigin) async -> String? {
            let probe = NotingProvider()
            _ = await ProviderClient(provider: probe, tier: tier).ask(request, origin: origin)
            return probe.handed
        }
        return (sendsDictionaryText: await sent(.explain(explained), .reader)?.contains(marker) == true,
                asksSenseOnLookup: await sent(.pickSense(senses), .lookup) != nil,
                asksSenseOnTap: await sent(.pickSense(senses), .reader) != nil)
    }

    /// What a check said, as kinds and numbers.
    private static func describe(_ readiness: ProviderReadiness, into report: inout [String: Any]) {
        switch readiness {
        case .cli(.notInstalled): report["readiness"] = "notInstalled"
        // Not the path: it names the reader's home.
        case .cli(.overrideUnusable): report["readiness"] = "overrideUnusable"
        case .cli(.notSignedIn): report["readiness"] = "notSignedIn"
        case .cli(.tooOld(let version)):
            report["readiness"] = "tooOld"
            report["version"] = version ?? NSNull()
        case .cli(.unavailable(let failure)):
            report["readiness"] = "unavailable"
            report["failure"] = name(of: failure)
        case .cli(.ready(let version, let answeredIn)):
            report["readiness"] = "ready"
            report["version"] = version ?? NSNull()
            report["answeredInSeconds"] = answeredIn.seconds
        case .endpointUnusable: report["readiness"] = "endpointUnusable"
        case .endpointReady(let answeredIn):
            report["readiness"] = "ready"
            report["answeredInSeconds"] = answeredIn.seconds
        case .endpointFailed(let failure):
            report["readiness"] = "endpointFailed"
            report["failure"] = name(of: failure)
        }
    }

    /// A failure's kind. `badShape`'s reason is this app's own phrase, and is left out all the same: a kind is enough.
    private static func name(of failure: ProviderFailure) -> String {
        switch failure {
        case .unreachable: "unreachable"
        case .unauthorised: "unauthorised"
        case .modelNotFound: "modelNotFound"
        case .rateLimited: "rateLimited"
        case .refused: "refused"
        case .badShape: "badShape"
        case .timedOut: "timedOut"
        case .cancelled: "cancelled"
        }
    }

    /// A provider that notes what it was handed and answers with a failure: what reaches it is the whole point.
    private final class NotingProvider: TextGenerating {
        private let noted = OSAllocatedUnfairLock<String?>(initialState: nil)
        var handed: String? { noted.withLock { $0 } }

        func generate(_ request: GenerationRequest) async throws(ProviderFailure) -> String {
            noted.withLock { $0 = request.instructions + "\n" + request.prompt }
            throw .refused
        }
    }
}
