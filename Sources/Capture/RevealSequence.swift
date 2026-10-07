import Foundation

/// **Shift+Up, three times in quick succession.** The gesture that shows the developer pane.
///
/// A value, so it is tested without posting a key event (which ends a test process). **In Core, not the view
/// layer**: it is gesture logic, and its counts are not design values. It is compiled in every build and acts
/// on nothing: the pane it reveals exists only in a development build.
public struct RevealSequence: Equatable {
    /// How many presses reveal, and the longest gap between two that still counts as in a row.
    public static let presses = 3
    public static let longestGap: TimeInterval = 1.5

    private var count = 0
    private var last: TimeInterval?

    public init() {}

    /// Feeds one key-down. `shiftUp` is true only for Shift+Up with no other modifier; any other key
    /// starts over. Answers true on the press that completes the gesture, and starts over after it.
    public mutating func note(shiftUp: Bool, at time: TimeInterval) -> Bool {
        guard shiftUp else {
            self = RevealSequence()
            return false
        }
        if let last, time - last > Self.longestGap { count = 0 }
        count += 1
        last = time
        guard count >= Self.presses else { return false }
        self = RevealSequence()
        return true
    }
}
