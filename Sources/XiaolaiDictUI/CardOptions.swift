import AppKit
import SwiftUI

/// How the looked-up word is picked out of the reader's own sentence.
///
/// The word always carries its own colour; this is only how it is *set*. Weight and slant do
/// different things to a line of prose — bold pulls the eye before it reads, italic marks the word
/// as it passes — and which one a reader wants is not something to decide for them.
public enum WordEmphasis: String, CaseIterable, Codable, Sendable {
    case italic
    case bold
    case boldItalic

    public var label: String {
        switch self {
        case .italic: return String(localized: "Italic")
        case .bold: return String(localized: "Bold")
        case .boldItalic: return String(localized: "Bold Italic")
        }
    }

    var weight: Font.Weight { self == .italic ? .regular : .semibold }
    var isItalic: Bool { self != .bold }
}

/// The reader's choices about what a card shows, as opposed to how large it is.
struct CardOptions: Equatable, Sendable {
    /// **Off by default.** The time a word was looked up is a fact the ledger keeps and the reader
    /// almost never wants: the day is already the group the card sits in, and to the minute is
    /// precision nobody reviews by. It is a switch rather than a deletion because it is occasionally
    /// exactly what someone is looking for.
    var showsTime = false
    /// **Off by default.** The icon already says where a word was read, and at a glance it says it
    /// faster than the name does. The name is there for the reader who does not recognise an icon,
    /// or who has two browsers.
    var showsPlaceName = false
    var emphasis = WordEmphasis.italic
}

extension EnvironmentValues {
    @Entry var cardOptions = CardOptions()
}

/// Opens the word in Apple's own Dictionary, at that word's entry.
///
/// `dict://` — checked rather than assumed: the scheme resolves to Dictionary.app on this system.
/// The word is percent-encoded, because a looked-up term can contain a space, and a URL built by
/// interpolation would silently fail to open for exactly the words worth opening.
@MainActor
enum SystemDictionary {
    static func url(for term: String) -> URL? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "dict://\(encoded)")
    }

    static func open(_ term: String) {
        guard let url = url(for: term) else { return }
        NSWorkspace.shared.open(url)
    }

    /// **The tooltip on the button that does it, wherever one is drawn.** Written out on the lookup
    /// card and again on a history card, and the two did not reach the translator alike: the
    /// drawer's was a `Text` literal and was extracted, the card's arrived as a `String` through
    /// `Text`'s verbatim overload and was not.
    static var openHelp: Text { Text("Open in Dictionary") }
}

/// The reader's word for a part of speech, from the dictionaries' word for it.
///
/// Translated here rather than at the source on purpose. What the ledger stores and what
/// `Lemmatizer` answers is the vocabulary a dictionary blocks its senses by, so it can be compared
/// against `d:pos` without a mapping table; localising *that* would make a stored value depend on
/// the machine's language, which is the kind of thing that only ever breaks for someone else.
enum PartOfSpeechLabel {
    static func reader(_ stored: String?) -> String? {
        switch stored {
        case "noun": return String(localized: "noun")
        case "verb": return String(localized: "verb")
        case "adjective": return String(localized: "adjective")
        case "adverb": return String(localized: "adverb")
        // A vocabulary this does not know is shown as it is rather than dropped: it came from a
        // dictionary, and a reader can read it.
        default: return stored
        }
    }
}
