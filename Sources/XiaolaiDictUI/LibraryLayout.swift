import SwiftUI

public enum LibraryLayout: String, Sendable, CaseIterable {
    case list, grid
    var name: LocalizedStringKey { self == .list ? "List" : "Grid" }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}
