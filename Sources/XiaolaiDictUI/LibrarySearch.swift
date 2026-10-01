import SwiftUI

/// Search stays compact until the reader asks for it, in either collection pane.
struct LibrarySearch: ViewModifier {
    @Binding var text: String
    var layout: LibraryLayout = .grid
    var chooseLayout: @MainActor (LibraryLayout) -> Void = { _ in }
    @State private var expanded = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack {
                    ForEach(LibraryLayout.allCases, id: \.self) { mode in
                        Toggle(isOn: Binding(get: { layout == mode }, set: { if $0 { chooseLayout(mode) } })) {
                            Label(mode.name, systemImage: mode.symbol)
                        }
                        .toggleStyle(.button)
                        .accessibilityIdentifier("library-layout-\(mode.rawValue)")
                    }
                    Button {
                        expanded = true
                        focused = true
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Search")
                    if expanded || !text.isEmpty {
                        TextField("Search", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: Token.Library.searchWidth)
                            .focused($focused)
                            .onAppear { focused = true }
                            .onExitCommand { close() }
                        Button(action: close) {
                            Label("Close search", systemImage: "xmark")
                        }
                        .labelStyle(.iconOnly)
                        .help("Close search")
                    }
                }
            }
        }
    }

    private func close() {
        text = ""
        focused = false
        expanded = false
    }
}
