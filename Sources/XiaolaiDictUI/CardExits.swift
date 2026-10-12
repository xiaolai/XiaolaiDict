import XiaolaiDictCore

/// **What the row pinned under the card holds, and where "Dictionaries…" is drawn** — one decision per outcome and card
/// size (plan-card-refinements WI-1).
///
/// The way to Settings › Dictionary used to be "Choose Another Dictionary…" alone, drawn only where the entry marks no
/// senses. The compact card mounts no footer, a detailed miss mounted none and prose only Copy, so the way out was
/// missing on exactly the miss that needs it. Decided here, as a value a test reads as a table, so no state can be
/// left out by a branch in a view body. The conditional button stays where it was: it names a cure for a condition,
/// and this names a place.
struct CardExits: Equatable {
    /// The pinned row's content.
    enum Footer: Equatable {
        /// Nothing pinned: still waiting, or the compact card, which pins nothing.
        case none
        /// The dictionary list and the entry's actions.
        case entry
        /// Copy, the one action prose has.
        case prose
        /// A miss: nothing to act on but the way out.
        case miss
    }

    /// Where "Dictionaries…" is drawn.
    enum DictionariesExit: Equatable {
        case none
        case footer
        case compactCard
    }

    let footer: Footer
    let dictionaries: DictionariesExit

    /// `outcome` nil is still waiting: no card about any dictionary is on screen, so there is nothing to leave.
    static func of(_ outcome: LookupOutcome?, compact: Bool) -> CardExits {
        guard let outcome else { return CardExits(footer: .none, dictionaries: .none) }
        if compact { return CardExits(footer: .none, dictionaries: .compactCard) }
        let footer: Footer =
            switch outcome {
            case .entries: .entry
            case .plainText: .prose
            case .notFound: .miss
            }
        return CardExits(footer: footer, dictionaries: .footer)
    }
}
