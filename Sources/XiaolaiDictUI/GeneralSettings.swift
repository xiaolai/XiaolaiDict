import AppKit
import Capture
import StudyKit
import SwiftUI
import XiaolaiDictCore

/// **Whether the menu bar icon is shown** — the one setting two targets have to agree about.
///
/// The Settings window writes it and the status item, in the app target, obeys it. They meet at
/// one key in the app's own defaults suite rather than at a shared object, so neither side has to
/// be built before the other and a test can drive either with a suite of its own.
///
/// **The key is `ShowsMenuBarIcon`, a Bool, and absent means shown.** A reader who has never
/// seen this setting has an icon; reading a missing key as `false` would hide the app's only
/// always-visible surface on the first launch after an update.
///
/// Two ways to follow it from the app target, and both see the same value:
/// `SettingsModel.showsMenuBarIcon` is observable (the settings model is the app's own instance),
/// and the key can be watched on the suite with key-value observing — `ShowsMenuBarIcon` is a
/// valid key path, which is why it has no dot in it.
public struct MenuBarIconSetting {
    public static let key = "ShowsMenuBarIcon"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// Shown unless the reader said otherwise. `object(forKey:)`, because `bool(forKey:)` answers
    /// `false` for a key that was never written.
    public func load() -> Bool {
        defaults.object(forKey: Self.key) as? Bool ?? true
    }

    public func save(_ shows: Bool) {
        defaults.set(shows, forKey: Self.key)
    }
}

/// **Which pane Settings opens on**, across launches.
///
/// The window opened on Setup at every launch, on the reasoning that nothing else led to the
/// board. That stopped being true when Setup became the first tab, and what was left was a reader
/// who changed their text size, quit, and came back to a board telling them everything was ready.
///
/// Two facts are kept, because the rule has two halves: the pane **the reader last chose**, and
/// whether setup was **unfinished the last time the board could say**. Setup wins while something
/// is still needed — that is what a reader opening Settings then is there for — and otherwise the
/// window opens where they left it.
///
/// **Only a choice the reader made is stored.** An instrument selecting panes to measure them, or
/// a link from the lookup window to the Dictionary pane, moves the window without being a
/// preference; `SettingsModel.choose(_:)` is the one writer.
public struct SettingsPaneStore {
    public static let paneKey = "SettingsPane"
    public static let setupUnfinishedKey = "SettingsSetupUnfinished"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// The pane to open on. Setup until the board has reported itself finished at least once:
    /// an install that has never been asked has, as far as anyone knows, everything still to do.
    public func openingPane() -> SettingsPane {
        let unfinished = defaults.object(forKey: Self.setupUnfinishedKey) as? Bool ?? true
        guard !unfinished else { return .setup }
        return defaults.string(forKey: Self.paneKey).flatMap(SettingsPane.init(rawValue:))
            .flatMap { SettingsPane.allCases.contains($0) ? $0 : nil } ?? .setup
    }

    public func save(_ pane: SettingsPane) {
        defaults.set(pane.rawValue, forKey: Self.paneKey)
    }

    public func save(setupUnfinished: Bool) {
        // Written only on a change: this is called from a poll, and a write a second is a write
        // nobody asked for.
        guard defaults.object(forKey: Self.setupUnfinishedKey) as? Bool != setupUnfinished else { return }
        defaults.set(setupUnfinished, forKey: Self.setupUnfinishedKey)
    }
}

/// Opening the app at login, as Settings needs it.
///
/// Handed in, like the dictionary and the shortcut: registering a login item is
/// `SMAppService`, which answers for the running bundle and so belongs to the app target. Here
/// it is three closures, and a preview or a test supplies its own.
public struct LoginItemChoice {
    public enum Status: Sendable, Equatable {
        case enabled
        case disabled
        /// Registered, and waiting on the reader in System Settings › General › Login Items.
        /// Not "enabled": the app will not open at login until they allow it there.
        case needsApproval
    }

    /// Asked every time rather than cached: the reader can change it in System Settings while
    /// this window is open, and a cached answer would draw a switch that is no longer true.
    public var status: @MainActor () -> Status
    /// Turns it on or off. Nil means it took; otherwise the answer is the system's own reason.
    public var set: @MainActor (Bool) -> String?
    /// Opens the Login Items list, for the reader who has to allow it there.
    public var openSystemSettings: @MainActor () -> Void

    public init(
        status: @escaping @MainActor () -> Status, set: @escaping @MainActor (Bool) -> String?,
        openSystemSettings: @escaping @MainActor () -> Void
    ) {
        self.status = status
        self.set = set
        self.openSystemSettings = openSystemSettings
    }
}

