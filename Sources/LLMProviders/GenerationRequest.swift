import Foundation

/// **One question to a language model, as text** — what every provider is handed, whether it is an HTTP endpoint or a
/// CLI the reader signed in to (ADR-0053).
///
/// Text and not a `ModelRequest`: deciding what a request may hold — what `RemoteDisclosure` lets a tier see, which
/// prompt `ModelPrompt` builds — is the caller's (P3's `ProviderClient`), done once, before anything reaches a
/// provider. A provider is transport; it never sees a sense list it could leak, only the prompt it was given.
public struct GenerationRequest: Sendable, Equatable {
    /// The system instructions — the existing instruction texts, so the measured prompts carry over. Empty is none.
    public let instructions: String
    /// The question itself, already flattened and cut by `ModelPrompt`.
    public let prompt: String
    /// The most the answer may run to, in tokens: never a backend's default of thousands.
    public let maxTokens: Int
    /// 0 for a sense choice, which must not vary run to run; sampled for prose.
    public let temperature: Double

    public init(instructions: String, prompt: String, maxTokens: Int, temperature: Double) {
        self.instructions = instructions
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

/// **A language model that answers in text** — the one shape the router (P3) needs of every source, so an endpoint,
/// a resident CLI and a test double are interchangeable behind it.
///
/// It throws `ProviderFailure` and nothing else, so the router maps every failure without a default branch that
/// could hide a new one.
public protocol TextGenerating: Sendable {
    func generate(_ request: GenerationRequest) async throws(ProviderFailure) -> String
}
