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

    /// Cards the reader has removed and can still bring back. The card is gone from the drawer
    /// the moment they click; the ledger is not touched until the grace window expires.
    ///
    /// **Undo by delay, not by restore.** Putting a deleted lookup back would mean re-inserting
    /// it, and a `ReadingEntry` is not the whole row — it has no lemma basis, no language, no
    /// answering source — so an undo built that way would silently return a poorer record than
    /// the one it replaced. Waiting costs nothing and cannot be lossy. If XiaolaiDict quits inside the
    /// window the lookup simply survives, which is the safe direction to fail.
    public private(set) var removing: Set<Int> = []

    /// Called once a removal is final. Set by whoever owns the ledger; nil in previews and tests
    /// that only care about what the drawer shows.
    public var delete: ((ReadingEntry) -> Void)?

    private var pending: [Int: Task<Void, Never>] = [:]

    public init() {}

    public func remove(_ entry: ReadingEntry) {
        guard !removing.contains(entry.id) else { return }
        removing.insert(entry.id)
        pending[entry.id] = Task { [weak self] in
            try? await Task.sleep(for: Token.Timing.undoGrace)
            guard !Task.isCancelled else { return }
            self?.commitRemoval(of: entry)
        }
    }

    /// Undo: the ledger was never asked, so this is a cancellation rather than a restore.
    public func keep(_ entry: ReadingEntry) {
        pending.removeValue(forKey: entry.id)?.cancel()
        removing.remove(entry.id)
    }

    /// Everything still inside its window goes now — the reader has closed the drawer, which is
    /// them moving on rather than changing their mind.
    public func commitRemovals() {
        for (id, task) in pending {
            task.cancel()
            guard let entry = entry(id) else { continue }
            commitRemoval(of: entry)
        }
        pending.removeAll()
    }

    private func entry(_ id: Int) -> ReadingEntry? {
        days.lazy.flatMap(\.entries).first { $0.id == id }
    }

    private func commitRemoval(of entry: ReadingEntry) {
        pending[entry.id] = nil
        removing.remove(entry.id)
        days = days.compactMap { day in
            let kept = day.entries.filter { $0.id != entry.id }
            guard kept.count != day.entries.count else { return day }
            // A day with nothing left in it is not an empty day, it is a day that is no longer
            // part of the history — and a header over no cards reads as a drawer that is broken.
            guard !kept.isEmpty else { return nil }
            return ReadingDay(id: day.id, date: day.date, label: day.label, entries: kept)
        }
        delete?(entry)
    }

    public var totalEntries: Int { days.reduce(0) { $0 + $1.entries.count } }

    public func isExpanded(_ day: ReadingDay) -> Bool { expandedDays.contains(day.id) }

    public func setExpanded(_ expanded: Bool, for day: ReadingDay) {
        if expanded { expandedDays.insert(day.id) } else { expandedDays.remove(day.id) }
    }
}
