import AppKit
import Carbon.HIToolbox

/// Asks the reader for a new shortcut: a small window that takes the next key combination
/// pressed. Escape cancels; a combination without ⌘, ⌃ or ⌥ is refused with a hint.
@MainActor
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var completion: ((Shortcut?) -> Void)?

    /// Calls `completion` once: with the new shortcut, or nil when the reader cancels.
    func record(current: Shortcut, completion: @escaping (Shortcut?) -> Void) {
        finish(with: nil)
        self.completion = completion
        let hint = NSTextField(labelWithString: "Current: \(current.label()) · Esc cancels")
        hint.textColor = .secondaryLabelColor
        let catcher = KeyCatcher { [weak self, weak hint] shortcut in
            guard shortcut.isUsable else {
                hint?.stringValue = "\(shortcut.label()) needs ⌘, ⌃ or ⌥ — try another."
                return
            }
            self?.finish(with: shortcut)
        } onCancel: { [weak self] in
            self?.finish(with: nil)
        }
        let stack = NSStackView(views: [NSTextField(labelWithString: "Press the new shortcut for Look Up Selection"), hint, catcher])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Change Shortcut"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        // A settings action the reader chose: taking focus here is the point.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(catcher)
    }

    func windowWillClose(_ notification: Notification) {
        finish(with: nil)
    }

    private func finish(with shortcut: Shortcut?) {
        guard let completion else { return }
        self.completion = nil
        window?.delegate = nil
        window?.close()
        window = nil
        completion(shortcut)
    }

    /// Carbon's modifier flags for AppKit's — the form `RegisterEventHotKey` takes.
    nonisolated static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        return UInt32(modifiers)
    }
}

/// Takes key presses — including ⌘ combinations, which reach `performKeyEquivalent` before
/// `keyDown` — and turns each into a shortcut.
private final class KeyCatcher: NSView {
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
