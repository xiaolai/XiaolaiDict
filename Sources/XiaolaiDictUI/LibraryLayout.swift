import SwiftUI

public enum LibraryLayout: String, Sendable, CaseIterable {
    case list, grid
    /// The segment's symbol and name, from the one table every symbol comes from.
    var action: ActionSymbol { self == .list ? .listLayout : .gridLayout }
    /// What the segment's tooltip says: the segment shows only its symbol.
    var hint: LocalizedStringKey { self == .list ? "Show as a list" : "Show as a grid" }
}
