import Foundation
import XiaolaiDictBase

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
    case lookup(LookupAnswer)
    case dictionaries([DictionaryCapability])
}

/// The word's answer, and the phrase around it.
///
/// **Two fields rather than one merged answer**, and `LookupReply` is untouched. The sense ladder's rule
/// is that `chosen_by` never merges: a phrase's senses are not the word's, and a caller that received
/// them in one list could not tell *take* from *take something into account*. Everything that already
/// switches on `LookupReply` keeps working, which is also why the phrase arrives here rather than as a
/// fourth associated value on a case.
public struct LookupAnswer: Codable, Sendable, Equatable {
    public let word: LookupReply
    public let phrase: PhraseAnswer

    public init(word: LookupReply, phrase: PhraseAnswer = .notAsked) {
        self.word = word
        self.phrase = phrase
    }
}

/// Whether the reader is standing inside a phrase, and where the answer stands if not.
///
/// **Four-valued, because "no phrase here" is one of four different facts.** A service still reading its
/// inventory, a request that carried no sentence, and a sentence with no phrase in it would all be `nil`
/// — and a failure rendering as confidently as a success is the thing this project keeps finding. The
/// reader's first lookup after the service launches is genuinely `.notReady`, and saying so is what lets
/// a card decline to claim there was nothing to find.
public enum PhraseAnswer: Codable, Sendable, Equatable {
    /// No sentence reached the service, or no anchor within it, so nothing was asked.
    case notAsked
    /// The phrase inventory is still being read. **Not the same as `.none`.**
    case notReady
    /// No dictionary's phrases could be read at all, so nothing can be looked in.
    ///
    /// **Distinct from `.notReady`, which resolves.** A reader whose every dictionary failed was told the
    /// inventory was still loading — for ever — which is a failure wearing a transient state's clothes. An
    /// abstention names itself: `.refused`, `.undecided`, `.unavailable` is the rule the sense ladder already
    /// follows, and this is the same rule one layer out.
    case unavailable
    /// Asked, and the reader is on an ordinary word.
    case none
    /// **Every phrase covering the term, best first.** Plural because length must not choose the unit:
    /// `give up` and `give up the ghost` both cover the hovered word, and which one the reader met is a
    /// question about the sentence rather than about span length. Never empty — `.none` is that answer.
    case found([PhraseHit])
}

/// One phrase found around the term, with its own entries.
public struct PhraseHit: Codable, Sendable, Equatable {
    /// The dictionary's own spelling, slots and all — `take something into account`. This is the string
    /// the entries were found under, so it is what a card must name.
    public let phrase: String

    /// Where the span sits in the sentence that was sent, UTF-16, gap included.
    public let location: Int
    public let length: Int

    public let separation: PhraseSeparation

    /// What the dictionaries could say about the phrase, which is **not** always its meaning.
    public let meaning: PhraseMeaning

    /// The phrase's own entries, where it has any. **Never merged with the word's.**
    public var entries: [DictionaryEntry] { meaning.ownEntries }

    public init(phrase: String, location: Int, length: Int,
                separation: PhraseSeparation, meaning: PhraseMeaning) {
        self.phrase = phrase
        self.location = location
        self.length = length
        self.separation = separation
        self.meaning = meaning
    }
}

/// What the dictionaries hold for a phrase: entries of its own, filings inside other words' entries, or
/// both at once — **and either way, what it means.**
///
/// **Measured, and the distinction is load-bearing** (2026-09-29, NOAD). *purple passage* is
/// `m_en_gbus0830950` and *red herring* is `m_en_gbus0853810` — entries of their own, whose senses are the
/// phrase's meaning, and which are therefore candidates for the sense ladder. *take something into account*
/// answers with `m_en_gbus0005190`, which is **`account`'s entry**: the framework returns the parent, and
/// `EntryDocument` walks only `x_xd0`/`x_xd1`, so *that* document's 6 senses are all nouns and the phrase's
/// own definition is not among them. Adding them to the candidate set would be handing the selector noise it
/// could confidently pick.
///
/// Told apart by entry id: an answered entry that is also one of the phrase's own words' entries is a
/// parent, not the phrase's. **Per entry, not per lookup** — the reader's dictionaries do not agree about
/// which phrases get their own entry, and deciding for the whole reply lost whichever ones did.
///
/// **The meaning comes from the phrase inventory, not from the entry.** A body walk reads every sub-entry's
/// own definition — *take something into account → consider something along with other factors before
/// reaching a decision* — for 9,740 of NOAD's sub-entries. So a sub-entry phrase is explained rather than
/// deferred, and this type never has to say "read it somewhere else".
public struct PhraseMeaning: Codable, Sendable, Equatable {
    /// The phrase's own entries. Their senses are the phrase's meaning, and are candidates for the ladder.
    public let ownEntries: [DictionaryEntry]

