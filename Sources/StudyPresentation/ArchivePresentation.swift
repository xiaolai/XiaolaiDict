import Foundation
import StudyKit

public struct ArchivePresentation: Sendable {
    public let rows: [ReadingEntry]
    public let total: Int
    public let search: String
    public let hasMore: Bool
    public let problem: String?
    public let undoCount: Int
    public let focused: Int?
    public let selection: Set<Int>
    public var inspector: ReadingEntry? {
        guard selection.count == 1 else { return nil }
        return rows.first { selection.contains($0.id) }
    }
    public var selectedLookupIDs: [Int] {
        Array(Set(rows.filter { selection.contains($0.id) }.flatMap(\.lookupIDs))).sorted()
    }
    public init(rows: [ReadingEntry] = [], total: Int = 0, search: String = "", hasMore: Bool = false,
                problem: String? = nil, undoCount: Int = 0, focused: Int? = nil, selection: Set<Int> = []) {
        self.rows = rows; self.total = total; self.search = search; self.hasMore = hasMore
        self.problem = problem; self.undoCount = undoCount; self.focused = focused; self.selection = selection
    }
}
public enum ArchiveAction: Sendable {
    case select(Set<Int>), retry, confirm(UUID), search(String), more, discard([Int]), restore([Int]), undo, keep(Int), clarify(Int), erase([Int])
}
