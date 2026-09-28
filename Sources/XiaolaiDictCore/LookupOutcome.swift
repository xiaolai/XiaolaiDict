import DictionaryModel
import Foundation
import XiaolaiDictBase

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

/// What one lookup came back with: the word's own answer, and the phrase the reader was standing in.
///
/// **Two fields, never merged** — the same rule as `LookupAnswer` on the wire, kept on this side of it so
/// the app cannot accidentally do the merging the protocol refused to. *take* and
/// *take something into account* are different words to a reader, and a card that received their senses in
/// one list could not tell them apart.
public struct LookupResolution: Sendable, Equatable {
    public let word: LookupOutcome
    public let phrase: PhraseAnswer

    public init(word: LookupOutcome, phrase: PhraseAnswer = .notAsked) {
        self.word = word
        self.phrase = phrase
    }
}
