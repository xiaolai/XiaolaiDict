/// What answered a lookup: the dictionary service with its rich entries, or — when it could not —
/// the public API's plain text. A degraded answer stays marked as one after it is stored.
public enum AnswerSource: String, Sendable, CaseIterable {
    case dictionaryService
    case publicFallback
}
