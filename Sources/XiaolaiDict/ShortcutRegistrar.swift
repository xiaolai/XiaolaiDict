import Foundation
import Observation
import XiaolaiDictBase
import XiaolaiDictCore
import XiaolaiDictUI
import os

/// The lookup shortcut: what is registered with the system, what the reader is choosing, and what
/// to tell them when neither worked.
///
/// **Its own type because it is a state machine with three states that look like two.** A hot key
/// can be registered, or not registered because nothing has claimed one yet, or not registered
/// *because the reader is typing a replacement into the field* — and the last two are identical
/// from `hotkey == nil` while meaning opposite things. Every rule below was learned from a defect,
/// and they only hold together: read as separate lines on a 369-line delegate they are four
/// properties and four methods that happen to be adjacent.
///
/// The rules, in the order they were paid for:
///
/// - **Every way a recording can end must put the hot key back.** `suspend(false)` is idempotent,
///   because `ShortcutCapture` calls `onEnd` exactly once however it ends — a choice, Escape,
///   Cancel, the window closing or resigning key, the app deactivating.
/// - **A rollback that also fails must not be reported as a success.** When both registrations
///   failed, the reader used to be told XiaolaiDict was "still using" a shortcut that no longer
///   existed: no hot key registered, and a message naming one. The second failure also overwrote
///   the first, so the error described the recovery rather than the choice that caused it.
/// - **Suspension is recorded, never inferred.** `armTriggers` asks before it registers, so a
///   window-action capture landing mid-recording cannot take the key back from the field the reader
///   is typing into.
@Observable
@MainActor
final class ShortcutRegistrar {
    @ObservationIgnored private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "shortcut")
    /// **The suite the app was given, not `.standard`.** Built inline against the real preferences
    /// while `init(defaults:)` existed for exactly this reason, so every test that touched the
    /// shortcut rewrote the reader's own.
    @ObservationIgnored private let store: ShortcutStore
    /// Carbon's hot-key plumbing, injected so a test never registers a real global shortcut — which
    /// would take it from the reader for as long as the suite ran.
    @ObservationIgnored private let hotkeys: HotkeyCenter
    /// What a press does. Set once by the delegate, which owns the lookup.
    @ObservationIgnored private let onPress: @MainActor () -> Void

    private var hotkey: Hotkey?
    /// Nil when the shortcut is registered; otherwise what to tell the reader. Observed, so the
    /// menu redraws when it changes.
    private(set) var problem: String?
    /// Whether the recorder in Settings is armed. See `suspend(_:)`.
    private(set) var isSuspended = false

    init(defaults: UserDefaults, hotkeys: HotkeyCenter, onPress: @escaping @MainActor () -> Void) {
        store = ShortcutStore(defaults: defaults)
        self.hotkeys = hotkeys
        self.onPress = onPress
    }

    /// The shortcut as it stands: the one registered, or — while the field in Settings is armed and
    /// nothing is registered — the one on disk.
    var current: Shortcut { hotkey?.shortcut ?? store.load() }

    /// Whether XiaolaiDict is answering its shortcut. Read by the wiring tests, because "the field
    /// drew the right combination" and "the combination works" are different claims.
    var isRegistered: Bool { hotkey != nil }

    /// What the menu names, and nothing when there is no shortcut. The menu is the witness.
    var label: String? { hotkey?.shortcut.label() }

    /// Registers what is on disk. Called when there is a window to draw a lookup into, never at
    /// launch — see `XiaolaiDictApp.armTriggers`.
    @discardableResult
    func registerSaved() -> Hotkey.RegistrationFailed? { register(store.load()) }

    @discardableResult
    private func register(_ shortcut: Shortcut) -> Hotkey.RegistrationFailed? {
        hotkey = nil  // released first: registration is exclusive, and would collide with itself
        do {
            hotkey = try hotkeys.register(shortcut) { [weak self] in self?.onPress() }
            problem = nil
            return nil
        } catch {
            problem = String(localized: "\(shortcut.label()) is unavailable: \(String(describing: error))",
                             comment: "Menu warning when the lookup shortcut could not be registered")
            log.error("hotkey unavailable: \(String(describing: error), privacy: .public)")
            return error
        }
    }

    /// Stands the hot key down while the field is armed, and puts it back after.
    ///
    /// **Without this the one combination a reader most wants to change is the one they cannot.** A
    /// registered hot key is handled below the Cocoa event stream, so pressing the shortcut
    /// currently in use fires a lookup instead of reaching the field.
    ///
    /// Putting it back is conditional on nothing being registered, which makes it idempotent — the
    /// field disarms after a successful choice, and a `suspend(false)` that re-registered whatever
    /// was on disk would undo the choice a moment after the reader made it.
    func suspend(_ suspended: Bool) {
        isSuspended = suspended
        if suspended {
            hotkey = nil
        } else if hotkey == nil {
            registerSaved()
        }
    }

    /// Takes the reader's new shortcut: registers it, and saves it if it held. Nil means it held;
    /// otherwise the refusal says why — another app holds it, XiaolaiDict holds it for something
    /// else, or Carbon answered with a status — and the one that worked is left working.
    @discardableResult
    func choose(_ chosen: Shortcut) -> Hotkey.RegistrationFailed? {
        let previous = current
        guard chosen != previous || hotkey == nil else { return nil }
        if let refusal = register(chosen) {
            // Keep the problem with the new one in view, and the old one working — but only say so
            // if it *is* working. See the type's doc comment for what this cost.
            let refused = problem
            let restored = register(previous) == nil
            problem = refused.map {
                restored
                    ? String(localized: "\($0) — still using \(previous.label())",
                             comment: "The new shortcut was refused and the old one still works")
                    : String(localized: "\($0) — and \(previous.label()) could not be put back, so no shortcut is registered",
                             comment: "Both the new shortcut and the old one were refused")
            }
            return refusal
        }
        do {
            try store.save(chosen)
        } catch {
            log.error("shortcut not saved: \(String(describing: error), privacy: .public)")
            problem = String(localized: "\(chosen.label()) works now but was not saved: \(String(describing: error))",
                             comment: "The shortcut registered but could not be written to disk")
        }
        return nil
    }

    /// Settings' shortcut control, as `XiaolaiDictUI` needs it.
    ///
    /// Handed over rather than reached for: registering a combination with the system is Carbon,
    /// which lives here, and `XiaolaiDictUI` draws rather than registers.
    var choice: ShortcutChoice {
        ShortcutChoice(
            shortcut: current,
            choose: { [weak self] shortcut in
                // An app that is gone registered nothing, and must not be reported as having done so.
                guard let self else { return String(localized: "The app is not running") }
                return choose(shortcut)?.description
            },
            suspend: { [weak self] in self?.suspend($0) })
    }
}
