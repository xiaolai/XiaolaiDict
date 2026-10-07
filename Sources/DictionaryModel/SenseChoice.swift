/// How a sense came to be the one recorded. A sense the model picked is a hypothesis; one the
/// reader tapped is a fact. **They must never merge in the ledger** (`dev-docs/study-unit.md` §5.2).
public enum SenseChoice: String, Codable, Sendable, CaseIterable {
    /// The reader tapped it.
    case reader
    /// The sense selector proposed it. A card built on this says so.
    case model
    /// The entry has exactly one sense, so nothing was chosen and nothing can be wrong.
    case onlySense
}
