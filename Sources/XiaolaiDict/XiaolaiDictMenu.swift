import AppKit
import XiaolaiDictCore
import SwiftUI

/// The menu-bar menu, as a SwiftUI view rather than an `NSMenu` rebuilt on every open.
///
/// The `NSMenu` it replaces had to be torn down and reassembled in `menuNeedsUpdate` so a problem
/// that appeared since launch would show. A view re-reads its state whenever that state changes,
/// which is the same guarantee without the ceremony. Settings is opened through the environment's
/// `openSettings`, not `SettingsLink`: an accessory app cannot reach the scene through
/// `showSettingsWindow:` at all, and `SettingsLink` opens the window without bringing XiaolaiDict
/// forward, which leaves it behind the app the reader is using.
struct XiaolaiDictMenu: View {
    let app: XiaolaiDictApp

    var body: some View {
        Button(app.shortcutLabel.map { "Look Up Selection    \($0)" } ?? "Look Up Selection") {
            app.lookUpSelection()
        }

        // Read from the watcher, not from the setting: if starting it failed, the menu says off.
        // The modifier is named from the policy, never as a literal. "hold ⌥" was hardcoded here
        // while `HoverModifier` had four cases, which was correct only for as long as the reader
        // could not change it — and a menu naming the wrong key is worse than naming none, since
        // the reader holds it and nothing happens.
        Toggle("Hover Lookup    hold \(app.hover.policy.modifier.symbol)", isOn: Binding(
            get: { app.hover.isWatching }, set: { _ in app.hover.toggle() }))

        // The pause switch (A5). It was specified, modelled, given three lengths and a label —
        // and never drawn, so `HoverPause.label(at:)`'s "what the menu says" described a menu that
        // did not exist. Resuming is one click; pausing picks a length, which is what having three
        // of them is for.
        if app.hover.isPaused {
            Button(app.hover.pauseLabel) { app.hover.resume() }
        } else {
            Menu(app.hover.pauseLabel) {
                ForEach(HoverPause.durations, id: \.self) { duration in
                    Button(HoverPause.name(of: duration)) { app.hover.pause(for: duration) }
                }
            }
        }

        Button(app.drawerIsVisible ? "Hide Reading History" : "Reading History") { app.toggleHistory() }

        studyFrom

        Divider()
        // Beside Settings rather than hidden in it: the board is the answer to "is this working?",
        // and a reader asking that has no reason to look under Settings for it.
        Button("Set Up…") { app.showSetup() }
        Button("Settings…") { app.showSettings() }

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
            Button { app.dictionary.choose(nil) } label: {
                Text(app.dictionary.chosen == nil
                     ? "\u{2713} First that marks senses" : "First that marks senses")
            }
            Divider()
            if let dictionaries = app.dictionary.enabled {
                ForEach(dictionaries, id: \.identity.key) { capability in
                    Button {
                        app.dictionary.choose(capability.identity.key)
                    } label: {
                        Text(verbatim: app.dictionary.chosen == capability.identity.key
                             ? "\u{2713} \(capability.identity.name)    · \(capability.note)"
                             : "\(capability.identity.name)    · \(capability.note)")
                    }
                }
            } else {
                Text("Asking the dictionary service…")
            }
        }
        // Asked when the menu is built rather than at launch: probing parses real entries, and
        // Longman's *hold* alone is 625 KB. The model is re-read here too — the other place the
        // reader looks — rather than inside the dictionary question, which is not about the model.
        .task {
            app.models.refresh()
            await app.askForDictionaries()
        }
    }
}
