import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// What the shortcut-recording window is showing.
@Observable
@MainActor
final class ShortcutRecorderModel {
    var current = Shortcut(keyCode: 0, modifiers: 0)
    /// Refreshed in place when the reader presses something unusable, so the window teaches
    /// rather than simply refusing.
    var hint = ""
}

/// Asks the reader for a new shortcut: a small window that takes the next key combination
/// pressed. Escape cancels; a combination without ⌘, ⌃ or ⌥ is refused with a hint.
@MainActor
final class ShortcutRecorder: NSObject {
    let model = ShortcutRecorderModel()
    private var completion: ((Shortcut?) -> Void)?

    /// Calls `completion` once: with the new shortcut, or nil when the reader cancels.
    func record(current: Shortcut, completion: @escaping (Shortcut?) -> Void) {
        finish(with: nil)
        self.completion = completion
        model.current = current
        model.hint = "Current: \(current.label()) · Esc cancels"
        // A settings action the reader chose: taking focus here is the point, unlike every panel.
        NSApplication.shared.activate()
        WindowActions.shared.open?(id: XiaolaiDictScene.shortcutID)
    }

    /// The reader pressed something. Unusable combinations are answered with a hint rather than
    /// accepted, because a shortcut without a modifier would fire while they were typing.
    func pressed(_ shortcut: Shortcut) {
        guard shortcut.isUsable else {
            model.hint = "\(shortcut.label()) needs ⌘, ⌃ or ⌥ — try another."
            return
        }
        finish(with: shortcut)
    }

    func cancelled() { finish(with: nil) }

    private func finish(with shortcut: Shortcut?) {
        guard let completion else { return }
        self.completion = nil
        WindowActions.shared.dismiss?(id: XiaolaiDictScene.shortcutID)
        completion(shortcut)
    }

    nonisolated static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        return UInt32(modifiers)
    }
}

final class KeyCatcher: NSView {
    private let onKey: (Shortcut) -> Void
    private let onCancel: () -> Void

    init(onKey: @escaping (Shortcut) -> Void, onCancel: @escaping () -> Void) {
        self.onKey = onKey
        self.onCancel = onCancel
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        take(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        take(event)
        return true
    }

    private func take(_ event: NSEvent) {
        let modifiers = ShortcutRecorder.carbonModifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        if event.keyCode == UInt16(kVK_Escape), modifiers == 0 { return onCancel() }
        onKey(Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers))
    }
}


/// The recording window's content.
struct ShortcutRecorderView: View {
    let recorder: ShortcutRecorder
    @Bindable var model: ShortcutRecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Press the new shortcut for Look Up Selection")
            Text(model.hint)
                .font(.callout)
                .foregroundStyle(.secondary)
            // The capture stays AppKit. SwiftUI's `onKeyPress` reports a `KeyEquivalent`, and what
            // `RegisterEventHotKey` needs is the raw key code — which only `NSEvent` carries.
            KeyCatcherView(onKey: recorder.pressed, onCancel: recorder.cancelled)
                .frame(width: 1, height: 1)
        }
        .padding(20)
        .frame(minWidth: 380, alignment: .leading)
        // The one window in XiaolaiDict that must take focus. Activating before the window exists does
        // not hold — measured: the window came up `main` but not `focused`, with XiaolaiDict not the
        // frontmost app, so every key press went somewhere else and Escape could not even cancel.
        .background(WindowAccessor { window in
            NSApplication.shared.activate()
            window.makeKeyAndOrderFront(nil)
        })
    }
}

private struct KeyCatcherView: NSViewRepresentable {
    let onKey: (Shortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let catcher = KeyCatcher(onKey: onKey, onCancel: onCancel)
        // Retried until the window is key: asking once, before the window has been given focus,
        // silently does nothing and the first key press is lost with no sign of why.
        // Retried until the window exists and has taken the responder. Waiting for `isKeyWindow`
        // first never finished: the window came up main but not key, so the condition held forever
        // and the catcher was never asked for — which reads exactly like "the key press did
        // nothing". `makeFirstResponder` works on a window that is not yet key; when it becomes
        // key the responder is already in place.
        func claimFocus(attempt: Int = 0) {
            guard attempt < 40 else { return }
            if let window = catcher.window {
                window.makeKeyAndOrderFront(nil)
                if window.firstResponder === catcher { return }
                window.makeFirstResponder(catcher)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { claimFocus(attempt: attempt + 1) }
        }
        claimFocus()
        return catcher
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
