/// One dictionary's entry for a term, as Dictionary.app renders it.
public struct DictionaryEntry: Codable, Sendable, Equatable {
    /// How the entry's headword relates to the term that was looked up.
    public enum Match: String, Codable, Sendable {
        /// The headword is the term, up to case.
        case exact
        /// The headword is the term's dictionary form: "running" answered with "run".
        case dictionaryForm
        /// Another headword altogether — a near match. Said so in the panel, so it is never
        /// mistaken for the term's own entry.
        case otherHeadword
        /// The dictionary did not say which headword it answered with.
        case headwordUnknown
    }

    /// The dictionary's display name, e.g. "New Oxford American Dictionary".
    public let dictionary: String
    /// The headword the dictionary answered with; the term itself when it did not say (`match`
    /// is then `.headwordUnknown`).
    public let headword: String
    public let match: Match
    /// A complete XHTML document with the dictionary's own stylesheet inlined — renderable as is,
    /// with nothing to fetch from disk.
    public let html: String

    /// `term` is what was looked up; the match is worked out from it rather than asserted.
    public init(dictionary: String, headword: String?, lookedUp term: String, html: String) {
        self.dictionary = dictionary
        self.headword = headword ?? term
        self.match = Self.match(of: headword, for: term)
        self.html = html
    }

    private static func match(of headword: String?, for term: String) -> Match {
        guard let headword else { return .headwordUnknown }
        if term.lowercased() == headword.lowercased() { return .exact }
        // Only a differing headword needs the tagger.
        return Lemmatizer.lemma(of: term, in: nil).text == Lemmatizer.canonical(headword) ? .dictionaryForm : .otherHeadword
    }
}

/// App → dictionary service.
public struct LookupRequest: Codable, Sendable, Equatable {
    /// Longer than this, in characters, is a passage, not a word or phrase to look up. The app
    /// refuses such a selection; the service refuses such a request, because it cannot know that
    /// every caller did.
    public static let maximumLength = 80

    public let term: String

    public init(term: String) {
        self.term = term
    }
}

/// Dictionary service → app. A failure is a value rather than a dropped connection, so the app
/// can tell "the service answered, and found nothing" from "the service could not answer".
public enum LookupReply: Codable, Sendable, Equatable {
    /// At least one dictionary has the term. `unreadable` names dictionaries that also had it but
    /// whose entry could not be read — reported, not silently dropped.
    case entries(NonEmpty<DictionaryEntry>, unreadable: [String])
    /// No active dictionary has the term.
    case notFound
    case failure(LookupFailure)
}

/// Why the service could not answer. Typed, so a caller can treat a bad request differently from a
/// broken private API; `description` is the text for the reader.
public enum LookupFailure: Codable, Sendable, Equatable, CustomStringConvertible {
    /// The request itself was unusable: blank, or longer than `LookupRequest.maximumLength`.
    case invalidRequest(String)
    /// DictionaryServices, or one of its private symbols, is missing or answered with something
    /// this code does not understand — a macOS update changed it.
    case dictionaryServicesUnavailable(String)
    /// Dictionaries had the term, but not one of their entries could be read.
    case unreadableEntries(dictionaries: [String])

    public var description: String {
        switch self {
        case .invalidRequest(let why): "invalid request: \(why)"
        case .dictionaryServicesUnavailable(let why): "DictionaryServices unavailable: \(why)"
        case .unreadableEntries(let names): "entries found but unreadable in \(names.joined(separator: ", "))"
        }
    }
}
