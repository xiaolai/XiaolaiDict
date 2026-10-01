import Carbon.HIToolbox
import XiaolaiDictBase
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
            case .heldByXiaolaiDict: "this shortcut is already used for something else in this app"
            case .unreleasedByXiaolaiDict: "this shortcut could not be released earlier; quit and reopen the app to free it"
            case .status(let status) where status == eventHotKeyExistsErr: "another app has claimed this shortcut"
            case .status(let status): "the shortcut could not be registered (OSStatus \(status))"
            }
        }

        /// The same four reasons, **for the reader rather than the log**. `description` is English
        /// and is what `log.error` prints; it used to be interpolated into the menu's warning and
        /// the settings field's refusal as well, so a translated sentence carried an untranslated
        /// clause and, for the last case, a Carbon status code nobody can act on.
        var readerText: String {
            switch reason {
            case .heldByXiaolaiDict:
                String(localized: "This shortcut is already used for something else in this app.",
                       comment: "Why a lookup shortcut was refused")
            case .unreleasedByXiaolaiDict:
                String(localized: "This shortcut could not be released earlier. Quit and reopen the app to free it.",
                       comment: "Why a lookup shortcut was refused")
            case .status(let status) where status == eventHotKeyExistsErr:
                String(localized: "Another app has claimed this shortcut.",
                       comment: "Why a lookup shortcut was refused")
            case .status(let status):
                // The number stays: it is the one thing a reader can quote when asking for help,
                // and without it this case is indistinguishable from the three above.
                String(localized: "The system would not register this shortcut (error \(status)).",
                       comment: "Why a lookup shortcut was refused; the placeholder is a system error number")
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

    /// **The one Escape claim this centre makes**, shared by every surface that Escape dismisses.
    /// Lazy so a centre nothing dismisses with registers nothing, and held here so "one claim per
    /// centre" is a fact of the type rather than a convention between two controllers.
    private(set) lazy var escape = EscapeStack(hotkeys: self)
}

/// **One Escape claim, and a stack of what it dismisses — topmost first.**
///
/// The lookup panel and the history drawer each used to register bare Escape for themselves.
/// Registration is exclusive, so whichever showed second was refused as `.heldByXiaolaiDict`, the
/// refusal was only logged, and the reader was left with a panel Escape did nothing for: with the
/// drawer open, a lookup's first Escape closed the drawer and every later one went nowhere. Found by
/// the interface audit of 2026-10-02 (M4).
///
/// So the claim is made once, when the first surface asks, and released when the last one leaves.
/// A press runs the **most recently shown** surface's handler and nothing else; that handler
/// dismisses its surface, which pops it, and the next press reaches the one beneath.
///
/// **Bare Escape, system-wide, is a deliberate departure** from the guidance that an app should not
/// take an unmodified key from the app in front (HIG, keyboard shortcuts — the audit's 13.8, M15).
/// The reason: neither surface can become key — `.plain` windows answer `canBecomeKey` false, and
/// "no panel may rely on being key" is the project's own rule — so an ordinary key event never
/// reaches them, and a global key *monitor* needs Accessibility and cannot consume the press. The
/// cost is bounded by holding the claim only while one of them is on screen.
///
/// **A hover-summoned panel claims it too**, which the audit asked to be reconsidered. Kept, for
/// three reasons: hover requires a gesture (`HoverGesture` is a held or double-tapped modifier), so
/// the panel is not one the reader failed to ask for; the panel has no close button, so without
/// Escape the only way out is a click somewhere else, which the app in front then acts on; and the
/// claim is already released by the first press, which is the audit's own alternative.
@MainActor
final class EscapeStack {
    /// Escape with no modifiers. Carbon's hot keys match modifiers exactly, so ⇧⎋ and ⌘⎋ stay with
    /// the app in front.
    static let shortcut = Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0)

    /// A surface's place in the stack. Opaque: all an owner can do with one is hand it back.
    struct Entry: Equatable { fileprivate let id: Int }

    private unowned let hotkeys: HotkeyCenter
    private var held: Hotkey?
    /// Bottom first; the last element is the surface Escape dismisses next.
    private var handlers: [(entry: Entry, dismiss: @MainActor () -> Void)] = []
    private var nextID = 0
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "hotkey")

    fileprivate init(hotkeys: HotkeyCenter) {
        self.hotkeys = hotkeys
    }

    /// Whether Escape is XiaolaiDict's right now. False with handlers waiting means the claim was
    /// refused, which `push` has already logged.
    var isClaimed: Bool { held != nil }
    /// How many surfaces Escape would dismiss, one press each.
    var depth: Int { handlers.count }

    /// Puts a surface on top, claiming Escape if this is the first.
    ///
    /// **The entry is returned even when the claim is refused**, so the surface keeps its place and
    /// the next push tries the claim again — a refusal at one moment is not a refusal for the life
    /// of the surface.
    func push(_ dismiss: @escaping @MainActor () -> Void) -> Entry {
        nextID += 1
        let entry = Entry(id: nextID)
        handlers.append((entry, dismiss))
        claimIfNeeded()
        return entry
    }

    /// Moves a surface already in the stack to the top: it was shown again, so it is the one the
    /// reader is looking at. An entry that is not in the stack is left alone.
    func raise(_ entry: Entry) {
        guard let index = handlers.firstIndex(where: { $0.entry == entry }) else { return }
        handlers.append(handlers.remove(at: index))
        claimIfNeeded()
    }

    /// Takes a surface out, wherever it is, and gives Escape back when none is left.
    func pop(_ entry: Entry) {
        handlers.removeAll { $0.entry == entry }
        if handlers.isEmpty { held = nil }
    }

    /// Whether this surface is still waiting for Escape.
    func contains(_ entry: Entry) -> Bool { handlers.contains { $0.entry == entry } }

    private func claimIfNeeded() {
        guard held == nil, !handlers.isEmpty else { return }
        do {
            held = try hotkeys.register(Self.shortcut) { [weak self] in self?.pressed() }
        } catch {
            // **Not "the panel still has its close button".** It has none: the scenes are
            // `.windowStyle(.plain)`, which draws no title bar and no traffic lights. What is left
            // is the click-away dismissal, and Escape stays with the app being read. Logged loudly
            // for that reason: the reader keeps one way out rather than two, and nothing on screen
            // says so.
            log.error("Escape not claimed for \(self.handlers.count, privacy: .public) surface(s): \(String(describing: error), privacy: .public)")
        }
    }

    /// The topmost handler alone. It is expected to dismiss its surface, which pops it; one that
    /// does not is simply asked again on the next press rather than skipped, because skipping would
    /// dismiss a surface *under* one still on screen.
    private func pressed() {
        handlers.last?.dismiss()
    }
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
