import AppKit
import Carbon.HIToolbox
import XiaolaiDictCore
import Observation
import SwiftUI

/// The reader's lookup shortcut, as Settings needs it.
///
/// Handed in, like the dictionary and the hover policy: registering a key combination with the
/// system is Carbon, which lives in the app target, and `XiaolaiDictUI` draws rather than registers.
public struct ShortcutChoice {
    public var shortcut: Shortcut
    /// Takes a new combination. Nil means it holds; otherwise the answer is why it does not — another
    /// app owns it, XiaolaiDict holds it for something else, Carbon refused it — and the control says so
    /// rather than showing a shortcut that does nothing. Why, and not merely whether: the field
    /// said "already taken" for every refusal, which is true of only one of them.
    public var choose: (Shortcut) -> String?
    /// Stands the global hot key down while the control is armed.
    ///
    /// **Without this the one shortcut a reader most wants to change is the one they cannot.**
    /// A registered hot key is handled below the Cocoa event stream, so pressing the combination
    /// currently in use fires a lookup instead of arriving here as a key press. Learned in TYPE,
    /// where the same control lives in the same place.
    public var suspend: (Bool) -> Void

    public init(shortcut: Shortcut, choose: @escaping (Shortcut) -> String?, suspend: @escaping (Bool) -> Void) {
        self.shortcut = shortcut
        self.choose = choose
        self.suspend = suspend
    }
}

/// The shortcut, and a way to change it — a control in Settings, not a window of its own.
///
/// It was a window: opening it activated XiaolaiDict, and closing it left XiaolaiDict active with no window,
/// which is how Settings came to appear by itself. A shortcut is a setting, and it belongs where
/// the reader's other settings are.
struct ShortcutField: View {
    @Environment(\.scale) private var scale
    let choice: ShortcutChoice
    /// The recorder, owned by the settings model: leaving the pane must end it, and this view
    /// cannot see that it has been left.
    var capture: ShortcutCapture

    @State private var window: NSWindow?
    /// What the field says while it is listening: how to answer it, or why the last key was not
    /// an answer. Shown only while armed, so ending a recording clears it by itself.
    @State private var coaching: String?
    /// Why the last combination did not take. Outlives the recording on purpose — the reader needs
    /// to read it after the field has stopped listening — and is cleared when they try again.
    @State private var refusal: String?