/// **How the app behaves and what it keeps** — as opposed to how a reading looks, which is the
/// Reading pane's.
///
/// A sixth pane, decided 2026-10-02. The Reading pane held seven sections under a text-size icon:
/// type, the card, the lookup window, the drawer's glass, what is saved for study, the voice, and
/// the one irreversible command in the app — and it scrolled. Two more settings were due (open at
/// login, the menu bar icon) and neither is about reading at all. A "Learning" tab was the other
/// candidate and would have held a single picker. So the split is by subject: this pane is the
/// app — when it starts, where it shows, what it saves, what it deletes — and Reading is left with
/// what a card looks and sounds like, which is what its icon says.
struct GeneralPane: View {
    var model: SettingsModel
    var keepPolicy: Binding<LookupKeepPolicy>?
    /// The two study options (R1b, R1c) — nil in a preview, which draws no switch wired to nothing.
    var study: StudyChoice?
    var reminders: ReminderChoice?
    var erase: ErasePresentation?
    var eraseAction: (@MainActor (EraseAction) -> Void)?

    /// What the login switch shows. Held, because the answer comes from the system and changes
    /// only when asked again — after a toggle, and whenever the window comes back.
    @State private var loginStatus: LoginItemChoice.Status?
    /// Why the last change to the login item did not take.
    @State private var loginRefusal: String?

    var body: some View {
        Form {
            startup
            menuBar
            if keepPolicy != nil || study != nil {
                StudySection(keepPolicy: keepPolicy, choice: study)
            }
            if let study {
                ReviewWaitSection(choice: study)
            }
            if let reminders {
                ReminderSection(choice: reminders)
            }
            if let erase, let eraseAction {
                EraseReadingSection(state: erase, act: eraseAction)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var startup: some View {
        if let login = model.loginItem {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { (loginStatus ?? login.status()) != .disabled },
                    set: { wanted in
                        loginRefusal = login.set(wanted)
                        // Asked again rather than assumed: a refusal leaves it where it was, and
                        // a switch that stayed on over a login item that was never registered
                        // would be the false tick this window keeps removing elsewhere.
                        loginStatus = login.status()
                    }))
                if (loginStatus ?? login.status()) == .needsApproval {
                    StatusLabel(
                        .caution,
                        "macOS is waiting for you to allow this in Login Items.",
                        size: Token.Text.form)
                    Button("Open Login Items Settings…") { login.openSystemSettings() }
                }
                if let loginRefusal {
                    StatusLabel(
                        .error, text: Text("That could not be changed: \(loginRefusal)"),
                        size: Token.Text.form)
                }
            } header: {
                Text("Startup")
            }
            // The reader may have been to System Settings and back.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                loginStatus = login.status()
            }
        }
    }

    private var menuBar: some View {
        @Bindable var model = model
        return Section {
            Toggle("Show in menu bar", isOn: $model.showsMenuBarIcon)
        } header: {
            Text("Menu Bar")
        } footer: {
            // **Says the way back, because hiding it removes the way in.** The icon is where
            // Settings, the Library and Quit live; a switch that hid it without saying how to
            // return would strand the reader with a hot key and nothing else.
            Text("""
                 With the icon hidden, the lookup shortcut and hover keep working. Open \
                 XiaolaiDict again from Finder or Spotlight to show the Library, where ⌘, opens \
                 these settings.
                 """)
        }
    }
}

/// What the hover controls are called, in the reader's own language.
///
/// **Here and not on the types themselves**, which live in `XiaolaiDictCore` — a module with no
/// view layer, where a word can be written and never extracted for a translator. They were there:
/// "Quick", "Hold", "Option" and five more were plain `String`s drawn with `Text(verbatim:)`, and
/// none had a key in the catalog. Every function switches over the cases, so a case added in the
/// core fails to compile here rather than appearing unnamed in a picker.
enum HoverLabels {
    static func name(of modifier: HoverModifier) -> String {
        switch modifier {
        case .option: String(localized: "Option", comment: "The Option key, in the hover key picker")
        case .control: String(localized: "Control", comment: "The Control key, in the hover key picker")
        case .command: String(localized: "Command", comment: "The Command key, in the hover key picker")
        case .shift: String(localized: "Shift", comment: "The Shift key, in the hover key picker")
        }
    }

    static func name(of gesture: HoverGesture) -> String {
        switch gesture {
        case .hold: String(localized: "Hold", comment: "Hover gesture: hold the key down")
        case .doubleTap: String(localized: "Double-Tap", comment: "Hover gesture: tap the key twice")
        }
    }

    static func name(of rest: HoverPolicy.Settle) -> String {
        switch rest {
        case .quick: String(localized: "Quick", comment: "How long the pointer rests before a hover lookup: shortest")
        case .standard: String(localized: "Standard", comment: "How long the pointer rests before a hover lookup: the default")
        case .relaxed: String(localized: "Relaxed", comment: "How long the pointer rests before a hover lookup: longer")
        case .patient: String(localized: "Patient", comment: "How long the pointer rests before a hover lookup: longest")
        }
    }
}
