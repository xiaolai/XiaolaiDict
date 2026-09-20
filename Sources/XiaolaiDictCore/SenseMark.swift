import Foundation

/// What the panel says about the sense, once something is known about it.
public enum SenseMark: Equatable {
    /// `by` is the difference between a fact and a hypothesis, and the panel shows which.
    case chosen(key: String, by: SenseChoice)
    /// Nothing was chosen, and this is why — the other half of "the popup can mark a sense, and
    /// can say why it did not".
    case couldNot(Abstention, nearest: NearMiss? = nil)

    public var key: String? {
        guard case .chosen(let key, _) = self else { return nil }
        return key
    }

    /// A sense XiaolaiDict picked is a guess and must read as one; one the reader tapped is a fact.
    /// The sense it nearly chose, where it declined because several fit equally well.
    public var nearest: NearMiss? {
        guard case .couldNot(_, let nearest) = self else { return nil }
        return nearest
    }

    public var isHypothesis: Bool {
        guard case .chosen(_, let by) = self else { return false }
        return by == .model
    }
}