    var body: some View {
        LabeledContent("Look up the selection") {
            HStack(spacing: scale.space.inline) {
                Button(capture.isArmed ? String(localized: "Press a shortcut…") : choice.shortcut.label()) {
                    capture.isArmed ? capture.end() : arm()
                }
                .monospaced()
                .buttonStyle(.bordered)
                if capture.isArmed {
                    Button(String(localized: "Cancel")) { capture.end() }.buttonStyle(.link)
                }
            }
        }
        .background(WindowReader { window = $0 })
        if let note = capture.isArmed ? coaching ?? Self.instruction : refusal {
            Text(note)
                .font(.system(size: scale.text.label))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static var instruction: String {
        String(localized: "Press a combination including ⌘, ⌃ or ⌥. Escape cancels.")
    }

    private func arm() {
        coaching = nil
        refusal = nil
        // Stood down before listening, so the combination in use arrives here as a key press
        // rather than firing a lookup.
        choice.suspend(true)
        capture.begin(in: window, onPress: { press in
            switch press {
            case .cancel: capture.end()
            case .take(let shortcut): take(shortcut)
            }
        }, onEnd: {
            // However the recording ended — a choice, Escape, Cancel, the window closing, the
            // reader switching apps — the hot key comes back. Idempotent on the app's side, so the
            // path where `choose` already registered the new one costs nothing.
            choice.suspend(false)
        })
    }

    private func take(_ shortcut: Shortcut) {
        // A bare key, or shift and a key, would fire while the reader was typing. Refused with a
        // hint rather than accepted, and the field keeps listening so they can try another.
        guard shortcut.isUsable else {
            coaching = String(localized: "\(shortcut.label()) needs ⌘, ⌃ or ⌥ — try another.")
            return
        }
        refusal = choice.choose(shortcut).map {
            String(localized: "\(shortcut.label()) can't be used: \($0).")
        }
        capture.end()
    }
}

/// One recording of a shortcut: a local key monitor, and everything that ends it.
///
/// **A monitor, not the responder chain.** The field first caught keys with an `NSView` overriding
/// `keyDown` and `performKeyEquivalent`, and in a settings window both are wrong. AppKit offers
/// `performKeyEquivalent` to *every* view in the window, focused or not, so an unarmed field would
/// have taken ⌘W as the new lookup shortcut and eaten the close. And `keyDown` goes only to the
/// first responder, which a zero-sized background view was measured not to be: the field armed, the
/// key was pressed, and nothing arrived. A monitor sees every key bound for the app before anything
/// else does — which is also what lets ⌘Q and ⌘, be recorded rather than acted on — and it exists
/// only while armed, so there is nothing to swallow a key with the rest of the time.
///
/// TYPE moved to the same design for the same reasons, and learned the rest the hard way: a
/// recording that only ends when its view leaves the window never ends, because closing a window
/// does not detach its content. So everything that takes the reader's attention away ends it.
@Observable
@MainActor
public final class ShortcutCapture {
    public enum Press: Equatable {
        case cancel
        case take(Shortcut)
    }

    public private(set) var isArmed = false
    /// Whether a key monitor is installed. Separate from `isArmed` so a test can assert the thing
    /// that actually swallows keys is gone, not just a flag beside it.
    public var isListening: Bool { monitor != nil }

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var onEnd: (() -> Void)?

    /// What a key press means to a recording.
    ///
    /// Escape cancels only when it is bare. With a modifier it is someone recording, not someone
    /// reaching for the cancel key — TYPE cancelled on ⌥⎋ for a while, and a perfectly good
    /// combination could not be chosen. Caps Lock and fn ride along in the flags and are not
    /// modifiers of a shortcut, so only the four that are survive.
    public static func interpret(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Press {
        let modifiers = Shortcut.carbonModifiers(flags.intersection(.deviceIndependentFlagsMask))
        if keyCode == UInt16(kVK_Escape), modifiers == 0 { return .cancel }
        return .take(Shortcut(keyCode: UInt32(keyCode), modifiers: modifiers))
    }

    /// Starts listening for keys aimed at `window`. `onEnd` is called exactly once, however the
    /// recording ends.
    public func begin(
        in window: NSWindow?, onPress: @escaping (Press) -> Void, onEnd: @escaping () -> Void
    ) {
        guard !isArmed else { return }
        isArmed = true
        self.onEnd = onEnd
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isArmed else { return event }
            // Only keys aimed at this window. A local monitor is app-wide, so without this a key
            // pressed in a pinned note would be swallowed and saved as the shortcut.
            guard event.window == nil || event.window === window else { return event }
            onPress(Self.interpret(keyCode: event.keyCode, flags: event.modifierFlags))
            return nil
        }
        let centre = NotificationCenter.default
        let end: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            observers.append(centre.addObserver(forName: name, object: window, queue: .main, using: end))
        }
        observers.append(centre.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: end))
    }

    /// And if the recorder itself goes away while armed, it still ends — monitor removed, hot key
    /// put back — rather than leaving a monitor installed that nothing will remove and a shortcut
    /// stood down until XiaolaiDict is relaunched. A safety net, not the pane switch's answer: Settings
    /// keeps a hidden pane alive, so switching panes releases nothing — `isShowing` handles that.
    public init() {}

    isolated deinit { end() }

    public func end() {
        guard isArmed else { return }
        isArmed = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        let finished = onEnd
        onEnd = nil
        finished?()
    }
}

public extension Shortcut {
    /// Cocoa's modifier flags as Carbon's, which is what registering a hot key takes.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        return UInt32(modifiers)
    }
}
