import AppKit
import SwiftUI

/// The window a view is in, for code that has to name it: the shortcut capture, which listens to
/// that window and ends when it closes, and the settings window's fit, which resizes it.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> Reporter { Reporter(found: found) }
    func updateNSView(_ view: Reporter, context: Context) { view.found = found }

    final class Reporter: NSView {
        var found: (NSWindow?) -> Void

        init(found: @escaping (NSWindow?) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        /// Told when it arrives in a window rather than asked on the next turn of the runloop,
        /// which is the guess this replaces.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found(window)
        }
    }
}
