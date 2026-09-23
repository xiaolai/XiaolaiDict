import XiaolaiDictCore

/// **Which sense the reader tapped, per entry.**
///
/// A tap is a fact (`chosen_by: reader`) and it replaces the selector's hypothesis on the card as
/// well as in the ledger — the copy, the pin, the translation and the explanation are all built
/// from the card as it is drawn. Held as a single value it was wrong twice over, and both were
/// found by hand rather than by a test: a tap in an auxiliary entry became the *primary* entry's
/// mark, and two dictionaries whose sense keys happen to collide confirmed the wrong sense
/// outright.
///
/// It is a value type rather than three private methods on the view because a view's `@State` and
/// its `onChange` conditions cannot be asked anything from a test. Nothing tested
/// `LookupPanelContent` at all — the per-entry filing, the identity that separates two
/// dictionaries and the rule about the selector's late answer were each a few lines inside a view
/// body, and two of the three were defects while every unit test in the suite passed.
///
/// It does **not** decide whether a sense may be confirmed at all: a dictionary that cannot key a
/// sense must never have one presented as confirmed, and the caller checks that first by building
/// the encounter — a tap that cannot become a ledger row does not become a mark either.
public struct PanelSelection: Equatable {
    private var choices: [String: SenseMark] = [:]

    public init() {}

    /// Which entry a tap belongs to: the dictionary that issued the sense, and the entry inside it.
    /// Both halves are needed — one dictionary answers a word with several entries, and a sense key
    /// is only meaningful inside the dictionary that issued it. The separator is a character no
    /// identifier and no headword carries, so one pair of halves cannot spell another pair's
    /// identity.
    public static func identity(of entry: DictionaryEntry) -> String {
        "\(entry.dictionary.key)\u{1}\(entry.entryKey ?? "")"
    }

    /// The reader's tap, recorded against the entry it was made in.
    public mutating func choose(_ key: String, in entry: DictionaryEntry) {
        choices[Self.identity(of: entry)] = .chosen(key: key, by: .reader)
    }

    /// What the card draws and every question is built from: the reader's own tap **in this entry**
    /// where there is one, and the selector's proposal otherwise.
    public func mark(for entry: DictionaryEntry, proposing proposal: SenseMark?) -> SenseMark? {
        choices[Self.identity(of: entry)] ?? proposal
    }

    /// Whether the selector's late answer still changes what this entry shows. Where the reader has
    /// chosen here it does not, and clearing the panes on it took away a translation they had asked
    /// for *after* choosing.
    public func hasChosen(in entry: DictionaryEntry) -> Bool {
        choices[Self.identity(of: entry)] != nil
    }
}
