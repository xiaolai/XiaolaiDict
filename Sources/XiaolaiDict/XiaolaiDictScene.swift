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

        // `.contentMinSize`, not `.contentSize`: the panes fill the window rather than sizing it,
        // and `SettingsWindowFit` moves the window. With `.contentSize` SwiftUI also resized it
        // from the content — a second mover, measured to overshoot by the height of the title bar
        // and tabs and then correct itself, which the reader saw as the bottom edge shuddering.
        Settings { XiaolaiDictSettings(app: delegate) }
            .windowResizability(.contentMinSize)
    }
}

/// XiaolaiDict's settings window, as a **view** rather than as scene-body code.
///
/// **Reading observable state in an `App`'s `body` invalidates every scene in it.** Built inline
/// in the `Settings` scene, this read `delegate.dictionaries` and `delegate.hoverPolicy` — and
/// `dictionaries` arrives asynchronously, when the XPC probe answers. That one late write
/// re-evaluated `XiaolaiDictScene.body`, and a sibling `Window` scene went with it: its menu item was
/// clicked, no window ever appeared, and the end-to-end assertions for it failed while the drawer
/// and this window passed. Verified against `main`, which has none of these reads and passes.
///
/// It is the same rule `Scale.swift` records for `xiaolaiDictAppearance`: observation belongs in a view's
/// body. A view invalidates itself; an `App` invalidates the whole window list.
struct XiaolaiDictSettings: View {
    let app: XiaolaiDictApp

    var body: some View {
        // Everything the window can change is handed in, because `XiaolaiDictUI` reaches neither the XPC
        // dictionary service nor the preferences the app owns — and the hover policy has to be
        // written through `setHoverPolicy`, so the watcher and the store cannot drift apart.
        SettingsView(
            model: app.settings,
            appearance: app.appearance,
            hover: Binding(get: { app.hoverPolicy }, set: { app.setHoverPolicy($0) }),
            dictionary: DictionaryChoice(
                available: app.dictionaries,
                chosen: app.chosenDictionary,
                choose: { app.choosePrimaryDictionary($0) }),
            shortcut: app.shortcutChoice)
        .xiaolaiDictAppearance(app.appearance)
        // Identified from inside, for `--settings-report` to measure.
        .background(WindowAccessor { app.settingsWindow = $0 })
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
