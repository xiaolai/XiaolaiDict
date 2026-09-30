import Foundation

/// Which installed model answers, and why it is that one rather than the one the reader picked.
///
/// **Three states, because two of them are not the same absence.** "Nothing installed" and "what
/// you chose will not fit in the memory free right now" send the reader to different places, and
/// a surface that showed one sentence for both would send half of them to the wrong one.
public enum ModelChoice: Sendable, Equatable {
    /// The reader's choice is installed and can be loaded.
    case chosen(LocalModelSize)
    /// The reader's choice is installed but will not fit in the memory free now, so a smaller
    /// installed model answers instead. **Both are named**, because a card drawn by the smaller
    /// one must not read as the answer the reader asked for.
    case standingIn(LocalModelSize, forWanted: LocalModelSize)
    /// Nothing installed can be loaded — either nothing is installed, or what is cannot fit now.
    case none(wanted: LocalModelSize?)

    /// The size that will actually answer, if any.
    public var answering: LocalModelSize? {
        switch self {
        case .chosen(let size): size
        case .standingIn(let size, _): size
        case .none: nil
        }
    }

    /// Whether what answers is not what was asked for — the one fact a surface must show.
    public var isStandingIn: Bool {
        if case .standingIn = self { return true }
        return false
    }
}

extension ModelSizing {
    /// **Which model answers.** The reader's choice when it is installed and fits; otherwise the
    /// largest installed model that does fit, named as standing in for it.
    ///
    /// Keeping a smaller model beside a larger one is what makes this possible, and it is the
    /// whole reason the store stopped pruning to one: measured on a 32 GB Mac, 9B needs 6,633 MB
    /// and 4,729 MB was free — so the reader who upgraded had nothing that could answer, while a
    /// perfectly good 4B had been deleted to make room for it — ADR-0041.
    public static func answering(
        wanted: LocalModelSize?, installed: [LocalModelSize],
        physicalMemory: UInt64, availableMemory: UInt64
    ) -> ModelChoice {
        let usable = installed
            .filter { mayLoad($0, physicalMemory: physicalMemory, availableMemory: availableMemory) }
        // No choice recorded is not a failure: the largest that fits is the sensible answer, and
        // it is `chosen` because the reader has expressed nothing for it to stand in for.
        guard let wanted else {
            return usable.max().map { ModelChoice.chosen($0) } ?? .none(wanted: nil)
        }
        if usable.contains(wanted) { return .chosen(wanted) }
        // **Only smaller.** A larger model standing in for a smaller one would cost the reader
        // memory and time they declined when they chose the smaller.
        guard let substitute = usable.filter({ $0 < wanted }).max() else { return .none(wanted: wanted) }
        return .standingIn(substitute, forWanted: wanted)
    }
}
