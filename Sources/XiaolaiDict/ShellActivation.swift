import AppKit
import XiaolaiDictBase
import os

/// **Whether XiaolaiDict is in the Dock and the application switcher: only while a window the
/// reader chose is open.**
///
/// It is a menu bar app (`LSUIElement`, `.accessory`), and stayed one even with the Library open —
/// a 1,200-point window the reader types into, which then slid behind whatever they clicked next
/// with no Dock icon, no Command-Tab entry and no menu bar to come back by; the only way back was
/// the right-click menu (audit M13, 2026-10-02). So the policy follows the windows: `.regular`
/// while the Library or Settings is open, `.accessory` again when the last of them closes.
///
/// **The panel, the drawer and pinned notes never count.** They appear while the reader is
/// mid-sentence in another app, and `AGENTS.md` is plain that none of them may activate this one.
/// Changing the policy does not activate anything — `setActivationPolicy` is not `activate()` —
/// and nothing here is called from their paths; the rule is also the reason they are a separate
/// case of `Kind` rather than simply absent, so that adding one to the "chosen" set is an edit to a
/// switch the tests read.
///
/// **Not forbidden by "Windows and panels"**, which was checked before this was written: that
/// section governs who may *activate* and who may be key. The two windows this follows are the two
/// it already says must come forward.
enum ShellActivation {
    /// What a window is, as far as the Dock is concerned.
    enum Kind: Equatable {
        case library, settings
        /// The lookup panel, the history drawer, a pinned note.
        case floating
        /// Anything else AppKit lists: the status bar's own window, a menu, a sheet.
        case other

        /// Whether the reader opened it on purpose, to work in.
        var isChosen: Bool {
            switch self {
            case .library, .settings: true
            case .floating, .other: false
            }
        }
    }

    struct Window: Equatable {
        let kind: Kind
        let isVisible: Bool
        /// The window a will-close notification is about: still visible when asked, and gone a
        /// moment later.
        var isClosing = false
    }

    /// The whole decision. `opening` is a chosen window that has been asked for and does not exist
    /// yet — the policy changes *before* the window opens, so it comes forward as a regular app's.
    static func policy(for windows: [Window], opening: Kind? = nil) -> NSApplication.ActivationPolicy {
        if opening?.isChosen == true { return .regular }
        let chosen = windows.contains { $0.kind.isChosen && $0.isVisible && !$0.isClosing }
        return chosen ? .regular : .accessory
    }

    /// Classified by the scene's identifier, never by a title, which is localised. SwiftUI's
    /// settings window carries no scene id of ours, so the app hands over the one it captured.
    static func kind(ofIdentifier identifier: String?, isSettings: Bool) -> Kind {
        if isSettings { return .settings }
        guard let identifier else { return .other }
        if identifier.contains(XiaolaiDictScene.libraryID) { return .library }
        if identifier.contains(XiaolaiDictScene.lookupID) || identifier.contains(XiaolaiDictScene.drawerID) {
            return .floating
        }
        return .other
    }
}

/// Applies `ShellActivation` to the running app.
///
/// **What it does to the system is injected**, so a unit test that opens the Library neither puts
/// the test runner in the Dock nor brings it in front of whoever is at the building Mac — the same
/// objection this project makes to a test that writes the reader's defaults.
@MainActor
final class ShellActivationController {
    /// The two things this does to the running app.
    struct System {
        var setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
        var activate: @MainActor () -> Void

        /// The real ones. Named by `XiaolaiDictApp.init()` and by nothing else.
        static let appKit = System(
            setPolicy: { NSApplication.shared.setActivationPolicy($0) },
            activate: { NSApplication.shared.activate() })
        /// Does nothing — what a test gets unless it asks to watch.
        static let inert = System(setPolicy: { _ in }, activate: {})
    }

    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "windows")
    private let system: System
    private let settingsWindow: @MainActor () -> NSWindow?
    private var closeObserver: (any NSObjectProtocol)?
    private(set) var current: NSApplication.ActivationPolicy = .accessory

    init(system: System, settingsWindow: @escaping @MainActor () -> NSWindow?) {
        self.system = system
        self.settingsWindow = settingsWindow
    }

    /// Starts following window closes. Not in `init`: a test builds the app without wanting an
    /// observer on every window its process closes.
    func watchForClosingWindows() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated { self?.reconsider(closing: closing) }
        }
    }

    /// A window the reader chose is about to be opened: into the Dock first, then forward, so it
    /// arrives as a regular app's window rather than an accessory's behind the app in front.
    ///
    /// **Only for a chosen window.** Asked for anything else this does nothing at all — no policy,
    /// no activation — so a panel routed here by mistake still cannot activate the app.
    func bringForward(for kind: ShellActivation.Kind) {
        guard kind.isChosen else {
            log.fault("activation: asked to bring the app forward for a window the reader did not choose")
            return
        }
        set(ShellActivation.policy(for: windows(closing: nil), opening: kind), because: "a window was asked for")
        system.activate()
    }

    /// A window is going, or one that was asked for never came; decide again from what is
    /// actually there. **The only route back to `.accessory`.**
    func reconsider(closing: NSWindow? = nil) {
        set(ShellActivation.policy(for: windows(closing: closing)), because: "the windows changed")
    }

    /// A chosen window was attached to its view — which is how the launch-time setup board
    /// arrives, without anybody having asked through `bringForward`.
    ///
    /// **Raises, never lowers.** The view reports its window before the window is ordered in, and
    /// again on every SwiftUI update, so deciding in full here would send an app whose Library is
    /// a moment from appearing back out of the Dock. It looks now and once more a turn later, when
    /// the window has had the chance to be on screen.
    func windowAttached() {
        raiseIfAChosenWindowIsVisible()
        DispatchQueue.main.async { [weak self] in self?.raiseIfAChosenWindowIsVisible() }
    }

    private func raiseIfAChosenWindowIsVisible() {
        guard ShellActivation.policy(for: windows(closing: nil)) == .regular else { return }
        set(.regular, because: "a chosen window is on screen")
    }

    private func windows(closing: NSWindow?) -> [ShellActivation.Window] {
        let settings = settingsWindow()
        return NSApplication.shared.windows.map { window in
            ShellActivation.Window(
                kind: ShellActivation.kind(
                    ofIdentifier: window.identifier?.rawValue, isSettings: settings != nil && window === settings),
                isVisible: window.isVisible, isClosing: closing != nil && window === closing)
        }
    }

    private func set(_ policy: NSApplication.ActivationPolicy, because reason: String) {
        guard policy != current else { return }
        current = policy
        log.notice("activation policy: \(policy == .regular ? "regular" : "accessory", privacy: .public) because \(reason, privacy: .public)")
        system.setPolicy(policy)
    }

    isolated deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
}
