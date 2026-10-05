import SwiftUI

public enum LookupKeepStatus: Equatable, Sendable, CaseIterable {
    case keeping, kept, needsMeaning, needsConfirmation, manual, failed, discarded, discardedExternally
    /// The reading was deleted while its card was open — from the Library, or by an erase. Nothing is
    /// left to save to, restore or discard, so the row offers no control.
    case deleted
    /// **What choosing a meaning did to the word saved without one** — with the reader's option on
    /// (R1b): replaced and archived, or kept beside the meaning and why. Said on the card where the
    /// reader chose, because the word-only card's fate is otherwise discovered later in Saved.
    case replacedWordCard, keptReviewedWordCard, keptAnsweredWordCard

    /// What the row says, **as a status and never as an instruction** — and in the words every
    /// other surface uses: a meaning is *saved*, a reading is *discarded*.
    /// A reading the ledger could not write is *not recorded* — never "not saved", which is the
    /// word for a meaning and sat one row away from "Saved" meaning exactly that.
    ///
    /// It read "Kept · Confirm this meaning in Library" and "History kept · Choose Keep for
    /// learning to study" (2026-10-01): a state and an errand in one line, the second naming a
    /// control that was an unlabelled icon below a fold. The reader pressed *Keep* and looked for
    /// the result under *Saved*. What to do about a status is the control beside it, or the
    /// Library's own row for it.
    public var sentence: LocalizedStringResource {
        switch self {
        case .keeping: "Saving…"
        case .kept: "Saved"
        case .needsMeaning: "Saved, with no meaning chosen yet"
        case .needsConfirmation: "Saved, not confirmed yet"
        case .manual: "In your reading history, not saved"
        case .failed: "This reading could not be recorded"
        case .discarded, .discardedExternally: "Discarded"
        case .deleted: "Deleted"
        case .replacedWordCard: "Saved in place of the word-only card, which is now archived"
        case .keptReviewedWordCard: "Saved; the word-only card stays too, because you have reviewed it"
        case .keptAnsweredWordCard: "Saved; the word-only card stays too, because its answer differs from this one"
        }
    }

    /// Whether the reading has been put away. Both ways of getting there are undone the same way
    /// and by the same word: there were two, *Undo* and *Restore*, for one action in two states.
    public var isDiscarded: Bool { self == .discarded || self == .discardedExternally }
}

public enum LookupKeepAction: Sendable { case retry, discard, undo }

private struct KeepStatusKey: EnvironmentKey { static let defaultValue: LookupKeepStatus? = nil }
private struct KeepActionKey: EnvironmentKey {
    static let defaultValue: @MainActor (LookupKeepAction) -> Void = { _ in }
}

public extension EnvironmentValues {
    var lookupKeepStatus: LookupKeepStatus? {
        get { self[KeepStatusKey.self] }
        set { self[KeepStatusKey.self] = newValue }
    }
    var lookupKeepAction: @MainActor (LookupKeepAction) -> Void {
        get { self[KeepActionKey.self] }
        set { self[KeepActionKey.self] = newValue }
    }
}

/// **Whether this reading was saved, and the way to take it back — the card's own last row.**
///
/// It was stacked *under* the card by the window's scene, and the window is clear: measured
/// 2026-10-01 from screenshot pixels, the row's words were black at alpha 60 over whatever app was
/// behind in a light appearance and near-white over the same in a dark one, and the Discard bezel
/// straddled the edge of the window underneath. `PanelSurface` draws it now, after the scrolling
/// region and inside the fill, so it is pinned, always visible, and on paper.
///
/// The controls are the icons the Library uses for the same acts, so *Discard* here and *Discard*
/// there are one glyph and one word. Discard is not red: a discarded reading is one press from
/// restored, and red is kept for what cannot be taken back.
struct LookupKeepStatusRow: View {
    @Environment(\.scale) private var scale
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.lookupKeepStatus) private var status
    @Environment(\.lookupKeepAction) private var action

    var body: some View {
        if let status {
            HStack(spacing: scale.space.inline) {
                label(for: status)
                Spacer(minLength: scale.space.inline)
                controls(for: status)
            }
            // The card's own inset, so the words start where the card's text starts and the last
            // control ends where its content ends. The bezel used to end at the card's outer edge.
            .padding(.leading, scale.space.padAcross)
            .padding(.trailing, scale.space.padAcross)
            .padding(.vertical, scale.space.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A rule above it: what scrolls ends here, and this does not scroll.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(CardSurface.neutralBorder(contrast: contrast))
                    .frame(height: Token.Stroke.hairline)
            }
        }
    }

    @ViewBuilder
    private func label(for status: LookupKeepStatus) -> some View {
        if status == .failed {
            // A failure is told apart from a note by a mark as well as by its words.
            StatusLabel(.error, text: Text(status.sentence), prominence: .secondary)
        } else {
            Text(status.sentence)
                .font(.system(size: scale.text.small))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func controls(for status: LookupKeepStatus) -> some View {
        Group {
            if status == .failed {
                IconButton(.retry, size: scale.text.small) { action(.retry) }
            }
            if status.isDiscarded {
                IconButton(.restoreReading, size: scale.text.small) { action(.undo) }
            } else if status != .deleted {
                IconButton(.discardReading, size: scale.text.small) { action(.discard) }
            }
        }
        .foregroundStyle(.secondary)
    }
}
