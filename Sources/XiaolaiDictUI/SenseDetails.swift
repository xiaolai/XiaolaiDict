import DictionaryModel
import SwiftUI

/// **What a bilingual entry's senses say beyond their labels, for the default card's own disclosure**
/// (plan-card-refinements WI-4, and the owner's decision of 2026-10-09 to show it on the default card as well).
///
/// The compact card's expand already draws it, in `DictionaryDetailsView`; the default card had no expand and so showed
/// none of it. It goes behind a disclosure of the card's own — **closed whenever a card arrives, and opened only by the
/// reader** (D5) — and never behind "N other meanings", which the card opens by itself wherever it cannot name the
/// meaning, as it does for every auxiliary dictionary's entry: there the text would have been shown unasked.
///
/// Display only: built from `SensePresentation.display`, never from `label`, `key` or the hash, so nothing that keys,
/// hashes or saves a sense moves.
public struct SenseDetails: Equatable, Sendable {
    /// One sense with something to say beyond its label.
    public struct Row: Equatable, Identifiable, Sendable {
        public let id: String
        /// The number the dictionary prints, as the other meanings show it.
        public let ordinal: Int
        /// `SenseDisplayLines`' lines, in their order: the translations with their indicators, then the rest.
        public let lines: [String]
    }

    /// One part-of-speech block's rows, in the entry's own order — numbering restarts in each, as for the other
    /// meanings (`LookupCard.alternativeGroups`).
    public struct Group: Equatable, Identifiable, Sendable {
        public let block: Int
        public let partOfSpeech: String?
        public let rows: [Row]

        public var id: Int { block }
    }

    public let groups: [Group]

    public var isEmpty: Bool { groups.isEmpty }

    /// Whether the groups are named: only where the numbering restarts, the rule the other meanings follow.
    public var namesGroups: Bool { groups.count > 1 }

    /// **Every sense of the entry, the one the card leads with included**, in the entry's order — and only the senses
    /// whose display data says more than the label does. A monolingual sense has none (`display == nil`), and a
    /// bilingual sense whose one translation *is* its label has nothing to add.
    public init(senses: [SensePresentation]) {
        var groups: [Group] = []
        for sense in senses {
            guard let display = sense.display, !display.isEmpty else { continue }
            let row = Row(id: sense.id, ordinal: sense.ordinal, lines: SenseDisplayLines.of(display))
            if let last = groups.last, last.block == sense.block {
                groups[groups.count - 1] = Group(block: last.block, partOfSpeech: last.partOfSpeech, rows: last.rows + [row])
            } else {
                groups.append(Group(block: sense.block, partOfSpeech: sense.partOfSpeech, rows: [row]))
            }
        }
        self.groups = groups
    }

    public static let none = SenseDetails(senses: [])
}

/// **The default card's details, open** — each sense's number and the lines its label left out.
struct SenseDetailsView: View {
    @Environment(\.scale) private var scale
    let details: SenseDetails

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.line) {
            ForEach(details.groups) { group in
                if details.namesGroups, let partOfSpeech = PartOfSpeechLabel.reader(group.partOfSpeech) {
                    Text(verbatim: partOfSpeech)
                        .font(.system(size: scale.text.small).italic())
                        .foregroundStyle(.secondary)
                        .padding(.leading, scale.space.inline)
                        .padding(.top, scale.space.inline)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(group.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                        Text(row.ordinal, format: .number)
                            .font(.system(size: scale.text.small).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: scale.space.ordinal, alignment: .trailing)
                        VStack(alignment: .leading, spacing: scale.space.tight) {
                            // By position: two lines of one sense can read the same, and the list is drawn whole.
                            ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in
                                Text(verbatim: line)
                                    .font(.system(size: scale.text.body))
                                    .lineSpacing(scale.text.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, scale.space.inline)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.vertical, scale.space.line)
    }
}
