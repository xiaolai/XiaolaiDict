import Carbon.HIToolbox
import Foundation
import XiaolaiDictCore
import XiaolaiDictUI
import Testing

@testable import XiaolaiDict

/// **The shortcut is a setting, and these test the wire rather than the model.**
///
/// It used to be a window of its own: choosing "Change Shortcut…" activated XiaolaiDict to open it, and
/// closing it left XiaolaiDict active with no window — which is how the settings window came to appear by
/// itself, seconds after the reader had closed something else. The recorder is now a control in
/// Settings, and what has to hold is that the control reaches the hot key: a field that drew the
/// right combination and registered nothing would look exactly like a working one.
///
/// Carbon is faked throughout. Registering real global shortcuts from a test would take them from
/// the reader, and the preferences suite is a fresh one per test for the same reason.
@MainActor struct ShortcutSettingsWiringTests {
    private static let other = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey))

    private func app(_ backend: FakeBackend, defaults: UserDefaults? = nil) -> XiaolaiDictApp {
        XiaolaiDictApp(
            defaults: defaults ?? UserDefaults(suiteName: "xiaolaidict.app.test.\(UUID().uuidString)")!,
            hotkeys: HotkeyCenter(backend: backend))
    }

    /// The control Settings draws is connected to the app's own hot key — asserted by *using* it,
    /// not by comparing two properties that could both be reading the same dead value.
    @Test func choosingFromSettingsChangesTheAppsShortcut() {
        let app = app(FakeBackend())
        #expect(app.shortcutChoice.shortcut == app.currentShortcut)
        #expect(app.shortcutChoice.choose(Self.other) == nil)
        #expect(app.currentShortcut == Self.other)
        #expect(app.shortcutIsRegistered)
    }

    /// **The one combination a reader most wants to change is the one they cannot press.** A
    /// registered hot key is handled below the Cocoa event stream, so while XiaolaiDict still answers it
    /// the key press fires a lookup instead of arriving in the field. Arming stands it down.
    @Test func armingTheFieldStandsTheHotKeyDown() {
        let app = app(FakeBackend())
        #expect(app.chooseShortcut(.defaultLookUp) == nil)
        #expect(app.shortcutIsRegistered)

        app.shortcutChoice.suspend(true)
        #expect(!app.shortcutIsRegistered, "the field is armed and XiaolaiDict still answers the shortcut")

        app.shortcutChoice.suspend(false)
        #expect(app.shortcutIsRegistered, "the shortcut was not put back when the field disarmed")
        #expect(app.currentShortcut == .defaultLookUp)
    }

    /// Disarming after a successful choice must not undo it. The field calls `choose` and then
    /// `suspend(false)`, and a `suspend` that re-registered whatever was stored would put the old
    /// combination back a moment after the reader set the new one.
    @Test func disarmingAfterAChoiceKeepsTheNewShortcut() {
        let app = app(FakeBackend())
        #expect(app.shortcutChoice.choose(Self.other) == nil)
        app.shortcutChoice.suspend(false)
        #expect(app.currentShortcut == Self.other)
    }

    /// What the reader chose is there next launch.
    @Test func theChosenShortcutSurvivesALaunch() {
        let suite = UserDefaults(suiteName: "xiaolaidict.app.test.\(UUID().uuidString)")!
        #expect(app(FakeBackend(), defaults: suite).chooseShortcut(Self.other) == nil)
        #expect(app(FakeBackend(), defaults: suite).currentShortcut == Self.other)
    }

    /// XiaolaiDict writes the reader's shortcut into the suite it was given, never into the real
    /// preferences. `ShortcutStore(defaults: .standard)` was built inline while `init(defaults:)`
    /// existed precisely so a test could be given a suite of its own — so every test that touched
    /// the shortcut changed the machine it ran on.
    @Test func theShortcutIsSavedInTheSuiteTheAppWasGiven() {
        let suite = UserDefaults(suiteName: "xiaolaidict.app.test.\(UUID().uuidString)")!
        #expect(app(FakeBackend(), defaults: suite).chooseShortcut(Self.other) == nil)
        #expect(ShortcutStore(defaults: suite).load() == Self.other)
    }

    /// A combination another app holds is refused, and the reader keeps the one that worked —
    /// registered, and still the one on disk. Refusing *and* leaving them with nothing would be
    /// the worse half of the same failure.
    @Test func aRefusedShortcutLeavesTheOldOneWorking() {
        let suite = UserDefaults(suiteName: "xiaolaidict.app.test.\(UUID().uuidString)")!
        let backend = FakeBackend()
        let app = app(backend, defaults: suite)
        #expect(app.chooseShortcut(.defaultLookUp) == nil)

        backend.refused = [Self.other]
        #expect(app.chooseShortcut(Self.other) != nil, "a combination another app holds must be refused")
        #expect(app.currentShortcut == .defaultLookUp, "the reader lost the shortcut that worked")
        #expect(app.shortcutIsRegistered)
        #expect(ShortcutStore(defaults: suite).load() == .defaultLookUp, "the refused shortcut was saved")
        #expect(app.problems.contains { $0.contains("still using") },
                "a refusal the reader is never told about is a shortcut that silently did nothing")
    }

    /// **A refusal says why.** The field said "is already taken" for every refusal, while the hot-key
    /// layer tells four apart — another app holds it, XiaolaiDict holds it for something else,
    /// it could not release the shortcut earlier, or Carbon answered with a status. Only the
    /// first is "taken", and a reader told so about the others would try combination after
    /// combination against a cause no combination fixes.
    @Test func aRefusalSaysWhy() {
        let backend = FakeBackend()
        let app = app(backend)
        backend.refused = [Self.other]
        let reason = app.shortcutChoice.choose(Self.other)
        #expect(reason?.contains("another app") == true, "the field was told \(String(describing: reason))")

        backend.refused = []
        backend.registerStatus = OSStatus(paramErr)
        let other = app.shortcutChoice.choose(Shortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | optionKey)))
        #expect(other?.contains("\(paramErr)") == true, "a Carbon status came back as \(String(describing: other))")
    }

    /// Cocoa's modifier flags as Carbon's — the conversion the field needs to build a `Shortcut`
    /// from an `NSEvent`, which is the only thing that carries a raw key code.
    @Test func cocoaModifiersBecomeCarbons() {
        #expect(Shortcut.carbonModifiers([.control, .option]) == UInt32(controlKey | optionKey))
        #expect(Shortcut.carbonModifiers([.command, .shift]) == UInt32(cmdKey | shiftKey))
        #expect(Shortcut.carbonModifiers([]) == 0)
    }
}
