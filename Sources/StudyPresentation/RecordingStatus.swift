import Foundation

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

/// What the ledger did with a save of the phrase — **the recorder's, per request and spelling**, so a phrase
/// the card switches to is not drawn with another's state.
public enum PhraseCollectStatus: Equatable, Sendable, CaseIterable {
    /// Asked for, and not yet written — waiting for the reading's row, or for the ledger.
    case collecting
    case collected
    /// It was saved before, from this reading or another: the same card, one more reading behind it.
    case alreadyCollected
    /// It was not written. The control offers the same save again.
    case failed
}
