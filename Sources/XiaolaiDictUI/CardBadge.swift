import XiaolaiDictCore

/// The one badge a history card shows at the end of its line — **decided here, not in the view**,
/// because there are two kinds of it and which one applies is the question the view got wrong.
///
/// A lookup that recorded an entry but no sense still has a `SenseNote`; its badge says how many
/// senses the entry has. So a refusal, whose encounter is exactly that, drew "12 senses" and the
/// reader was never told the model had declined. A refusal is the more specific fact and wins.
///
/// Three standings for a sense, not two: an entry where no sense was settled read "9 senses?" and
/// "the sense XiaolaiDict guessed" — a claim the ledger never made.
public struct CardBadge: Equatable {
    public let text: String
    public let explanation: String
    /// Whether the card is stating a fact rather than a hypothesis, which is how it is drawn.
    public let isConfirmed: Bool

    public init?(of entry: ReadingEntry) {
        // **A sense the reader settled outranks the refusal that came before it.** The model
        // declining is a fact about the moment it was asked; the reader's own tap is a fact about
        // the word, and it came afterwards. A card that went on saying "declined" would throw away
        // the one thing the ledger keeps `chosen_by` for. A *proposed* sense does not outrank it:
        // that is a hypothesis, and the refusal is the more specific thing known.
        if entry.senseAbstention == .refused, entry.sense?.isConfirmed != true {
            text = String(localized: "declined", comment: "History card badge: a model declined to pick a sense for this sentence")
            explanation = Abstention.refused.reason
            isConfirmed = false
            return
        }
        guard let sense = entry.sense else { return nil }
        text = sense.badge
        explanation = sense.standing.explanation
        isConfirmed = sense.standing.isConfirmed
    }
}
