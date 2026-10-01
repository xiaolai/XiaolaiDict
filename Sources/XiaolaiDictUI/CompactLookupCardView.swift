import DictionaryModel
import SwiftUI
import XiaolaiDictCore

/// A reading preview, not a new sense selection. The original card retains every sense and claim.
struct CompactLookupSummary: Equatable {
    let senses: [SensePresentation]
    let isUncertain: Bool

    init(card: LookupCard) {
        let first: [SensePresentation]
        switch card.answer {
        case .sense(let sense), .ambiguous(let sense, _): first = [sense]
        default: first = []
        }
        var seen = Set<Meaning>()
        senses = Array((first + card.alternatives).filter { sense in
            !sense.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seen.insert(Meaning(
                    partOfSpeech: PartOfSpeechLabel.compact(sense.partOfSpeech),
                    label: sense.label.trimmingCharacters(in: .whitespacesAndNewlines))).inserted
        }.prefix(Token.Panel.compactMeaningLimit))
        switch card.answer {
        case .ambiguous: isUncertain = true
        case .sense: isUncertain = card.isHypothesis
        case .undecided: isUncertain = !senses.isEmpty
        default: isUncertain = false
        }
    }

    /// The quick card groups grammar variants; the detailed card keeps each publisher sense.
    var groups: [MeaningGroup] {
        var result: [MeaningGroup] = []
        for sense in senses {
            let partOfSpeech = PartOfSpeechLabel.compact(sense.partOfSpeech)
            let label = sense.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = result.firstIndex(where: { $0.partOfSpeech == partOfSpeech }) {
                result[index].labels.append(label)
            } else {
                result.append(MeaningGroup(partOfSpeech: partOfSpeech, labels: [label]))
            }
        }
        return result
    }

    struct MeaningGroup: Equatable {
        let partOfSpeech: String?
        var labels: [String]
        var text: String { labels.joined(separator: "；") }
    }

    private struct Meaning: Hashable {
        let partOfSpeech: String?
        let label: String
    }
}

/// The quick dictionary lookup: word, pronunciation, short meanings, then an exit to detail.
struct CompactLookupCardView: View {
    @Environment(\.scale) private var scale
    @Environment(\.closeLookup) private var close
    let card: LookupCard
    var incomplete = false
    let onMore: () -> Void

    private var summary: CompactLookupSummary { CompactLookupSummary(card: card) }

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space.column) {
            HStack(alignment: .firstTextBaseline, spacing: scale.space.line) {
                Text(verbatim: card.term)
                    .font(.system(size: scale.text.lookupWord, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: card.term))
                Spacer(minLength: scale.space.inline)
                IconButton(title: "Close lookup", symbol: "xmark", action: close)
                    .foregroundStyle(.secondary)
                IconButton(title: "Open in Dictionary", symbol: "magnifyingglass", help: SystemDictionary.openHelp) {
                    SystemDictionary.open(card.term)
                }
                .foregroundStyle(.secondary)
            }

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: scale.space.line) {
                if let pronunciation = card.pronunciation {
                    Text(verbatim: pronunciation)
                        .font(.system(size: scale.text.body))
                        .fixedSize(horizontal: false, vertical: true)
                }
                IconButton(
                    title: "Say it aloud", symbol: "speaker.wave.2",
                    help: Speech.sayItAloudHelp(for: card.term, in: card.sentence)
                ) { Speech.say(card.term, in: card.sentence) }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)

            meanings

            HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                if incomplete {
                    Label("Partial result", systemImage: "exclamationmark.circle")
                        .font(.system(size: scale.text.small))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: onMore) {
                    HStack(spacing: scale.space.line) {
                        Text("More meanings")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: scale.text.label))
                    .frame(minHeight: Token.Target.minimum)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text("Show all meanings, examples, and context"))
            }
        }
        .padding(scale.space.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var meanings: some View {
        if !summary.senses.isEmpty {
            VStack(alignment: .leading, spacing: scale.space.stack) {
                ForEach(Array(summary.groups.enumerated()), id: \.offset) { _, group in
                    HStack(alignment: .firstTextBaseline, spacing: scale.space.inline) {
                        if let partOfSpeech = group.partOfSpeech {
                            Text(verbatim: partOfSpeech)
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: group.text)
                    }
                    .font(.system(size: scale.text.body))
                    .lineLimit(Token.Panel.compactMeaningLines)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if summary.isUncertain {
                    Text("Meaning in context is uncertain")
                        .font(.system(size: scale.text.small))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Group {
                switch card.answer {
                case .prose(let text):
                    Text(verbatim: text).lineLimit(Token.Panel.compactProseLines)
                case .absent:
                    Text("No entry for “\(card.term)” in your dictionaries.")
                case .undecided:
                    Text("Open details to read this dictionary entry")
                default:
                    Text("The sense you read could not be identified.")
                }
            }
            .font(.system(size: scale.text.body))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The publisher's sense text includes examples and subsenses that the short definition omits.
/// Displayed only after expansion, from the entry already returned; no second lookup or generation.
struct DictionaryDetailsView: View {
    @Environment(\.scale) private var scale
    let entry: DictionaryEntry

    private var extended: [DictionarySense] {
        entry.senses.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) != $0.label }
    }

    var body: some View {
        if !extended.isEmpty {
            VStack(alignment: .leading, spacing: scale.space.stack) {
                Text("Examples and details")
                    .font(.system(size: scale.text.heading, weight: .semibold))
                ForEach(extended, id: \.path) { sense in
                    Text(verbatim: sense.text)
                        .font(.system(size: scale.text.body))
                        .lineSpacing(scale.text.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Full dictionary entry") { SystemDictionary.open(entry.headword) }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, scale.space.padAcross)
            .padding(.bottom, scale.space.padDown)
        }
    }
}
