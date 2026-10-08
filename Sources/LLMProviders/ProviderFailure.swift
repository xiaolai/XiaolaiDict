import ModelKit

/// **Why a provider did not answer, as a kind — never as a message.**
///
/// No case carries what the server said, a header, or the key: a body can echo the request, which holds the reader's
/// sentence, and an error description is the first thing a log or an instrument prints. `badShape`'s reason is one of
/// this module's own fixed phrases (or a status code), so it says which way the answer was wrong and nothing it held.
/// The words a reader is shown for each kind are the view layer's (ADR-0025).
public enum ProviderFailure: Error, Equatable, Sendable {
    /// No connection, a refused one, a lost one, or a server error (5xx): try again later, or check the endpoint.
    case unreachable
    /// The server refused the key (401, 403), or the key could not be read or could not be sent as a header.
    case unauthorised
    /// The endpoint has no such model (404, or an error code saying so).
    case modelNotFound
    /// The server asked us to slow down (429) — and a subscription's limit is shared across the reader's apps.
    case rateLimited
    /// The model declined: a content filter, or a refusal in its answer. The model's own abstention.
    case refused
    /// An answer this provider cannot read, or a request the server would not take for a reason none of the above
    /// names. The reason is a fixed phrase of this module's or a status code, never anything the server sent.
    case badShape(String)
    /// The request outlived its timeout.
    case timedOut
    /// The caller gave up on the request.
    case cancelled

    /// **What the ladders already fall through on** (plan §7): they take a provider unchanged because each of these
    /// is a `ModelFailure` they know. Only `.refused` keeps its meaning — the model's own abstention; every other kind
    /// is "this backend did not answer", with a short reason that names the kind and holds nothing it was sent.
    public static func modelFailure(for failure: ProviderFailure) -> ModelFailure {
        switch failure {
        case .refused: .refused
        case .unreachable: .generationFailed("unreachable")
        case .unauthorised: .generationFailed("unauthorised")
        case .modelNotFound: .generationFailed("model not found")
        case .rateLimited: .generationFailed("rate limited")
        case .badShape(let reason): .generationFailed("bad shape: \(reason)")
        case .timedOut: .generationFailed("timed out")
        case .cancelled: .generationFailed("cancelled")
        }
    }
}
