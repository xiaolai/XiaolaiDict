import Foundation
import ModelKit

/// **The source a question goes to, read off the reader's choice and settings** — only the settings that source uses,
/// so a change to another source's field does not restart the one in use.
public enum ProviderSource: Sendable, Equatable {
    /// The bundled model where one is installed, and nothing where none is: what `none` and `localModel` both mean
    /// here. Nothing is sent off the Mac by either — the local model runs on it, and with no model the model service
    /// answers "not installed" from a few file sizes without being started (`LocalModelAccess`).
    case local
    /// The reader's `claude`, at the path they gave or found, started with `model`.
    case claudeCLI(path: String?, model: String)
    /// The reader's `codex`, at the path they gave or found, asking `model` — empty for the server's own default.
    case codexCLI(path: String?, model: String)
    /// An OpenAI-compatible endpoint at the base URL `url`, asked for `model`.
    case endpoint(url: String, model: String)

    public init(choice: ProviderChoice, settings: ProviderSettings) {
        self = switch choice {
        case .none, .localModel: .local
        case .claudeCLI: .claudeCLI(path: settings.claudeCLIPath, model: settings.claudeCLIModel)
        case .codexCLI: .codexCLI(path: settings.codexCLIPath, model: settings.codexCLIModel)
        case .openAICompatible: .endpoint(url: settings.endpointURL, model: settings.endpointModel)
        }
    }

    /// Where it runs, by `RemoteDisclosure`'s rule: the local model on this Mac, both CLIs remote, an endpoint on this
    /// Mac only where its host is loopback beyond doubt.
    public var tier: ProviderTier {
        switch self {
        case .local: .onThisMac
        case .claudeCLI, .codexCLI: .remote
        case .endpoint(let url, _): RemoteDisclosure.tier(ofEndpoint: url)
        }
    }
}

/// **What a source says about itself once asked one trivial question** — a kind, never a sentence: the words a reader
/// is shown are the view layer's (ADR-0025).
public enum ProviderReadiness: Sendable, Equatable {
    /// A CLI's preflight: not installed, the path the reader gave is not a program, nobody signed in, too old, not
    /// answering, or ready.
    case cli(CLIReadiness)
    /// The endpoint's settings cannot be asked anything: a base URL that is not http(s), or no model named.
    case endpointUnusable
    /// The endpoint answered one trivial question, whole, in this time.
    case endpointReady(answeredIn: Duration)
    /// The endpoint was asked and did not answer.
    case endpointFailed(ProviderFailure)
}

/// **A source the router can hold**: it answers questions, says what the reader must do, and is put away. This
/// module's own: the router is the only thing that holds one.
protocol ProviderBackend: TextGenerating {
    /// One trivial question, and what its answer says the reader must do. A resident CLI keeps the process it started,
    /// warm, for the questions that follow.
    func readiness() async -> ProviderReadiness
    /// **Whether asking that question is how this source is warmed** — a resident CLI, whose process and thread are
    /// what a first question waits for — or would only spend a request of the reader's: an endpoint, whose kept
    /// connection opens on its first question.
    var warmsByAsking: Bool { get }
    /// Puts away whatever it started, and returns once it has gone.
    func shutDown() async
}

extension ClaudeCLIProvider: ProviderBackend {
    func readiness() async -> ProviderReadiness { .cli(await preflight()) }
    var warmsByAsking: Bool { true }
}

extension CodexCLIProvider: ProviderBackend {
    func readiness() async -> ProviderReadiness { .cli(await preflight()) }
    var warmsByAsking: Bool { true }
}

extension OpenAICompatibleProvider: ProviderBackend {
    /// One real round trip — the reader's *Check connection*, and `--provider-status`'s — with the CLIs' own trivial
    /// question, so the two kinds of source are asked the same thing.
    func readiness() async -> ProviderReadiness {
        let start = ContinuousClock.now
        do throws(ProviderFailure) {
            _ = try await generate(CLIPreflight.question)
            return .endpointReady(answeredIn: ContinuousClock.now - start)
        } catch {
            return .endpointFailed(error)
        }
    }

    nonisolated var warmsByAsking: Bool { false }

    /// Cancels whatever is in flight and closes the kept connection: a source the reader has left is asked nothing more.
    public func shutDown() async {
        invalidate()
    }
}
