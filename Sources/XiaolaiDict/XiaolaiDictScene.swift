import AppKit
import StudyModels
import XiaolaiDictBase
import XiaolaiDictUI
import SwiftUI
import os

/// XiaolaiDict as a SwiftUI app.
///
/// Every window XiaolaiDict shows is a SwiftUI `Scene`, and every one of them is a `Window` — never a
/// `UtilityWindow`. Measured in this bundle with the same content and the same action, only the
/// scene type differing: a `UtilityWindow` is created and reports `isVisible`, but the compositor
/// never lists it and Accessibility never sees it, so it is drawn nowhere and readable by nothing.
/// A `Window` is composited, is listed by Accessibility, and still does not activate the app.
///
/// What a `Window` lacks is panel behaviour — floating level, `collectionBehavior` — and SwiftUI
/// exposes none of it. `WindowAccessor` sets it on the window SwiftUI made. That is the only AppKit
/// left in this layer, and it is there for reasons that were measured rather than guessed.
///
/// **`becomesKeyOnlyIfNeeded` is not among them, and used to be named here.** A `Window` scene is a
/// `SwiftUI.AppKitWindow`, never an `NSPanel`, so the line that set it could not run — see
/// `xiaolaiDictPanelBehaviour`. Whether these windows take the keyboard is `canBecomeKey`'s answer
/// instead: false for `.plain`, true for `.hiddenTitleBar`, both measured.
///
/// `main()` is called from `main.swift` rather than `@main`, because XiaolaiDict's other launch modes —
/// the lookup, the reports, the instruments — must be able to run without a scene at all.
struct XiaolaiDictScene: App {
    // `nonisolated`: they are constants, and what classifies a window by them (`ShellActivation`) is
    // a pure function that should not need the main actor to compare two strings.
    nonisolated static let drawerID = "reading-history"
    nonisolated static let lookupID = "lookup"
    nonisolated static let libraryID = "library"
    /// Where AppKit keeps the Library window's frame between launches.
    static let libraryFrameName = "XiaolaiDictLibraryWindow"

    /// The window SwiftUI made for a scene, found by the scene's id.
    ///
    /// **By identifier, never by title.** SwiftUI gives a `Window` scene's window an identifier that
    /// begins with the scene's id, and a title that is the localised one: three lookups compared
    /// titles against an English literal, so in any translated build they found nothing and said
    /// nothing (audit M10, 2026-10-02).
    ///
    /// `NSApplication.shared`, never `NSApp`: the latter is implicitly unwrapped and nil in a
    /// process that has not made one — every unit test — where it traps instead of answering nil.
    @MainActor
    static func window(of sceneID: String) -> NSWindow? {
        NSApplication.shared.windows.first { $0.identifier?.rawValue.contains(sceneID) == true }
    }

    @NSApplicationDelegateAdaptor(XiaolaiDictApp.self) private var delegate

