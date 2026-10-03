import AppKit
import SwiftUI

/// Says which showing the window has **drawn** — from AppKit's display pass, the only evidence an app
/// has of its own drawing.
///
/// A reused panel is listed by the compositor before the next card is drawn on it, so "the window is
/// on screen" credited one lookup with another's card (audit round 3, #17). SwiftUI's `onChange` runs
/// inside the update, before any drawing, and a main-queue hop promises neither a new loop turn nor a
/// display — both were tried and refuted. A view's `draw(_:)` is called only when its window draws it —
/// in a layer-backed window, when the Core Animation transaction commits and the new contents go to the
/// window server (measured: `window.display()` alone did not call it, the commit did). This one is marked
/// dirty whenever its generation changes, so the generation it acknowledges is one that was drawn.
///
/// One point, transparent, not hit-testable, not in the accessibility tree: it draws nothing a reader
/// can see and exists only to be drawn.
public struct RenderAcknowledger: NSViewRepresentable {
    public let generation: Int
    public let acknowledge: @MainActor (Int) -> Void

    public init(generation: Int, acknowledge: @escaping @MainActor (Int) -> Void) {
        self.generation = generation
        self.acknowledge = acknowledge
    }

    public final class Marker: NSView {
        var generation = 0
        var acknowledge: (@MainActor (Int) -> Void)?

        override public var isOpaque: Bool { false }
        override public func hitTest(_ point: NSPoint) -> NSView? { nil }
        override public func draw(_ dirtyRect: NSRect) { acknowledge?(generation) }
    }

    public func makeNSView(context: Context) -> Marker {
        let marker = Marker()
        marker.setAccessibilityElement(false)
        return marker
    }

    public func updateNSView(_ marker: Marker, context: Context) {
        marker.acknowledge = acknowledge
        guard marker.generation != generation else { return }
        marker.generation = generation
        marker.needsDisplay = true
    }

    /// Its own size, so a container cannot collapse it to nothing — a view with no area is never drawn.
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: Marker, context: Context) -> CGSize? {
        CGSize(width: 1, height: 1)
    }
}
