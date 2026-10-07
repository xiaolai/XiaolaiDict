import DictionaryModel

/// Which dictionary the reader studies from, as the settings window needs it.
///
/// Passed in rather than read: the list comes from the XPC dictionary service, which lives in the
/// app target, and `XiaolaiDictUI` carries no private API and no XPC by design. `available` is optional
/// because "still asking" is a real state the reader can arrive in — an empty list and an
/// unanswered one must not look the same.
public struct DictionaryChoice {
    public var available: [DictionaryCapability]?
    public var chosen: String?
    /// The dictionary the reader's language names, as a `DictionaryIdentity.key`. **Not a choice**:
    /// `chosen` is nil for a reader who never picked, and this is what is used meanwhile.
    public var automatic: String?
    public var choose: (String?) -> Void
    /// Whether the service has been asked and has finished answering.
    ///
    /// `available` is nil both before the question is asked and after one that failed, and those
    /// are different sentences: "asking…" is a state that resolves, and a service that answered
    /// nothing is a state that does not. Without this the setup board said "asking" for the life
    /// of the window.
    public var hasAsked: Bool
    /// Asks the service again, discarding its last answer.
    ///
    /// **The failure state needs an action, not just a sentence.** Telling the reader the
    /// service did not answer, with nothing to do about it, leaves them to guess that
    /// reopening the window might help — and nothing guarantees it does: the dictionary list
    /// is asked once and handed in, and the window's own polling `.task` refreshes
    /// permissions, not this.
    public var reask: () -> Void

    public init(
        available: [DictionaryCapability]?, chosen: String?, automatic: String? = nil, hasAsked: Bool = false,
        choose: @escaping (String?) -> Void, reask: @escaping () -> Void = {}
    ) {
        self.available = available
        self.chosen = chosen
        self.automatic = automatic
        self.hasAsked = hasAsked
        self.reask = reask
        self.choose = choose
    }
}
