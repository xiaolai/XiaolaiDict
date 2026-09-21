import AppKit
import Carbon.HIToolbox
import XiaolaiDictCore
@testable import XiaolaiDict
import Testing

/// Hot keys are routed by the ID each press carries, registered exclusively, and cleaned up with
/// their status checked. Carbon is faked: registering real global shortcuts from a test would take
/// them from the reader.
@MainActor
struct HotkeyTests {
    private let d = Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))
    private let e = Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(controlKey | optionKey))

    private func press(_ id: UInt32, signature: OSType = HotkeyCenter.signature) -> EventHotKeyID {
        EventHotKeyID(signature: signature, id: id)
    }

    /// Found by audit: every registration shared ID 1 and every press ran every action.
    @Test func aPressRunsOnlyItsOwnAction() throws {
        let center = HotkeyCenter(backend: FakeBackend())
        var fired: [String] = []
        let first = try center.register(d) { fired.append("d") }
        let second = try center.register(e) { fired.append("e") }
        #expect(center.route(press(2)) == noErr)
        #expect(fired == ["e"])
        withExtendedLifetime((first, second)) {}
    }

    /// Another app's hot key, or an ID XiaolaiDict never issued, is passed on untouched.
    @Test func aPressThatIsNotXiaolaiDictsIsNotHandled() throws {
        let center = HotkeyCenter(backend: FakeBackend())
        let hotkey = try center.register(d) { Issue.record("ran for a press that was not its own") }
        #expect(center.route(press(1, signature: OSType(0x4F54_4852))) == OSStatus(eventNotHandledErr))
        #expect(center.route(press(9)) == OSStatus(eventNotHandledErr))
        withExtendedLifetime(hotkey) {}
    }

    @Test func registrationIsExclusiveAndTheHandlerInstalledOnce() throws {
        let backend = FakeBackend()
        let center = HotkeyCenter(backend: backend)
        let hotkeys = [try center.register(d) {}, try center.register(e) {}]
        #expect(backend.installs == 1)
        #expect(backend.registered.count == 2)
        withExtendedLifetime(hotkeys) {}
    }

    @Test func aConflictIsReportedAsAnotherAppsClaim() {
        let backend = FakeBackend()
        backend.registerStatus = OSStatus(eventHotKeyExistsErr)
        let center = HotkeyCenter(backend: backend)
        #expect(throws: Hotkey.RegistrationFailed(reason: .status(OSStatus(eventHotKeyExistsErr)))) { try center.register(d) {} }
        #expect(Hotkey.RegistrationFailed(reason: .status(OSStatus(eventHotKeyExistsErr))).description.contains("another app"))
        #expect(center.registrationCount == 0)
    }

    /// A combination XiaolaiDict already holds is refused before Carbon is asked — so Carbon's "exists"
    /// can only mean another app, and the message saying so is true.
    @Test func ourOwnDuplicateIsNotBlamedOnAnotherApp() throws {
        let backend = FakeBackend()
        let center = HotkeyCenter(backend: backend)
        let held = try center.register(d) {}
        #expect(throws: Hotkey.RegistrationFailed(reason: .heldByXiaolaiDict)) { try center.register(d) {} }
        #expect(backend.registered.count == 1)
        #expect(!Hotkey.RegistrationFailed(reason: .heldByXiaolaiDict).description.contains("another app"))
        withExtendedLifetime(held) {}
    }

    /// Found by the verifier: after a failed release, XiaolaiDict forgot the shortcut while
    /// Carbon kept it — and registering it again blamed another app. It now says it is its own.
    @Test func aShortcutCarbonWouldNotReleaseIsStillXiaolaiDicts() throws {
        let backend = FakeBackend()
        backend.unregisterStatus = OSStatus(eventHotKeyInvalidErr)
        let center = HotkeyCenter(backend: backend)
        var hotkey: Hotkey? = try center.register(d) {}
        hotkey = nil
        #expect(throws: Hotkey.RegistrationFailed(reason: .unreleasedByXiaolaiDict)) { try center.register(d) {} }
        #expect(backend.registered.count == 1, "Carbon was asked again")
        _ = hotkey
    }

    /// Released, a hot key is unregistered with Carbon and stops routing — even when Carbon reports
    /// a failure, which is logged rather than ignored.
    @Test func releasingAHotkeyUnregistersIt() throws {
        let backend = FakeBackend()
        backend.unregisterStatus = OSStatus(eventHotKeyInvalidErr)
        let center = HotkeyCenter(backend: backend)
        var hotkey: Hotkey? = try center.register(d) {}
        #expect(center.registrationCount == 1)
        hotkey = nil
        #expect(backend.unregistered == 1)
        #expect(center.registrationCount == 0)
        #expect(center.route(press(1)) == OSStatus(eventNotHandledErr))
        _ = hotkey
    }
}

struct ShortcutTests {
    private func name(_ keyCode: UInt32) -> String? { keyCode == UInt32(kVK_ANSI_D) ? "d" : nil }

    /// The label is derived from the combination actually registered, modifiers in the system's
    /// order — not a string kept beside it that can drift.
    @Test func theLabelFollowsTheCombination() {
        #expect(Shortcut.defaultLookUp.label(keyName: name) == "⌃⌥D")
        let all = Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(all.label(keyName: name) == "⌃⌥⇧⌘D")
        #expect(Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey)).label(keyName: name) == "⌘F5")
    }

    @Test func aShortcutNeedsCommandControlOrOption() {
        #expect(Shortcut.defaultLookUp.isUsable)
        #expect(!Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: 0).isUsable)
        #expect(!Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(shiftKey)).isUsable)
    }

    @Test func aChosenShortcutIsKept() throws {
        let defaults = try #require(UserDefaults(suiteName: "com.xiaolaidict.tests.\(UUID().uuidString)"))
        let store = ShortcutStore(defaults: defaults)
        #expect(store.load() == .defaultLookUp)
        let chosen = Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey))
        try store.save(chosen)
        #expect(store.load() == chosen)
    }

    /// An unusable saved shortcut — edited by hand, or from a bug — is not registered.
    @Test func anUnusableSavedShortcutFallsBackToTheDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "com.xiaolaidict.tests.\(UUID().uuidString)"))
        let store = ShortcutStore(defaults: defaults)
        try store.save(Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: 0))
        #expect(store.load() == .defaultLookUp)
    }
}
