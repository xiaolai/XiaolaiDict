import AppKit
import XiaolaiDictUI
import SwiftUI

/// XiaolaiDict as a SwiftUI app.
///
/// Every window XiaolaiDict shows is a SwiftUI `Scene`, and every one of them is a `Window` — never a
/// `UtilityWindow`. Measured in this bundle with the same content and the same action, only the
/// scene type differing: a `UtilityWindow` is created and reports `isVisible`, but the compositor
/// never lists it and Accessibility never sees it, so it is drawn nowhere and readable by nothing.
/// A `Window` is composited, is listed by Accessibility, and still does not activate the app.
///
/// What a `Window` lacks is panel behaviour — floating level, `becomesKeyOnlyIfNeeded`,
/// `collectionBehavior` — and SwiftUI exposes none of it. `WindowAccessor` sets it on the window
/// SwiftUI made. That is the only AppKit left in this layer, and it is there for reasons that were
/// measured rather than guessed.
///
/// `main()` is called from `main.swift` rather than `@main`, because XiaolaiDict's other launch modes —
/// the lookup, the reports, the instruments — must be able to run without a scene at all.
struct XiaolaiDictScene: App {
    static let drawerID = "reading-history"
    static let lookupID = "lookup"
    static let lookupTitle = "XiaolaiDict"
    static let shortcutID = "change-shortcut"

    @NSApplicationDelegateAdaptor(XiaolaiDictApp.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            XiaolaiDictMenu(app: delegate)
        } label: {
            MenuBarLabel()
        }

        Window(Self.lookupTitle, id: Self.lookupID) {
            LookupPanelSceneView(controller: delegate.panelController, model: delegate.panelModel)
                .xiaolaiDictAppearance(delegate.appearance)
        }
        // `.plain`, not `.hiddenTitleBar`. A reader pointing at a word asked a question; they did
        // not open a document. Traffic lights and a title bar say "this is yours to manage now",
        // and the panel answered by padding 28 pt off the top to dodge controls it never wanted —
        // `Token.Panel.titleBarClearance` existed for that and the lookup path no longer needs it.
        .windowStyle(.plain)
        // Hugs the card. The card is as tall as what it has to say, so the window has to be too.
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        // Below and to the right of the pointer, worked out before the scene opens.
        .defaultWindowPlacement { _, _ in
            let frame = delegate.panelController.placement
            return WindowPlacement(frame.origin, size: frame.size)
        }

        // A `Window`, deliberately not a `UtilityWindow`. Measured in this bundle, same content
        // and same action, only the scene type differing: a `UtilityWindow` is created and reports
        // `isVisible`, but the compositor never lists it and Accessibility never sees it — so it is
        // drawn nowhere and readable by nothing. A `Window` is composited, is listed by
        // Accessibility, and still does not activate the app.
        Window("Reading History", id: Self.drawerID) {
            HistoryDrawerRootView(model: delegate.drawerModel)
                .xiaolaiDictAppearance(delegate.appearance)
                .xiaolaiDictPanelBehaviour()
        }
        .windowStyle(.plain)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { _, _ in
            let rect = delegate.drawerPlacement ?? .zero
            return WindowPlacement(rect.origin, size: rect.size)
        }

        // The one window that *should* take focus: the reader asked for it from the menu and is
        // about to type into it.
        Window("Change Shortcut", id: Self.shortcutID) {
            ShortcutRecorderView(recorder: delegate.recorder, model: delegate.recorder.model)
                .xiaolaiDictAppearance(delegate.appearance)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // One window per pinned note. `WindowGroup(for:)` opens one per value, which is the shape
        // of "several notes, each independent" — the hand-built version kept a dictionary of
        // panels to do the same thing.
        WindowGroup(for: UUID.self) { $id in
            if let id {
                PinnedNoteSceneView(controller: delegate.panelController.notes, id: id)
                    .xiaolaiDictAppearance(delegate.appearance)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { _, _ in
            let frame = delegate.panelController.notes.placement
            return WindowPlacement(frame.origin, size: frame.size)
        }

        Settings {
            SettingsView(appearance: delegate.appearance)
                .xiaolaiDictAppearance(delegate.appearance)
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
    /// `transient` for the lookup panel, which goes away with the Space it was summoned in;
    /// `stationary` for the drawer, which is docked and stays put.
    func xiaolaiDictPanelBehaviour(
        transient: Bool = false, then extra: @escaping (NSWindow) -> Void = { _ in }
    ) -> some View {
        background(WindowAccessor { window in
            window.collectionBehavior = [
                .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle,
                transient ? .transient : .stationary,
            ]
            // The panel behaviour a `Window` scene does not have, applied to the window it made.
            // `UtilityWindow` has it built in and is unusable — it is never composited and never
            // reaches Accessibility — so this is the trade: a scene that is actually drawn, made to
            // behave like a panel.
            window.level = .floating
            window.hidesOnDeactivate = false
            if let panel = window as? NSPanel { panel.becomesKeyOnlyIfNeeded = true }
            extra(window)
        })
    }
}
