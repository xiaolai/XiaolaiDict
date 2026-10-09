import Foundation
import ModelKit

/// **A source, made ready to be asked** — or why it could not be, as the reader would have to act on it.
struct ProviderBuild: Sendable {
    /// The source, built. Nil where it could not be: no such CLI, an endpoint that cannot be asked.
    let backend: (any ProviderBackend)?
    /// Why there is no backend — the readiness a preflight would have reported — where there is none.
    let refusal: ProviderReadiness?
    /// What the backend runs in and must outlive it: a CLI's empty working directory, removed when this goes.
    let keeps: (any Sendable)?

    init(backend: any ProviderBackend) {
        self.init(backend: backend, refusal: nil, keeps: nil)
    }

    init(refusal: ProviderReadiness) {
        self.init(backend: nil, refusal: refusal, keeps: nil)
    }

    init(backend: (any ProviderBackend)?, refusal: ProviderReadiness?, keeps: (any Sendable)?) {
        self.backend = backend
        self.refusal = refusal
        self.keeps = keeps
    }
}

/// **Makes the provider a source names**, the way the app makes it: the reader's CLI found where they put it and
/// started in an empty directory of this app's, or their endpoint with its key read from the Keychain on every call.
///
/// A value, so the router can be handed another: a test's, which finds a fake CLI, routes an endpoint through a stub,
/// or answers in-process.
public struct ProviderFactory: Sendable {
    let make: @Sendable (ProviderSource) async -> ProviderBuild

    /// The app's: the CLIs where the reader's installers put them, the endpoint's key in this app's Keychain items.
    public static let standard = ProviderFactory(credentials: KeychainCredentialStore())

    init(credentials: any CredentialStore) {
        self.init(locator: .standard, credentials: credentials, configuration: .standard,
                  endpointSession: { .ephemeral }, scratch: { ScratchDirectory() }, events: { _ in })
    }

    /// The same parts, each the caller's: how a test finds a fake CLI, sees its process's events, and routes an
    /// endpoint's session through a stub or a proxy of its own.
    init(locator: CLILocator, credentials: any CredentialStore, configuration: ResidentConfiguration,
         endpointSession: @escaping @Sendable () -> URLSessionConfiguration,
         scratch: @escaping @Sendable () -> ScratchDirectory?,
         events: @escaping @Sendable (ResidentEvent) -> Void) {
        make = { source in
            switch source {
            case .local:
                // Not a provider: the router asks the local model, and nothing is made or refused.
                return ProviderBuild(backend: nil, refusal: nil, keeps: nil)
            case .claudeCLI(let path, let model):
                return await Self.cli(.claude, at: path, locator: locator, scratch: scratch) { found, directory in
                    ClaudeCLIProvider(executable: found.executable, model: model, workingDirectory: directory,
                                      searchPath: found.searchPath, configuration: configuration, events: events)
                }
            case .codexCLI(let path, let model):
                return await Self.cli(.codex, at: path, locator: locator, scratch: scratch) { found, directory in
                    CodexCLIProvider(executable: found.executable, model: model, workingDirectory: directory,
                                     searchPath: found.searchPath, configuration: configuration, events: events)
                }
            case .endpoint(let url, let model):
                // The one parse of the reader's address — the one their key's account is read from too — and what is
                // sent where is judged from the same text by `RemoteDisclosure`, which reads it failing closed.
                guard let address = EndpointAddress(url), !model.isEmpty else {
                    return ProviderBuild(refusal: .endpointUnusable)
                }
                return ProviderBuild(backend: OpenAICompatibleProvider(
                    endpoint: address, model: model, credentials: credentials,
                    timeout: OpenAICompatibleProvider.defaultTimeout, sessionConfiguration: endpointSession(),
                    responseByteLimit: OpenAICompatibleProvider.responseByteLimit))
            }
        }
    }

    /// The reader's `tool`, found and started in an empty directory of its own with the `PATH` it was found with — or
    /// what they must do where it is not there. The directory is kept by the build, so it is removed when the provider
    /// it was made for is let go.
    private static func cli(_ tool: CLITool, at override: String?, locator: CLILocator,
                            scratch: @Sendable () -> ScratchDirectory?,
                            start: ((executable: URL, searchPath: String), URL) -> any ProviderBackend) async
        -> ProviderBuild {
        let found: (executable: URL, searchPath: String)
        switch await locator.locate(tool, override: override) {
        case .found(let executable, let source):
            found = (executable, locator.searchPath(for: executable, source: source))
        case let missing: return ProviderBuild(refusal: .cli(CLIReadiness(missing) ?? .notInstalled))
        }
        // A directory that could not be made is a source that cannot be started, said as one that did not answer.
        guard let directory = scratch() else { return ProviderBuild(refusal: .cli(.unavailable(.unreachable))) }
        return ProviderBuild(backend: start(found, directory.url), refusal: nil, keeps: directory)
    }

    /// A factory that makes whatever `make` makes — a test's own backend, answering in-process.
    init(make: @escaping @Sendable (ProviderSource) async -> ProviderBuild) {
        self.make = make
    }
}
