import SwiftUI

/// How much of what is behind the history drawer comes through it.
///
/// **A reader's choice, because it depends on what is behind the drawer.** Frosted glass over a
/// dark, uniform window is flat grey — measured at (133, 133, 133) over black, the exact value the
/// drawer showed on a reader's screen while it docked over a black terminal and looked broken
/// while working. Over a photo or a page, frosted reads as glass and keeps the cards easy to read;
/// over a terminal, clear lets the terminal show through instead of turning it grey.
public enum DrawerGlass: String, CaseIterable, Codable, Sendable {
    case frosted
    case clear

    /// The drawer as it shipped. One declaration, read by the store's fallback and by the
    /// environment's default alike, so the two cannot disagree about what "default" means.
    public static let standard: DrawerGlass = .frosted

    public var label: String {
        switch self {
        case .frosted: String(localized: "Frosted")
        case .clear: String(localized: "Clear")
        }
    }

    /// SwiftUI's own style for each — not an approximation of one.
    var glass: Glass {
        switch self {
        case .frosted: .regular
        case .clear: .clear
        }
    }
}

extension EnvironmentValues {
    @Entry var drawerGlass: DrawerGlass = .standard
}
