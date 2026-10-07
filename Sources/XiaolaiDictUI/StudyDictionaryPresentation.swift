import DictionaryModel

/// What the Study pane shows before the reader asks to see anything else.
///
/// A value rather than logic in the view, because the pane is a grouped `Form`, which `ImageRenderer`
/// draws as nothing at all: a test over the view could not fail.
enum StudyDictionaryPresentation: Equatable {
    /// The reader never chose, or what they chose is no longer enabled: this is what is used.
    case automatic(DictionaryCapability)
    /// The reader's own choice, still enabled.
    case chosen(DictionaryCapability)
    /// Nothing can be derived and nothing is chosen, so the list is the only way in.
    case listOnly

    static func of(available: [DictionaryCapability]?, chosen: String?, automatic: String?) -> Self {
        let enabled = available ?? []
        if let chosen, let capability = enabled.first(where: { $0.identity.key == chosen }) {
            return .chosen(capability)
        }
        if let automatic, let capability = enabled.first(where: { $0.identity.key == automatic }) {
            return .automatic(capability)
        }
        return .listOnly
    }

    /// Whether the list is the first thing the pane draws, rather than something behind a disclosure.
    var offersTheListFirst: Bool {
        if case .listOnly = self { true } else { false }
    }
}
