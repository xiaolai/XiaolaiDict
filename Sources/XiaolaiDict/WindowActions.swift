import SwiftUI

/// The environment's real window actions, captured from a live view.
///
/// An `NSApplicationDelegate` has no environment of its own, and `EnvironmentValues()` constructed
/// on the spot is wired to nothing — its `openWindow` silently does nothing, which is exactly how
/// a drawer came to report that it had opened while no window was ever drawn.
///
/// The menu-bar item's label is a view that exists for as long as the app does, so it is the one
/// place these can be taken from reliably.
@MainActor
final class WindowActions {
    static let shared = WindowActions()

    private(set) var open: OpenWindowAction?
    private(set) var dismiss: DismissWindowAction?
    /// Opening Settings, for the same reason: `SettingsLink` opens the window but cannot bring
    /// XiaolaiDict forward with it, and an accessory app's window opened behind the app the reader is
    /// using is a window they never see.
    private(set) var settings: OpenSettingsAction?

    func capture(open: OpenWindowAction, dismiss: DismissWindowAction, settings: OpenSettingsAction) {
        self.open = open
        self.dismiss = dismiss
        self.settings = settings
    }
}

/// Carries the menu-bar icon, and takes the window actions while it is at it.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let icon = XiaolaiDictApp.menuBarImage() {
                Image(nsImage: icon)
            } else {
                Text("XiaolaiDict")   // no image at all is still no reason to show nothing
            }
        }
        .task {
            WindowActions.shared.capture(
                open: openWindow, dismiss: dismissWindow, settings: openSettings)
        }
    }
}
