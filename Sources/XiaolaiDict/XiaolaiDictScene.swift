import AppKit
import SwiftUI

/// XiaolaiDict as a SwiftUI app.
///
/// Every window XiaolaiDict shows is a SwiftUI `Scene`. That is possible because a `UtilityWindow` scene
/// is backed by an `AppKitPanel` that comes up **without activating the app** — measured, not
/// assumed: opened at launch and on demand, `NSApp.isActive` stayed false, the panel was visible
/// and not key, and the frontmost app never changed. `isFloatingPanel` and
/// `becomesKeyOnlyIfNeeded` are already set the way XiaolaiDict's panel rule requires.
///
/// The one thing SwiftUI does not expose is `collectionBehavior`, and its default —
/// `fullScreenNone + primary` — is the opposite of what XiaolaiDict needs. `WindowAccessor` sets it on the
/// panel underneath, which is the only AppKit left in the window layer and is there for a reason
/// that was measured rather than guessed.
///
/// `main()` is called from `main.swift` rather than `@main`, because XiaolaiDict's other launch modes —
/// the lookup, the reports, the instruments — must be able to run without a scene at all.
struct XiaolaiDictScene: App {
    static let drawerID = "reading-history"

    @NSApplicationDelegateAdaptor(XiaolaiDictApp.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            XiaolaiDictMenu(app: delegate)
        } label: {
            if let icon = XiaolaiDictApp.menuBarImage() {
                Image(nsImage: icon)
            } else {
                Text("XiaolaiDict")   // no image at all is still no reason to show nothing
            }
        }

        UtilityWindow("Reading History", id: Self.drawerID) {
            HistoryDrawerRootView(model: delegate.drawerModel)
                .xiaolaiDictPanelBehaviour()
        }
        .windowStyle(.plain)
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        // Opened on demand from the menu, never at launch, and never restored into a Space the
        // reader is no longer in.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // The docked rect the geometry worked out, which depends on the display the pointer was on
        // when the drawer was asked for. A scene cannot be handed a frame, so it is read back here.
        .defaultWindowPlacement { _, _ in
            let rect = delegate.drawerPlacement ?? .zero
            return WindowPlacement(rect.origin, size: rect.size)
        }

        Settings {
            SettingsView()
        }
    }
}

/// Reaches the `NSWindow` under a SwiftUI scene, to set what SwiftUI does not expose.
///
/// Measured on macOS 27: a `UtilityWindow`'s panel defaults to `fullScreenNone + primary`, so
/// without this the lookup panel would refuse to appear over a full-screen app — the case XiaolaiDict's
/// reader is most often in. Setting it from here sticks; the panel reads the new value back.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is not attached during `makeNSView`, so the work waits one turn.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            configure(window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else { return }
        configure(window)
    }
}

extension View {
    /// The collection behaviour every XiaolaiDict panel needs: in whichever Space the reader is in, over a
    /// full-screen app, and not a window to cycle to.
    func xiaolaiDictPanelBehaviour() -> some View {
        background(WindowAccessor { window in
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        })
    }
}
