import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import XiaolaiDictUI

/// **"Rendered" means AppKit drew it** (verify of the closing pass, #17). The acknowledgement came from
/// SwiftUI's `onChange`, which runs inside the update — before the drawing — and then from a main-queue
/// hop, which promises neither a new loop turn nor a display. It now comes from the marker's own
/// `draw(_:)`. **Measured here: in a layer-backed window that runs when the Core Animation transaction
/// commits** — `window.display()` alone did not draw it, `CATransaction.flush()` did — which is the moment
/// the window's new contents go to the window server. So the commit is what these tests drive.
@MainActor
struct RenderAcknowledgerTests {
    final class Acknowledged { var generations: [Int] = [] }

    private func window(showing generation: Int, into acknowledged: Acknowledged) -> (NSWindow, NSHostingView<RenderAcknowledger>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RenderAcknowledger(generation: generation) { acknowledged.generations.append($0) })
        host.frame = window.contentLayoutRect
        window.contentView = host
        return (window, host)
    }

    @Test func aGenerationIsAcknowledgedWhenTheWindowDisplaysIt() {
        let acknowledged = Acknowledged()
        let (window, host) = window(showing: 1, into: acknowledged)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(acknowledged.generations.isEmpty, "laid out is not drawn, and was acknowledged as drawn")
        CATransaction.flush()
        #expect(acknowledged.generations.last == 1, "the marker was committed and nothing was acknowledged")
    }

    /// The next showing is acknowledged only once **it** has been drawn, not on the strength of the last.
    @Test func aNewGenerationWaitsForItsOwnDisplay() {
        let acknowledged = Acknowledged()
        let (window, host) = window(showing: 1, into: acknowledged)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()
        host.rootView = RenderAcknowledger(generation: 2) { acknowledged.generations.append($0) }
        host.layoutSubtreeIfNeeded()
        #expect(acknowledged.generations.last == 1, "generation 2 was acknowledged before it was drawn")
        CATransaction.flush()
        #expect(acknowledged.generations.last == 2, "generation 2 was committed and not acknowledged")
    }
}
