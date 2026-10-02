import SwiftUI

/// The pane's search: a magnifier in the toolbar until the reader asks for it.
///
/// **Compact first, the way a macOS 27 toolbar keeps a search.** One glyph, which opens into a
/// field on a click or Command-F and folds away when it is left empty. `.searchable` cannot do
/// this on macOS: its field is always open, and `SearchToolbarBehavior.minimize` — the collapsing
/// behaviour — is marked unavailable on macOS in the SDK (read from the SwiftUI interface,
/// 2026-10-02). It was tried, in an audit pass, and put an open field across every pane.
///
/// **Nothing wipes a search under another name.** The earlier version of this had a close button
/// that cleared what was typed without saying so. Here the one control that clears is named Clear
/// Search; Escape does what it does in any search field — clears, then folds an empty one — and a
/// field with a search in it stays open, because the pane is still narrowed by it.
///
/// **The text is the view's and the search is the model's.** A search is read back from the ledger,
/// so the model's copy trails the keyboard; a field bound to that copy would be handed an older
/// string while the reader was still typing. So the field edits `text`, and every change of it
/// that the model has not already been sent goes to `search`.
struct LibrarySearch: ViewModifier {
    @Binding var text: String
    /// What the model is searching for now. Read once, when the pane appears, so a pane the
    /// reader comes back to shows the search it is still narrowed by.
    let current: String
    let prompt: LocalizedStringKey
    let search: @MainActor (String) -> Void
    @State private var sent: String?
    @State private var expanded = false
    @FocusState private var focused: Bool
    @Environment(\.scale) private var scale

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem {
                    if expanded || !text.isEmpty {
                        field
                    } else {
                        IconButton(.search, shortcut: KeyboardShortcut("f", modifiers: .command),
                                   size: Token.Library.toolbarGlyph) { open() }
                            .accessibilityIdentifier("library-search")
                    }
                }
            }
            .onAppear {
                sent = current
                text = current
            }
            .onChange(of: text) { _, typed in
                guard typed != sent else { return }
                sent = typed
                search(typed)
            }
    }

    private var field: some View {
        HStack(spacing: 0) {
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .frame(width: Token.Library.searchWidth)
                .padding(.leading, scale.space.inline)
                .focused($focused)
                .accessibilityIdentifier("library-search")
                .onExitCommand { text.isEmpty ? fold() : clear() }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused, text.isEmpty { expanded = false }
                }
                // The same, heard from AppKit: focus given through the window is not always
                // reported back through `@FocusState`, and an empty field left open is the
                // always-expanded search by another road.
                .onReceive(NotificationCenter.default.publisher(for: NSControl.textDidEndEditingNotification)) { _ in
                    if text.isEmpty { expanded = false }
                }
            IconButton(.clearSearch, size: Token.Library.toolbarGlyph) {
                clear()
                fold()
            }
            // Command-F while the field is already open goes back to it.
            Button("Search") { takeFocus(attemptsLeft: Token.Library.focusAttempts) }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func open() {
        expanded = true
        takeFocus(attemptsLeft: Token.Library.focusAttempts)
    }

    /// **Asked until it takes, a bounded number of times, and asked of AppKit.** The field
    /// replaces the magnifier in the toolbar, and a toolbar item is hosted apart from the pane:
    /// `@FocusState` set from here never reached it — asked once, then ten times a tenth apart,
    /// the collection kept the keyboard and the reader typed into nothing (E2E Mac, 2026-10-02).
    /// So the window is asked to make its toolbar's text field first responder, which is the
    /// thing a click on the field does.
    private func takeFocus(attemptsLeft: Int) {
        if Self.focusToolbarField() || attemptsLeft <= 0 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Token.Library.focusInterval) {
            if expanded { takeFocus(attemptsLeft: attemptsLeft - 1) }
        }
    }

    /// Makes the key window's toolbar text field first responder; false while there is none yet.
    private static func focusToolbarField() -> Bool {
        guard let window = NSApp.keyWindow, let items = window.toolbar?.items else { return false }
        func field(in view: NSView) -> NSTextField? {
            if let found = view as? NSTextField, found.isEditable { return found }
            for child in view.subviews { if let found = field(in: child) { return found } }
            return nil
        }
        for item in items {
            if let view = item.view, let found = field(in: view) { return window.makeFirstResponder(found) }
        }
        return false
    }

    private func clear() { text = "" }

    private func fold() {
        focused = false
        expanded = false
    }
}
