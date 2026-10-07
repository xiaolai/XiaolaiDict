import Foundation

public enum LibraryPane: String, Sendable, CaseIterable {
    case history, saved, review, discarded
    public var name: LocalizedStringResource {
        switch self { case .history: "History"; case .saved: "Saved"; case .review: "Review"; case .discarded: "Discarded" }
    }
}
