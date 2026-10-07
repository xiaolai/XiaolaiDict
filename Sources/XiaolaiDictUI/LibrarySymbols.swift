import StudyPresentation

// **The symbol each of the Library's values is drawn with**, from `ActionSymbol`, the one table every symbol
// comes from. Here rather than on the values, which are `StudyPresentation`'s and bind no UI framework:
// `ActionSymbol` draws — its `image`, `label` and `role` are SwiftUI's (plan-macos-modularisation, P4a).

extension LibraryPane {
    /// The pane's symbol and name in the sidebar, and the symbol of its empty state.
    var action: ActionSymbol {
        switch self { case .history: .historyPane; case .saved: .savedPane; case .review: .reviewPane; case .discarded: .discardedPane }
    }
}

extension LibraryLayout {
    /// The segment's symbol and name, from the one table every symbol comes from.
    var action: ActionSymbol { self == .list ? .listLayout : .gridLayout }
}

extension LibraryPresentation.Filter {
    /// The sidebar row's symbol and name, from the one table every symbol comes from — so a
    /// filter cannot wear a pane's symbol, as All wore Saved's and Due wore History's.
    public var action: ActionSymbol {
        switch self {
        case .all: .allFilter
        case .due: .dueFilter
        case .needsAttention: .needsAttentionFilter
        case .struggling: .strugglingFilter
        case .paused: .pausedFilter
        case .archived: .archivedFilter
        case .suggested: .suggestedFilter
        }
    }
}

extension LibraryPresentation.Status {
    /// The mark beside the name: the symbol of the list this state puts the card in.
    var action: ActionSymbol {
        switch self {
        case .needsConfirmation, .needsRepair: .needsAttentionFilter
        case .paused: .pausedFilter
        case .archived: .archivedFilter
        case .ignored: .alreadyKnow
        }
    }
}
