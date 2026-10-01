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
                // **In the system font.** It was `.monospaced()`, which drew ⌃ as a raised caret
                // here while the same shortcut on the Setup pane had the proper glyph.
                Button(capture.isArmed ? String(localized: "Press a Shortcut…") : choice.shortcut.label()) {
                    capture.isArmed ? capture.end() : arm()
                }
                .buttonStyle(.bordered)
                // **Named, valued and hinted, because its title is neither.** The title is
                // "⌃⌥D" or "Press a Shortcut…": VoiceOver read glyph names and never said what
                // the control was for or that it was listening.
                .accessibilityLabel(Text("Lookup shortcut"))
                .accessibilityValue(Text(
                    capture.isArmed
                        ? String(localized: "Recording", comment: "VoiceOver: the shortcut field is waiting for a key combination")
                        : Self.spoken(choice.shortcut)))
                .accessibilityHint(Text("Records a new shortcut"))
                if capture.isArmed {
                    Button(String(localized: "Cancel")) { capture.end() }.buttonStyle(.link)
                }
            }
        }
        .background(WindowReader { window = $0 })
        if let note {
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // **And said aloud when it changes.** The instruction, the coaching and the refusal each
        // appear as a new line under the field, which a VoiceOver reader has no reason to go and
        // read: they pressed a key and, as far as they were told, nothing happened.
        EmptyView().onChange(of: note) { _, latest in
            guard let latest else { return }
            AccessibilityNotification.Announcement(latest).post()
        }
    }

    /// What the line under the field says, if anything: how to answer while listening, or why the
    /// last answer was not taken.
    private var note: String? {
        capture.isArmed ? coaching ?? Self.instruction : refusal
    }

    private static var instruction: String {
        String(localized: "Press a combination including ⌘, ⌃ or ⌥. Escape cancels.")
    }

    /// The shortcut in words — "Control Option D" — for VoiceOver, which reads `⌃⌥D` as the
    /// names of three symbols. In the system's own modifier order, like the label.
    static func spoken(_ shortcut: Shortcut, keyName: (UInt32) -> String? = Shortcut.currentLayoutName) -> String {
        let names: [(mask: Int, name: String)] = [
            (controlKey, String(localized: "Control", comment: "The Control key, in the hover key picker")),
            (optionKey, String(localized: "Option", comment: "The Option key, in the hover key picker")),
            (shiftKey, String(localized: "Shift", comment: "The Shift key, in the hover key picker")),
            (cmdKey, String(localized: "Command", comment: "The Command key, in the hover key picker")),
        ]
        let modifiers = names.filter { shortcut.modifiers & UInt32($0.mask) != 0 }.map(\.name)
        // The key as the label draws it, without the modifier glyphs in front.
        let key = Shortcut(keyCode: shortcut.keyCode, modifiers: 0).label(keyName: keyName)
        // The locale's own list, so VoiceOver pauses between the keys and nothing here spells a
        // separator.
        return (modifiers + [key]).formatted(.list(type: .and, width: .narrow))
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
        switch Self.verdict(on: shortcut) {
        case .coach(let line):
            // Refused with a line of coaching rather than accepted, and the field keeps
            // listening so the reader can try another.
            coaching = line
        case .accept:
            refusal = choice.choose(shortcut).map {
                String(localized: "\(shortcut.label()) can't be used: \($0).")
            }
            capture.end()
        }
    }

    /// What the recorder does with a combination: take it, or say why not and keep listening.
    enum Verdict: Equatable {
        case accept
        case coach(String)
    }

    /// **A function of the shortcut alone, so the rule can be tested without a key press.**
    ///
    /// Two refusals. A bare key, or shift and a key, would fire while the reader was typing. And
    /// a combination the system or every app already uses — ⌘C, ⌘Q, ⌘Space — would be taken
    /// from all of them: a registered hot key is swallowed before any app sees it, so one
    /// mis-press while recording made Copy look a word up, system-wide, with nothing said.
    static func verdict(
        on shortcut: Shortcut, keyName: (UInt32) -> String? = Shortcut.currentLayoutName
    ) -> Verdict {
        guard shortcut.isUsable else {
            return .coach(String(localized: "\(shortcut.label(keyName: keyName)) needs ⌘, ⌃ or ⌥ — try another."))
        }
        guard !shortcut.isReserved(keyName: keyName) else {
            return .coach(String(localized: "\(shortcut.label(keyName: keyName)) is a standard shortcut that other apps rely on — try another."))
        }
        return .accept
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
/// else does — which is also what lets ⌘Q and ⌘, arrive here rather than be acted on, so that
/// `ShortcutField.verdict(on:)` can refuse them with a reason instead of the app quitting — and
/// it exists only while armed, so there is nothing to swallow a key with the rest of the time.
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
