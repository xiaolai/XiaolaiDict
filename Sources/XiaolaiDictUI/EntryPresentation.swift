import Foundation
import XiaolaiDictCore

/// How far a sense is claimed to be the one the reader read. The whole point of the type is that
/// the three are not interchangeable, and that the weakest is the default.
public enum SenseStanding: Equatable {
    /// A fact: the reader tapped it, or the entry has exactly one sense so nothing was chosen.
    case confirmed(SenseChoice)
    /// A hypothesis: XiaolaiDict's selector proposed it. It is drawn differently and recorded separately,
    /// and a card built on it says so.
    case proposed
    /// Nothing is claimed about this sense.
    case unclaimed

    public var isConfirmed: Bool {
        guard case .confirmed = self else { return false }
        return true
    }

    /// What the standing means, in the reader's words. **One wording for both surfaces** — the
    /// lookup card had these privately and the drawer had its own, and the two described the same
    /// lookup differently: the drawer called an entry with no sense settled "the sense XiaolaiDict
    /// guessed".
    public var explanation: String {
        switch self {
        case .confirmed(.reader): String(localized: "You chose this sense")
        case .confirmed(.onlySense): String(localized: "The only sense in this entry")
        case .confirmed: String(localized: "Confirmed")
        case .proposed: String(localized: "A guess — not confirmed")
        case .unclaimed: String(localized: "Shown without a claim")
        }
    }
}

public extension SenseNote {
    /// How far the ledger claims this sense — the lookup card's three standings, not a yes/no.
    ///
    /// The drawer used `isConfirmed` alone and drew everything else as a guess, so an entry where
    /// no sense was settled at all wore a `?` and "the sense XiaolaiDict guessed". Nothing was guessed.
    /// A recorded sense with no provenance is unclaimed too, never promoted to a proposal: the
    /// weakest standing is the default.
    var standing: SenseStanding {
        guard ordinal != nil else { return .unclaimed }
        switch chosenBy {
        case .reader: return .confirmed(.reader)
        case .onlySense: return .confirmed(.onlySense)
        case .model: return .proposed
        case nil: return .unclaimed
        }
    }

    /// Which dictionary and which sense — never what it says (C2) — with `?` on the selector's
    /// proposal and on nothing else.
    var badge: String {
        standing == .proposed ? "\(dictionary) \(label)?" : "\(dictionary) \(label)"
    }
}

/// One sense, as the popup presents it.
public struct SensePresentation: Equatable, Identifiable {
    public let key: String?
    public let ordinal: Int
    public let partOfSpeech: String?
    public let label: String
    public let keyKind: SenseKeyKind
    public let standing: SenseStanding
    /// The reader has been on this sense before (`feature-ledger-ux.md` C3) — which no surveyed
    /// dictionary shows. It is *whether*, never *what*: the earlier gloss is not carried here.
    public let metBefore: Bool

    public var id: String { key ?? "\(ordinal)" }

    /// A position key is a weaker claim than a publisher's and must read as one (I4).
    public var isPositional: Bool { keyKind == .position }
}

/// One entry, as the popup presents it: the heading, what it is, how it sounds, and its senses.
///
/// The entry's *body* is still rendered from the dictionary's own document — the entry is the
/// publisher's, not XiaolaiDict's (B7). This is the chrome XiaolaiDict draws around it.
public struct EntryPresentation: Equatable {
    public let dictionary: DictionaryIdentity
    /// The headword with its homograph number raised: *fine²*.
    public let heading: String
    /// The parts of speech this entry has blocks for, in order, without repeats.
    public let partsOfSpeech: [String]
    /// What the entry prints for pronunciation (`d:prn`).
    public let pronunciations: [String]
    public let senses: [SensePresentation]
    /// The finest rung this entry's senses can be addressed at.
    public let senseKeyKind: SenseKeyKind

    /// Whether this entry can be studied at sense level at all. A dictionary that marks senses with
    /// nothing a parser can key to cannot, and the popup says so rather than offering sense rows it
    /// cannot stand behind.
    public var canKeySenses: Bool { senseKeyKind != SenseKeyKind.none }

    public init(entry: DictionaryEntry, mark: SenseMark?, met: Set<StudyItem>) {
        dictionary = entry.dictionary
        heading = EntryNode(
            index: 0, headword: entry.headword, homograph: entry.homograph, note: nil,
            senseKeyKind: entry.senseKeyKind, senses: []).label
        var seen: Set<String> = []
        partsOfSpeech = entry.blocks.compactMap(\.partOfSpeech).filter { seen.insert($0).inserted }
        pronunciations = entry.pronunciations
        senseKeyKind = entry.senseKeyKind

        senses = entry.blocks.flatMap { block in
            block.senses.map { sense in
                SensePresentation(
                    key: sense.key, ordinal: sense.path.ordinal, partOfSpeech: block.partOfSpeech,
                    label: sense.label, keyKind: sense.keyKind,
                    standing: Self.standing(of: sense, in: entry, mark: mark),
                    metBefore: entry.entryKey.map {
                        met.contains(StudyItem(
                            dictionary: entry.dictionary.key, entryID: $0, senseKey: sense.key,
                            senseKeyKind: sense.keyKind))
                    } ?? false)
            }
        }
    }

    /// A sense a dictionary cannot key is **never** presented as confirmed, however it was marked:
    /// "this is the sense you read" is a claim that needs a key to be true of.
    private static func standing(
        of sense: DictionarySense, in entry: DictionaryEntry, mark: SenseMark?
    ) -> SenseStanding {
        guard sense.keyKind != SenseKeyKind.none else { return .unclaimed }
        guard case .chosen(let key, let by) = mark, key == sense.key else { return .unclaimed }
        return by == .model ? .proposed : .confirmed(by)
    }
}

/// The memory strip: that the reader has been here before, when, and where — and **never what it
/// meant last time**.
///
/// It costs nothing, because the ledger already has it, and it lands at the moment of a naturally
/// occurring failed recall (`feature-ledger-ux.md` C1). It is absent on a first lookup: no empty
/// state, no "0 previous" (C4).
public struct MemoryStrip: Equatable {
    /// 2 on a second lookup. The strip does not exist below that.
    public let occasion: Int
    public let earlier: [PriorEncounter]

    /// Nil on a first lookup, so there is nothing to render rather than an empty box.
    public init?(_ prior: PriorEncounters) {
        guard prior.isWorthShowing else { return nil }
        occasion = prior.occasion
        earlier = prior.occasions
    }

    /// "3rd lookup".
    public var headline: String {
        "\(occasion)\(Self.ordinalSuffix(occasion)) lookup"
    }

    /// Where and when the earlier ones were — the most recent first, and never more than this many,
    /// because a strip that grows without bound stops being a strip.
    public static let shown = 3

    public var lines: [String] {
        // Built per call rather than held in a static: `RelativeDateTimeFormatter` is not Sendable,
        // and a shared one would be mutable state reachable from any actor.
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return earlier.prefix(Self.shown).map { encounter in
            let place = [encounter.title, encounter.where].compactMap { $0 }.first
            let when = relative.localizedString(for: encounter.at, relativeTo: .now)
            return place.map { "\(when) · \($0)" } ?? when
        }
    }

    /// How many earlier encounters are not listed, so the count is never silently truncated.
    public var more: Int { max(0, earlier.count - Self.shown) }

    private static func ordinalSuffix(_ number: Int) -> String {
        switch (number % 100, number % 10) {
        case (11...13, _): "th"
        case (_, 1): "st"
        case (_, 2): "nd"
        case (_, 3): "rd"
        default: "th"
        }
    }
}