    var body: some Scene {
        // **An empty, uninserted `MenuBarExtra`, kept for one reason**: `MenuBarLabel`'s `.task` is
        // where `WindowActions.shared` is captured, and it is the only view in this app that lives
        // as long as the process. The menu bar item itself is `MenuBarItem`, which says why
        // SwiftUI's cannot tell a left click from a right one.
        //
        // **No content**, because none of it could ever be opened. The menu this scene used to
        // build was a `XiaolaiDictMenu` view, and with `isInserted: false` there is no icon to open
        // it from — a whole menu's worth of reader-facing text, and a wiring test asserting over
        // it, describing a surface nobody could reach.
        MenuBarExtra(isInserted: .constant(false)) {
            EmptyView()
        } label: {
            MenuBarLabel()
        }

        // **Titled for what it is.** The title is not drawn — the window is `.plain` — but VoiceOver,
        // Mission Control and every window list read it, and it was the app's name (audit M9).
        Window("Lookup", id: Self.lookupID) {
            LookupPanelSceneView(
                controller: delegate.panelController, recorder: delegate.lookupRecorder, model: delegate.panelModel,
                translation: { [delegate] in delegate.models.translationActions },
                explainer: { [delegate] in delegate.models.explanationActions })
                .xiaolaiDictAppearance(delegate.appearance)
        }
        // `.plain`, not `.hiddenTitleBar`. A reader pointing at a word asked a question; they did
        // not open a document. Traffic lights and a title bar say "this is yours to manage now",
        // and the panel answered by padding 28 pt off the top to dodge controls it never wanted.
        // `Token.Panel.titleBarClearance` existed for that; nothing needs it now that a pinned note
        // hides its controls too, so it is gone rather than left as a value nobody reads.
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
            HistoryDrawerSceneView(app: delegate)
                .xiaolaiDictAppearance(delegate.appearance)
                .xiaolaiDictPanelBehaviour { delegate.attachHistoryWindow($0) }
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
                    // **Each note is named for its word.** A `WindowGroup` with no title falls back
                    // to the app's name, so three notes were three windows called "XiaolaiDict".
                    // Verbatim: a headword is the dictionary's spelling, not prose to translate.
                    .navigationTitle(Text(verbatim: delegate.panelController.notes.note(id)?.heading ?? ""))
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultWindowPlacement { _, _ in
            let frame = delegate.panelController.notes.placement
            return WindowPlacement(frame.origin, size: frame.size)
        }

        // **A window the reader chose, so it comes forward and keeps focus.** Unlike the panel and
        // the drawer, which must never activate the app: this one is typed into. The reader asked
        // for it from the menu, it is theirs to manage, and it keeps its title bar for that reason.
        Window("Library", id: Self.libraryID) {
            LibrarySceneView(model: delegate.libraryModel, review: delegate.reviewModel)
                .xiaolaiDictAppearance(delegate.appearance)
                // The floor: the sidebar and enough of one card to read it. Below this the split
                // view has nothing left to give and the toolbar starts dropping its items.
                .frame(minWidth: Token.Library.minWidth, minHeight: Token.Library.minHeight)
                .background(WindowAccessor { LibraryWindowFrame.restore(on: $0) })
        }
        .defaultLaunchBehavior(.suppressed)
        // **Still disabled, and the frame is kept another way.** What this switches off is the
        // system *reopening* the window at launch — and a menu bar app that starts at login must
        // not open a 1,200-point window at the reader unasked, which is why it was set (it arrived
        // with the scene in 3a95599, copied from the panel's, with no reason written down). The
        // audit's complaint was the other half of restoration: a window the reader had sized came
        // back at the default (L19). `LibraryWindowFrame` restores that half alone.
        .restorationBehavior(.disabled)
        .defaultSize(width: Token.Library.width, height: Token.Library.height)
        // The content's minimum is the window's; the reader sizes it freely above that.
        .windowResizability(.contentMinSize)

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
/// in the `Settings` scene, this read `delegate.dictionary.enabled` and `delegate.hover.policy` — and
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
            keepPolicy: Binding(get: { app.keepPolicyStore.load() }, set: { app.keepPolicyStore.save($0) }),
            hover: Binding(get: { app.hover.policy }, set: { app.hover.setPolicy($0) }),
            // The watcher, not the policy: whether hover runs at all. It lived only in the menu
            // bar menu until the menu was trimmed to what a reader reaches for often.
            hoverEnabled: Binding(get: { app.hover.isWatching }, set: { app.hover.setEnabled($0) }),
            // Observed: a wedged capture is said here, the place a reader goes when hover stops.
            captureStuck: app.hover.isCaptureStuck,
            dictionary: app.dictionary.choice,
            // The developer pane's operations: a development build's, nil in a release (which draws no pane).
            developer: app.developerChoice,
            shortcut: app.shortcuts.choice,
            modelLicence: app.models.licenceURL,
            erase: app.eraseModel.presentation,
            eraseAction: { [model = app.eraseModel] in model.act($0) },
            // Observed: the switch follows the settings and the grant the coordinator last read.
            reminders: app.reminders.choice,
            // Observed: the two study options (R1b, R1c), each written through the key its reader reads.
            study: app.studyOptions.choice,
            // The setup board's own inputs. It is a pane of this window now, so what it needs
            // arrives here rather than through a second scene.
            setup: app.setup,
            // Whether the hot key actually registered, not merely whether the combination is
            // well-formed: another app can hold it exclusively, and the row drew "Ready" over a
            // shortcut that answered nothing.
            shortcutIsRegistered: app.shortcuts.isRegistered,
            localModel: app.models.choice,
            refreshDictionaries: { await app.dictionary.askAgain() })
        .xiaolaiDictAppearance(app.appearance)
        // Identified from inside, for `--settings-report` to measure — and so the app can tell when
        // the reader has actually *seen* the setup pane, which is this window becoming key while
        // that pane is the one selected.
        .background(WindowAccessor { app.settingsWindow = $0 })
        // The dictionary list is fetched lazily. A reader who never opens the menu would otherwise
        // see "Asking which dictionaries are enabled…" forever on the setup pane.
        .task {
            // Re-read, so a model removed from Finder while the app ran is not still called ready.
            app.models.refresh()
            await app.dictionary.askAgain()
        }
    }
}

/// **The Library window's frame, kept between launches by AppKit's own autosave.**
///
/// Applied once per window: `WindowAccessor` calls back on every SwiftUI update, and re-applying
/// the saved frame on each would snap the window back while the reader was dragging its edge.
/// `setFrameUsingName` first, because naming the autosave does not by itself move a window that is
/// already on screen; then the name, so every later move is written.
@MainActor
enum LibraryWindowFrame {
    static func restore(on window: NSWindow) {
        guard window.frameAutosaveName != XiaolaiDictScene.libraryFrameName else { return }
        window.setFrameUsingName(XiaolaiDictScene.libraryFrameName)
        if !window.setFrameAutosaveName(XiaolaiDictScene.libraryFrameName) {
            // Another window holds the name — a second Library, which a `Window` scene cannot
            // make. Said rather than swallowed: the frame would silently stop being kept.
            Logger(subsystem: XiaolaiDictIdentity.app, category: "windows")
                .fault("library: the frame autosave name is already in use; the frame will not be kept")
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
            // **`becomesKeyOnlyIfNeeded` is not reachable from here, and the line that set it never
            // ran.** Measured 2026-09-25 with a throwaway SwiftUI app: a `Window` scene is a
            // `SwiftUI.AppKitWindow` and **not** an `NSPanel` under either style this app uses —
            // `.plain` gives style mask 0 with `canBecomeKey` false, `.hiddenTitleBar` gives 32775
            // with it true. So `if let panel = window as? NSPanel { … }` stood here doing nothing
            // since it was written: a line whose whole purpose was to soften focus-stealing, and
            // never once applied.
            //
            // Deleted rather than repaired because the property does not exist on the class SwiftUI
            // hands us, and there is nothing to set in its place. What actually decides whether these
            // surfaces take the reader's keyboard is `canBecomeKey`, which is the window's own and is
            // what `--panel-report` reads. The doc comment above this function no longer claims
            // otherwise.
            extra(window)
        })
    }
}

struct HistoryDrawerSceneView: View {
    let app: XiaolaiDictApp
    var body: some View {
        HistoryDrawerRootView(model: app.drawerModel)
            .onChange(of: LedgerChanges.shared.revision) { _, _ in app.refreshHistory() }
    }
}
