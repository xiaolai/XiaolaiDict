import Carbon.HIToolbox
import XiaolaiDictCore
import os

/// A system-wide keyboard shortcut. Carbon's `RegisterEventHotKey` is still the API for this that
/// needs no permission prompt — a global `NSEvent` monitor for keys needs Input Monitoring.
@MainActor
final class Hotkey {
    struct RegistrationFailed: Error, Equatable, CustomStringConvertible {
        enum Reason: Equatable {
            /// XiaolaiDict itself already holds this combination.
            case heldByXiaolaiDict
            /// XiaolaiDict once held it and Carbon would not release it; it is free again
            /// once the app quits.
            case unreleasedByXiaolaiDict
            case status(OSStatus)
        }

        let reason: Reason

        /// XiaolaiDict's own registrations are checked before Carbon is asked, so when Carbon's exclusive
        /// registration answers "exists", another app holds the combination.
        var description: String {
            switch reason {
            case .heldByXiaolaiDict: "XiaolaiDict already uses this shortcut for something else"
            case .unreleasedByXiaolaiDict: "XiaolaiDict could not release this shortcut earlier; quit and reopen the app to free it"
            case .status(let status) where status == eventHotKeyExistsErr: "another app has claimed this shortcut"
            case .status(let status): "the shortcut could not be registered (OSStatus \(status))"
            }
        }
    }

    let shortcut: Shortcut
    private let id: UInt32
    private let center: HotkeyCenter

    fileprivate init(shortcut: Shortcut, id: UInt32, center: HotkeyCenter) {
        self.shortcut = shortcut
        self.id = id
        self.center = center
    }

    isolated deinit {
        center.unregister(id)
    }
}

/// What XiaolaiDict needs from Carbon — the seam tests replace.
@MainActor
protocol HotkeyBackend {
    /// Installs the one application-wide handler. `route` returns whether the press was handled.
    func installHandler(_ route: @escaping @MainActor (EventHotKeyID) -> OSStatus) -> OSStatus
    func register(_ shortcut: Shortcut, id: EventHotKeyID) -> (OSStatus, EventHotKeyRef?)
    func unregister(_ reference: EventHotKeyRef) -> OSStatus
}

/// Carbon's hot-key plumbing, kept in one place: one application-wide handler, installed once and
/// never removed, which routes each press to the registration whose ID it carries. A press that is
/// not XiaolaiDict's is passed on untouched.
@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter(backend: CarbonHotkeyBackend())
    /// "XLDT": marks XiaolaiDict's registrations among every hot key the process sees. A Carbon
    /// signature is four characters, so it is an abbreviation rather than the name.
    static let signature = OSType(0x584C_4454)

    private let backend: any HotkeyBackend
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "hotkey")
    private var installed = false
    private var registrations: [UInt32: (shortcut: Shortcut, reference: EventHotKeyRef, action: @MainActor () -> Void)] = [:]
    private var nextID: UInt32 = 1
    /// Shortcuts Carbon failed to release: XiaolaiDict no longer routes them, but Carbon may still hold
    /// them for XiaolaiDict, so a later conflict on one is XiaolaiDict's own, not another app's.
    private var unreleased: [Shortcut] = []

    init(backend: any HotkeyBackend) {
        self.backend = backend
    }

    /// Exclusive: while XiaolaiDict holds the shortcut, no other app's registration fires on it — so a
    /// shortcut that works is one only XiaolaiDict answers.
    func register(_ shortcut: Shortcut, action: @escaping @MainActor () -> Void) throws(Hotkey.RegistrationFailed) -> Hotkey {
        guard !registrations.values.contains(where: { $0.shortcut == shortcut }) else {
            throw Hotkey.RegistrationFailed(reason: .heldByXiaolaiDict)
        }
        guard !unreleased.contains(shortcut) else { throw Hotkey.RegistrationFailed(reason: .unreleasedByXiaolaiDict) }
        if !installed {
            let status = backend.installHandler { [weak self] id in self?.route(id) ?? OSStatus(eventNotHandledErr) }
            guard status == noErr else { throw Hotkey.RegistrationFailed(reason: .status(status)) }
            installed = true
        }
        let id = nextID
        nextID += 1
        let (status, reference) = backend.register(shortcut, id: EventHotKeyID(signature: Self.signature, id: id))
        guard status == noErr, let reference else { throw Hotkey.RegistrationFailed(reason: .status(status)) }
        registrations[id] = (shortcut, reference, action)
        return Hotkey(shortcut: shortcut, id: id, center: self)
    }

    /// The action for the press, or "not handled" for any hot key that is not one of XiaolaiDict's.
    func route(_ pressed: EventHotKeyID) -> OSStatus {
        guard pressed.signature == Self.signature, let registration = registrations[pressed.id] else {
            return OSStatus(eventNotHandledErr)
        }
        registration.action()
        return noErr
    }

    fileprivate func unregister(_ id: UInt32) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        let status = backend.unregister(registration.reference)
        if status != noErr {
            unreleased.append(registration.shortcut)
            log.error("UnregisterEventHotKey failed (OSStatus \(status)); the shortcut may stay claimed until XiaolaiDict quits")
        }
    }

    /// For tests: how many shortcuts are registered.
    var registrationCount: Int { registrations.count }
}

/// The real backend. Carbon delivers hot-key events on the main thread, which is what makes
/// `assumeIsolated` sound. The handler takes no context pointer — it routes through a static — so
/// nothing it refers to can be freed under it.
struct CarbonHotkeyBackend: HotkeyBackend {
    @MainActor private static var route: ((EventHotKeyID) -> OSStatus)?

    func installHandler(_ route: @escaping @MainActor (EventHotKeyID) -> OSStatus) -> OSStatus {
        Self.route = route
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr else { return status }
                return MainActor.assumeIsolated { CarbonHotkeyBackend.route?(id) ?? OSStatus(eventNotHandledErr) }
            },
            1, &pressed, nil, nil)
    }

    func register(_ shortcut: Shortcut, id: EventHotKeyID) -> (OSStatus, EventHotKeyRef?) {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        return (status, reference)
    }

    func unregister(_ reference: EventHotKeyRef) -> OSStatus {
        UnregisterEventHotKey(reference)
    }
}
