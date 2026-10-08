import LLMProviders
import ModelKit
import Testing

/// **A provider's failure becomes the `ModelFailure` the ladders already fall through on** (plan §7): the ladders take
/// a provider unchanged because every failure is one they know. Only the model's own abstention keeps its meaning —
/// everything else is "this backend did not answer", with a short reason that names the kind and nothing more.
struct ProviderFailureTests {
    @Test func eachFailureMapsToTheLaddersVocabulary() {
        let cases: [(ProviderFailure, ModelFailure)] = [
            (.unreachable, .generationFailed("unreachable")),
            (.unauthorised, .generationFailed("unauthorised")),
            (.modelNotFound, .generationFailed("model not found")),
            (.rateLimited, .generationFailed("rate limited")),
            (.refused, .refused),
            (.badShape("no choices"), .generationFailed("bad shape: no choices")),
            (.timedOut, .generationFailed("timed out")),
            (.cancelled, .generationFailed("cancelled")),
        ]
        for (failure, expected) in cases {
            #expect(ProviderFailure.modelFailure(for: failure) == expected, "\(failure)")
        }
    }

    /// **Only a refusal is a refusal.** `.refused` is the model declining, which the ladders report as its own
    /// abstention; a transport or account failure reported as one would read as the model's judgement.
    @Test func onlyARefusalMapsToARefusal() {
        let failures: [ProviderFailure] = [
            .unreachable, .unauthorised, .modelNotFound, .rateLimited, .refused, .badShape("x"), .timedOut, .cancelled,
        ]
        let refusals = failures.filter { ProviderFailure.modelFailure(for: $0) == .refused }
        #expect(refusals == [.refused])
    }
}
