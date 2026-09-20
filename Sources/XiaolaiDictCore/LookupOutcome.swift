import Foundation

/// What a lookup produced, and how it was obtained. A fallback must never render as confidently as
/// the real thing, so the outcome says which it is.
public enum LookupOutcome: Sendable, Equatable {
    /// Rich entries from the dictionary service. `unreadable` names dictionaries that had the term
    /// but whose entry could not be read.
    case entries(NonEmpty<DictionaryEntry>, unreadable: [String])
    /// The service could not answer. This is the public API's plain text, and why the service failed.
    case plainText(String, serviceFailure: String)
    /// No dictionary has the term. `serviceFailure` is set when the service could not be asked.
    case notFound(serviceFailure: String?)

    public var result: LookupResult {
        switch self {
        case .entries, .plainText: .found
        case .notFound: .notFound
        }
    }

    /// A miss is the service's own answer only when the service was asked; otherwise the fallback
    /// missed too, which is a weaker "not found".
    public var answeredBy: AnswerSource {
        switch self {
        case .entries, .notFound(serviceFailure: nil): .dictionaryService
        case .plainText, .notFound: .publicFallback
        }
    }
}
