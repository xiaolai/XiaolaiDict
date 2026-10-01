import SwiftUI

/// **A status the reader should notice, said with a symbol and ordinary text — never with
/// coloured text.**
///
/// Orange text was the app's status colour and it was the hardest text on a light card to read:
/// system orange measured about 2.2:1 on white (2026-10-01), at 10 to 11 pt, carrying "this is a
/// guess" and "this failed to save". It was also the only signal — an error differed from a note
/// by hue alone — and orange is one of the seven colours a *word* can be, so an orange headword
/// beside an orange status read as one thing.
///
/// Here the symbol carries the kind and the tint, and the words stay in the label colour. The
/// tint is held to 3:1 against every card fill, which is the bar for a graphic, and VoiceOver is
/// told the kind in words, since it sees neither the symbol's shape nor its colour.
///
///     StatusLabel(.unconfirmed, "A guess, not confirmed")
///     StatusLabel(.error, text: Text(message), size: scale.text.body)
struct StatusLabel: View {
    enum Kind: CaseIterable, Sendable {
        /// Worth a look before going on: a caveat, a step that needs the reader.
        case caution
        /// The app's own guess at a meaning, which the reader has not agreed to.
        case unconfirmed
        /// Something failed.
        case error
        /// Practice — recorded, and scheduling nothing. Information, not a warning.
        case practice

        var symbol: String {
            switch self {
            case .caution: ActionSymbol.warning.symbol
            case .unconfirmed: ActionSymbol.needsAttentionFilter.symbol
            case .error: ActionSymbol.failure.symbol
            case .practice: ActionSymbol.practise.symbol
            }
        }

        var tint: ReadingAccent {
            switch self {
            case .caution, .unconfirmed: StatusPalette.caution
            case .error: StatusPalette.error
            case .practice: StatusPalette.neutral
            }
        }

        /// What VoiceOver says in place of the symbol.
        var spokenName: LocalizedStringResource {
            switch self {
            case .caution: "Caution"
            case .unconfirmed: "Not confirmed"
            case .error: "Error"
            case .practice: "Practice"
            }
        }
    }

    /// How loud the words are. The symbol is the same either way.
    enum Prominence: Sendable {
        case primary, secondary
    }

    @Environment(\.scale) private var scale
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let kind: Kind
    let text: Text
    /// The type size, from the scale. `text.small` where none is given, which is what a status
    /// line under a card's own text is set at.
    var size: CGFloat?
    var prominence: Prominence = .primary

    init(_ kind: Kind, _ text: LocalizedStringKey, size: CGFloat? = nil, prominence: Prominence = .primary) {
        self.init(kind, text: Text(text), size: size, prominence: prominence)
    }

    /// For text that is already a `Text`: a message from elsewhere, a composed or counted line.
    init(_ kind: Kind, text: Text, size: CGFloat? = nil, prominence: Prominence = .primary) {
        self.kind = kind
        self.text = text
        self.size = size
        self.prominence = prominence
    }

    var body: some View {
        Label {
            switch prominence {
            case .primary: text.foregroundStyle(.primary)
            case .secondary: text.foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.tint.color(in: scheme, contrast: contrast))
        }
        .font(.system(size: size ?? scale.text.small))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Text(kind.spokenName)): \(text)"))
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Four kinds, one text colour") {
    VStack(alignment: .leading) {
        StatusLabel(.caution, "The sentence may be cut short")
        StatusLabel(.unconfirmed, "A guess, not confirmed")
        StatusLabel(.error, "This could not be saved")
        StatusLabel(.practice, "Practice. Nothing is scheduled", prominence: .secondary)
    }
    .padding()
}
#endif
