/// The lookup panel's request numbers — **handing one out and claiming the panel are two acts.**
///
/// A hover is given its number when the reader's gesture is accepted, before the screen is read,
/// so that its place in line is the moment the reader asked. It claims the panel only once a word
/// has been read, and the claim fails if a later request got there first. Minting a panel ticket
/// at the gesture instead would be wrong in the other direction: under hold, every twitch of the
/// pointer on the word already shown passes the gate and ends `.samePlace`, and each would have
/// invalidated the sense mark still arriving in the panel on screen.
///
/// A value, so the rule is tested without a panel and the test's stand-in cannot drift from it.
public struct RequestSequence: Sendable, Equatable {
    /// The last number handed out.
    public private(set) var issued = 0
    /// No number at or below this may claim the panel: it has been claimed past, or closed over.
    private var floor = 0
    /// The request whose panel is on screen, if any.
    public private(set) var current: Int?

    public init() {}

    /// A new number, which supersedes nothing until it is claimed.
    public mutating func begin() -> Int {
        issued += 1
        return issued
    }

    /// Takes the panel for `request`, and answers whether it did. Refused once a later request has
    /// claimed it or the panel has been closed since `request` was handed out.
    public mutating func claim(_ request: Int) -> Bool {
        guard request > floor, request <= issued else { return false }
        floor = request
        current = request
        return true
    }

    /// Begins and claims at once — for a request the reader made *at* the panel, the selection
    /// shortcut, the Library, a reopened reading, where there is no wait for anything to overtake.
    public mutating func next() -> Int {
        let request = begin()
        floor = request
        current = request
        return request
    }

    /// Closing the panel supersedes every request handed out so far, claimed or not: a result that
    /// arrives afterwards is not reopened over the reader's dismissal.
    public mutating func close() {
        floor = issued
        current = nil
    }

    public func isCurrent(_ request: Int) -> Bool { current == request }
}
