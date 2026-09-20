import XiaolaiDictCore
import Testing

@testable import XiaolaiDict

/// **The pause reaches the gate from the menu it is offered in.**
///
/// This is the assertion that was missing, and its absence is the whole defect. `HoverPause` was
/// specified, modelled, given three lengths and a menu label; `HoverPolicy.decide` refused
/// correctly when handed a `pausedUntil`; `HoverPolicyTests` covered both. All of it passed while
/// nothing in the app held a `HoverPause` at all — `HoverReader`'s default built a fresh one on
/// every call, `HoverWatcher` never forwarded the parameter, and no menu item ever set it. The
/// model was complete and connected to nothing.
///
/// So these tests deliberately do not test the model. They test the wire.
@MainActor struct HoverPauseWiringTests {
    /// A reader who pauses XiaolaiDict from the menu is not looked up for, through the app's own watcher
    /// rather than one the test assembled to suit itself.
    @Test func pausingTheAppSilencesItsOwnWatcher() async {
        let app = XiaolaiDictApp()
        // **The watcher is built first, on purpose.** If the pause were captured by value when
        // the watcher is made, this ordering is what exposes it: the pause arrives afterwards and
        // must still be seen. Pausing first would pass either way.
        let watcher = app.hover
        app.pauseHover(for: .seconds(900))

        let outcome = await watcher.reader.read(
            at: .zero, modifiersHeld: [HoverPolicy.shipped.modifier], pointerStillFor: .seconds(10))
        guard case .quiet(.paused) = outcome else {
            Issue.record("the app answered \(outcome) while paused — the menu is not wired to the gate")
            return
        }
    }

    /// And resuming takes it back, so the pause cannot strand a reader with a XiaolaiDict that has
    /// quietly stopped working.
    @Test func resumingTakesItBack() {
        let app = XiaolaiDictApp()
        app.pauseHover(for: .seconds(900))
        #expect(app.hoverIsPaused)
        app.resumeHover()
        #expect(!app.hoverIsPaused)
    }

    /// A paused XiaolaiDict says so where the reader is looking. "Never *silently* paused" is the claim
    /// `HoverPause.label(at:)` was written to keep, and until now no surface read it.
    @Test func thePausedStateIsVisibleInTheMenu() {
        let app = XiaolaiDictApp()
        #expect(app.hoverPauseLabel == "Pause Hover…")
        app.pauseHover(for: .seconds(900))
        #expect(app.hoverPauseLabel.hasPrefix("Paused"), "the menu read \(app.hoverPauseLabel)")
    }
}
