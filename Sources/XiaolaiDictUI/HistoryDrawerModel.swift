import XiaolaiDictCore
import Observation

/// What the drawer is showing, and how much of it is fanned open.
@Observable
@MainActor
public final class HistoryDrawerModel {
    /// Nil until the drawer has been laid out for a display. The root view draws nothing rather
    /// than guessing a size — a sentinel rect would reach AppKit as a window nobody can see.
    public var geometry: DrawerGeometry?
    /// Drives the slide. **The window never moves while this animates.**
    public var revealed = false
    public var days: [ReadingDay] = []
    /// Day ids whose pile is fanned open. Today is never in here; it is never piled.
    public var expandedDays: Set<String> = []
    /// Set while the ledger is being read, so the drawer can say so instead of looking empty.
    public var isLoading = false
    /// A ledger that could not be read. Shown, never swallowed — an empty drawer and a broken one
    /// must not look the same.
    public var problem: String?

    public init() {}

    public var totalEntries: Int { days.reduce(0) { $0 + $1.entries.count } }

    public func isExpanded(_ day: ReadingDay) -> Bool { expandedDays.contains(day.id) }

    public func setExpanded(_ expanded: Bool, for day: ReadingDay) {
        if expanded { expandedDays.insert(day.id) } else { expandedDays.remove(day.id) }
    }
}
