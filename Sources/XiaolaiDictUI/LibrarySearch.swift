import SwiftUI

/// The pane's search: the system's own field, in the toolbar, named for what it searches.
///
/// **`searchable`, not a field of our own.** It was a magnifier button that swapped itself for a
/// bordered `TextField` and a close button, all inside the capsule the layout toggles shared, and
/// closing it wiped what had been typed without saying so. The system's field is always there, its
/// prompt says which pane it searches, and the only thing that clears it is its own clear button.
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
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(text: $text, placement: .toolbar, prompt: prompt)
            .searchFocused($focused)
            .onAppear {
                sent = current
                text = current
            }
            .onChange(of: text) { _, typed in
                guard typed != sent else { return }
                sent = typed
                search(typed)
            }
            // Command-F goes to the field. The field is the visible control; this only carries the
            // key, which an app with no Find menu would otherwise not answer.
            .background {
                Button("Search") { focused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
    }
}
