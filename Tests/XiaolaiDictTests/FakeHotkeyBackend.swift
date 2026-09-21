import Carbon.HIToolbox
import XiaolaiDictCore
@testable import XiaolaiDict

/// Carbon's hot-key calls, recorded instead of made: registering real global shortcuts from a test
/// would take them from the reader.
@MainActor
final class FakeBackend: HotkeyBackend {
    var installs = 0
    var registered: [EventHotKeyID] = []
    var shortcuts: [Shortcut] = []
    var unregistered = 0
    var registerStatus = noErr
    var unregisterStatus = noErr
    /// Combinations this fake answers "another app has it" for, so a test can refuse **one**
    /// shortcut rather than every registration. `registerStatus` is global, and a test that used it
    /// to refuse a new shortcut also refused the old one being put back — which would assert that
    /// the reader is left with nothing, rather than that they keep what they had.
    var refused: [Shortcut] = []

    func installHandler(_ route: @escaping @MainActor (EventHotKeyID) -> OSStatus) -> OSStatus {
        installs += 1
        return noErr
    }

    func register(_ shortcut: Shortcut, id: EventHotKeyID) -> (OSStatus, EventHotKeyRef?) {
        guard registerStatus == noErr else { return (registerStatus, nil) }
        guard !refused.contains(shortcut) else { return (OSStatus(eventHotKeyExistsErr), nil) }
        registered.append(id)
        shortcuts.append(shortcut)
        return (noErr, EventHotKeyRef(bitPattern: Int(id.id)))
    }

    func unregister(_ reference: EventHotKeyRef) -> OSStatus {
        unregistered += 1
        return unregisterStatus
    }
}
