/// Whether the dictionaries had the word. A miss is recorded too — usually a typo or a stray
/// selection, which later triage can tell from a real gap — but it does not rank in the study list.
public enum LookupResult: String, Sendable, CaseIterable {
    case found
    case notFound
    case pending
}
