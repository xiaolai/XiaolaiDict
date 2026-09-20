import AppKit
import XiaolaiDictCore
import SwiftUI

/// The menu-bar menu, as a SwiftUI view rather than an `NSMenu` rebuilt on every open.
///
/// The `NSMenu` it replaces had to be torn down and reassembled in `menuNeedsUpdate` so a problem
/// that appeared since launch would show. A view re-reads its state whenever that state changes,
/// which is the same guarantee without the ceremony — and `SettingsLink` is the supported way into
/// the `Settings` scene, which an accessory app cannot reach through `showSettingsWindow:` because
/// it has no main menu for the action to route through.
struct XiaolaiDictMenu: View {
    let app: XiaolaiDictApp

    var body: some View {
        Button(app.shortcutLabel.map { "Look Up Selection    \($0)" } ?? "Look Up Selection") {
            app.lookUpSelection()
        }
        Button("Change Shortcut…") { app.changeShortcut() }

        // Read from the watcher, not from the setting: if starting it failed, the menu says off.
        Toggle("Hover Lookup    hold \u{2325}", isOn: Binding(
            get: { app.hoverIsWatching }, set: { _ in app.toggleHover() }))

        // The pause switch (A5). It was specified, modelled, given three lengths and a label —
        // and never drawn, so `HoverPause.label(at:)`'s "what the menu says" described a menu that
        // did not exist. Resuming is one click; pausing picks a length, which is what having three
        // of them is for.
        if app.hoverIsPaused {
            Button(app.hoverPauseLabel) { app.resumeHover() }
        } else {
            Menu(app.hoverPauseLabel) {
                ForEach(HoverPause.durations, id: \.self) { duration in
                    Button(HoverPause.name(of: duration)) { app.pauseHover(for: duration) }
                }
            }
        }

        Button(app.drawerIsVisible ? "Hide Reading History" : "Reading History") { app.toggleHistory() }

        studyFrom

        Divider()
        SettingsLink { Text("Settings…") }

        // Problems the reader should see, in the place they already look.
        ForEach(app.problems, id: \.self) { problem in
            Label(problem, systemImage: "exclamationmark.triangle")
        }

        Divider()
        Button("Quit XiaolaiDict") { NSApp.terminate(nil) }
    }

    /// Which dictionary XiaolaiDict studies from (decision D7), and what choosing each one can key: a
    /// dictionary that marks senses with nothing a parser can read will only ever give whole-entry
    /// cards, and the reader should see that before choosing it, not afterwards.
    private var studyFrom: some View {
        Menu("Study From") {
            Button { app.choosePrimaryDictionary(nil) } label: {
                Text(app.chosenDictionary == nil
                     ? "\u{2713} First that marks senses" : "First that marks senses")
            }
            Divider()
            if let dictionaries = app.dictionaries {
                ForEach(dictionaries, id: \.identity.key) { capability in
                    Button {
                        app.choosePrimaryDictionary(capability.identity.key)
                    } label: {
                        Text(app.chosenDictionary == capability.identity.key
                             ? "\u{2713} \(capability.identity.name)    · \(capability.note)"
                             : "\(capability.identity.name)    · \(capability.note)")
                    }
                }
            } else {
                Text("Asking the dictionary service…")
            }
        }
        // Asked when the menu is built rather than at launch: probing parses real entries, and
        // Longman's *hold* alone is 625 KB.
        .task { await app.askForDictionaries() }
    }
}
