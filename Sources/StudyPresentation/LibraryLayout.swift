import Foundation

public enum LibraryLayout: String, Sendable, CaseIterable {
    case list, grid
    /// What the segment's tooltip says: the segment shows only its symbol.
    public var hint: LocalizedStringResource { self == .list ? "Show as a list" : "Show as a grid" }
}
