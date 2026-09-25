import XiaolaiDictCore

/// **Which entries the reader can turn to, named so no two read alike.**
///
/// The footer used to draw one capsule per entry labelled with its dictionary's name, and that was
/// wrong twice over.
///
/// - **It could not name its own items.** `showing` indexes *entries*, and one dictionary contributes
///   several: NOAD answers *fine* with four, and `DictionaryEntry.collapsingRepeatedRecords` merges
///   only same-*id* records, so all four survive deliberately — "the private API returns several
///   records per dictionary, and every one reaches the reader". Labelled by dictionary alone, the row
///   drew four capsules reading "New Oxford American Dictionary" and a reader picking among them was
///   guessing. Collapsing by dictionary instead would have lost three of the four, which breaks that
///   same invariant at the last step.
/// - **It did not fit.** Measured 2026-09-25: the eight dictionary names enabled on this developer's
///   Mac need **1,282 pt** at `text.micro` with capsule padding, in a card 396 pt wide and 312 pt at
///   its minimum. It overflowed at four.
///
/// So the footer wraps and the control is a **disclosure**, not a menu — the same gesture the card
/// already uses for "12 other senses". Each entry gets a full row, which is what makes room for a
/// label that distinguishes it; and a disclosure opens no second window, so it cannot meet the
/// click-away dismissal that a popup outside the panel's frame might.
struct DictionaryList: Equatable {
    struct Row: Equatable, Identifiable {
        /// Index into the entries the panel holds, which is what `showing` selects by.
        let index: Int
        let dictionary: String
        /// The headword this entry is — **only where its dictionary answered more than once**. A
        /// dictionary that answered once is named by itself; a headword on every row would be noise on
        /// the ordinary card. NOAD prints homographs as *fine¹*, *fine²*, so the heading is what
        /// actually separates its four entries.
        let headword: String?

        var id: Int { index }

        /// What the row says. The dictionary first, because that is what the reader is choosing
        /// between when there is a choice of dictionaries at all.
        var label: String {
            guard let headword else { return dictionary }
            return "\(dictionary) · \(headword)"
        }
    }

    let rows: [Row]

    /// **How many *other* dictionaries answered — distinct dictionaries, never entries.** NOAD
    /// answering *fine* four times is one other dictionary, and a count of entries would say four.
    let otherDictionaries: Int

    /// Whether there is anything to choose. One entry is not a choice; **four entries from one
    /// dictionary are**, which a count of dictionaries alone would have missed.
    var isWorthShowing: Bool { rows.count > 1 }

    init(of entries: [DictionaryEntry]) {
        let names = entries.map(\.dictionary.name)
        // Counted before the rows are built: whether a headword is needed is a property of how many
        // times that dictionary answered, not of the entry in hand.
        var appearances: [String: Int] = [:]
        for name in names { appearances[name, default: 0] += 1 }
        rows = entries.enumerated().map { index, entry in
            Row(
                index: index, dictionary: entry.dictionary.name,
                headword: (appearances[entry.dictionary.name] ?? 0) > 1 ? entry.heading : nil)
        }
        otherDictionaries = max(Set(names).count - 1, 0)
    }
}

extension DictionaryEntry {
    /// The headword as the card heads itself with it — through `EntryNode`, the same construction
    /// `EntryPresentation.heading` uses, so a row in this list and the card it opens cannot name the
    /// entry two different ways.
    ///
    /// It carries the publisher's homograph marker, and that marker is the whole point: *fine¹* against
    /// *fine²* is the only thing that separates two entries of one dictionary.
    var heading: String { EntryNode(headword: headword, homograph: homograph).label }
}
