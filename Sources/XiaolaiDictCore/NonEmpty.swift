/// A list that cannot be empty — so "found nothing" has to be said with its own case, never with
/// an empty success that every consumer must remember to treat as a miss.
public struct NonEmpty<Element>: RandomAccessCollection {
    public let elements: [Element]

    /// Nil for an empty list.
    public init?(_ elements: [Element]) {
        guard !elements.isEmpty else { return nil }
        self.elements = elements
    }

    public var startIndex: Int { elements.startIndex }
    public var endIndex: Int { elements.endIndex }
    public subscript(position: Int) -> Element { elements[position] }
}

extension NonEmpty: Equatable where Element: Equatable {}
extension NonEmpty: Sendable where Element: Sendable {}

/// Encoded as a plain array. Decoding refuses an empty one: the invariant holds across the process
/// boundary too, not only in code that went through `init?`.
extension NonEmpty: Codable where Element: Codable {
    public init(from decoder: any Decoder) throws {
        let elements = try decoder.singleValueContainer().decode([Element].self)
        guard !elements.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "an empty list where at least one element is required"))
        }
        self.elements = elements
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(elements)
    }
}
