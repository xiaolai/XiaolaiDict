/// The dictionary service's wire protocol — what the app asks and what the service answers.
///
/// Its own file, and **beside the domain model rather than inside it**: these six types are what
/// `XiaolaiDictService` and `DictionaryBridge` decode, and they lived in `DictionaryEntry.swift`
/// next to the entry model itself. Nothing was wrong with that until the module split, where a file
/// holding both would have made "the service links the entry model" and "the service links the wire
/// protocol" one fact instead of two. Same target, same types, one boundary now visible.

/// What the app asks the dictionary service for. An envelope rather than a bare `LookupRequest`,
/// because the menu needs to list the enabled dictionaries and say what each can key, and that is
/// not a lookup.
public enum ServiceRequest: Codable, Sendable, Equatable {
    case lookup(LookupRequest)
    /// Every enabled dictionary, in the reader's order, with what each can address.
    ///
    /// `reprobing` discards the service's cached answer first. The probe parses real entries —
    /// Longman's *hold* alone is 625 KB — so it runs once per service process, which is right for
    /// a menu opening and wrong for the one case that has to see a change: the setup board tells a
    /// reader to enable a dictionary in Dictionary.app and then promises to notice when they come
    /// back. A cache that outlives that promise makes it false.
    case dictionaries(reprobing: Bool = false)
}

/// What the dictionary service answers with. Typed per request, so a reply can never be read as
/// the answer to a different question.
public enum ServiceReply: Codable, Sendable, Equatable {
    case lookup(LookupReply)
    case dictionaries([DictionaryCapability])
}

/// One enabled dictionary and the finest rung it can key a study item to — which is what makes
/// "choosing this one costs you sense-level study" sayable in the menu before the reader chooses.
public struct DictionaryCapability: Codable, Sendable, Equatable {
    public let identity: DictionaryIdentity
    /// The best rung reached on the words probed. `.none` means the dictionary marks senses with
    /// nothing a parser can key to, so it can only ever be studied at entry level.
    public let senseKeyKind: SenseKeyKind
    /// False when no probe word was found in this dictionary at all, so `senseKeyKind` is a floor
    /// rather than a measurement — said plainly instead of passed off as a finding.
    public let probed: Bool
    /// What the bundle declares about its languages, empty where it declares nothing.
    ///
    /// Empty is an ordinary state, not a defect: no sideloaded conversion carries
    /// `DCSDictionaryLanguages`, and three of the seven dictionaries enabled on the development Mac
    /// are sideloaded. An Apple asset that declares none reads the same way here, which is why
    /// `indexes` below is what a reader's list is finally classified by.
    public let languages: [DictionaryLanguages]
    /// The writing systems this dictionary was measured to answer in — the signal that still works
    /// when `languages` is empty. Says what it indexes, never what it explains in.
    public let indexes: Set<ProbeScript>

    public init(
        identity: DictionaryIdentity, senseKeyKind: SenseKeyKind, probed: Bool,
        languages: [DictionaryLanguages] = [], indexes: Set<ProbeScript> = []
    ) {
        self.identity = identity
        self.senseKeyKind = senseKeyKind
        self.probed = probed
        self.languages = languages
        self.indexes = indexes
    }

    /// Whether this dictionary is one a reader of `language` would study English from: English
    /// headwords, explained in their own language.
    ///
    /// Answers from the declared languages alone. A dictionary that declares nothing answers false
    /// however it probed, because a records probe can say a bundle indexes Latin script and cannot
    /// say what language it explains in — and a monolingual English dictionary and an
    /// English-Chinese one are indistinguishable by that signal.
    public func teachesEnglish(to language: String) -> Bool {
        languages.contains { $0.indexesEnglish(explainedIn: language) }
    }

    /// What the menu prints beside the dictionary's name.
    public var note: String {
        guard probed else { return "not yet known" }
        switch senseKeyKind {
        case .publisher: return "senses"
        case .position: return "senses, by position"
        case .none: return "whole entries only"
        }
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