    /// Where the phrase is filed inside another word's entry. The parent's senses are **not** candidates —
    /// they are that word's — so these carry the phrase's own definitions instead.
    public let filings: [PhraseFiling]

    /// **Both, because it was one or the other and that deleted candidates.** This was an enum, and
    /// `DictionaryBridge` answered a whole lookup with a single case: one dictionary filing the phrase
    /// under a parent made the entire result a sub-entry, and another dictionary's genuine own entry for
    /// the same phrase — with the senses the ladder would have chosen among — vanished from the reply.
    /// Nothing on the lookup path may delete a candidate (`dev-docs/never-gate-always-annotate.md`).
    public init(ownEntries: [DictionaryEntry] = [], filings: [PhraseFiling] = []) {
        self.ownEntries = ownEntries
        self.filings = filings
    }

    /// Nothing at all: a phrase from the key index that no installed dictionary explains or files.
    public var isEmpty: Bool { ownEntries.isEmpty && filings.isEmpty }
}

/// Whether the phrase's words sat together, and on whose authority they were allowed not to.
///
/// **A wire copy of `PhraseSpans.Separation`, on purpose.** `DictionaryModel` crosses the XPC boundary
/// and binds nothing but `XiaolaiDictBase`; `AppleDictionaryFormat` is the service's business. The service
/// maps between the two, which is one small translation against letting the app's protocol depend on a
/// dictionary-format reader.
public enum PhraseSeparation: Codable, Sendable, Equatable {
    /// Written unbroken, as the dictionary spells it.
    case none
    /// The publisher marked a slot, and this many words of the sentence filled it.
    case marked(Int)
    /// The publisher wrote it unbroken; the split is the matcher's own inference from a particle.
    case inferred(Int)

    /// How many words were stepped over, for a caller that only needs the width.
    public var gap: Int {
        switch self {
        case .none: 0
        case .marked(let words), .inferred(let words): words
        }
    }
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

    /// Whether English can be looked up in it at all, whoever it explains to.
    ///
    /// The weaker half of `teachesEnglish(to:)`, and it earns its own name because the reader's own
    /// choice outranks the rule: someone who installs 牛津粵英雙語詞典 has said which language they read
    /// English in, and `yue` is a different language code from `zh`, so no Chinese reader matches it.
    /// The menu has always let them pick it; this is what lets the setup board stop describing it as
    /// absent.
    public var indexesEnglish: Bool {
        languages.contains { DictionaryLanguages.tag($0.index)?.languageCode?.identifier == "en" }
    }

    /// Whether it explains English **in English** — a monolingual or a thesaurus.
    ///
    /// Beside `indexesEnglish` because the pair is what distinguishes "a dictionary for a reader of
    /// another language" from "a dictionary in the language of the thing being studied". NOAD is the
    /// second, and calling it the first would describe it to a Chinese reader as a foreign-language
    /// dictionary.
    public var explainsInEnglish: Bool {
        languages.contains { DictionaryLanguages.tag($0.explains)?.languageCode?.identifier == "en" }
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

    /// **A sentence is not a term and needs its own bound.** Longer than this and it is a passage,
    /// not a reading context, and the words past it cannot be part of the phrase around the term.
    /// Enforced by the service, because it cannot know that every caller enforced it.
    public static let maximumSentenceLength = 1000

    public let term: String

    /// The sentence the term was read in, so the service can ask whether the reader is standing
    /// inside a phrase their dictionary knows. Nil where the capture had no sentence — most of the
    /// time, for a selection in an app that exposes nothing around it.
    ///
    /// **Sent rather than re-derived.** The capture already found this sentence and knows where the
    /// term sits in it; asking the service to find it again would be a second answer to a question
    /// already answered, and the two would disagree on the sentence that repeats a word.
    public let sentence: String?

    /// Where `term` sits in `sentence`, UTF-16. **Two `Int`s rather than an `NSRange`**, which is
    /// not `Codable` — and this type crosses a process boundary.
    ///
    /// Nil where the capture could not say. The service then has no anchor and asks nothing: which
    /// occurrence of a repeated word the reader pointed at is not guessed.
    public let termLocation: Int?
    public let termLength: Int?

    public init(term: String, sentence: String? = nil,
                termLocation: Int? = nil, termLength: Int? = nil) {
        self.term = term
        self.sentence = sentence
        self.termLocation = termLocation
        self.termLength = termLength
    }

    /// The term's range in the sentence, where both ends were supplied and the range is inside it.
    ///
    /// **Validated here, once.** Both fields arrive from another process; a range that overflows or
    /// runs past the sentence is a request to ignore, not one to trust and crash on.
    public var termRange: NSRange? {
        guard let sentence, let termLocation, let termLength,
              termLocation >= 0, termLength > 0,
              termLength <= sentence.utf16.count - termLocation else { return nil }
        return NSRange(location: termLocation, length: termLength)
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
