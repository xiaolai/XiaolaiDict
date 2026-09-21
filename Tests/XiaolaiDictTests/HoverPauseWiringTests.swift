import Foundation
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
    /// Its own preferences suite, so no test can read or write the reader's real settings.
    private func app() -> XiaolaiDictApp {
        XiaolaiDictApp(defaults: UserDefaults(suiteName: "xiaolaidict.app.test.\(UUID().uuidString)")!)
    }

    /// A reader who pauses XiaolaiDict from the menu is not looked up for, through the app's own watcher
    /// rather than one the test assembled to suit itself.
    @Test func pausingTheAppSilencesItsOwnWatcher() async {
        let app = app()
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
        let app = app()
        app.pauseHover(for: .seconds(900))
        #expect(app.hoverIsPaused)
        app.resumeHover()
        #expect(!app.hoverIsPaused)
    }

    /// A paused XiaolaiDict says so where the reader is looking. "Never *silently* paused" is the claim
    /// `HoverPause.label(at:)` was written to keep, and until now no surface read it.
    @Test func thePausedStateIsVisibleInTheMenu() {
        let app = app()
        #expect(app.hoverPauseLabel == "Pause Hover…")
        app.pauseHover(for: .seconds(900))
        #expect(app.hoverPauseLabel.hasPrefix("Paused"), "the menu read \(app.hoverPauseLabel)")
    }

    /// **And the policy, by the same argument as the pause.** `HoverPolicy` was taken as a closure
    /// from the start and the only value that ever reached it was the hardcoded `.shipped`, so the
    /// reader's modifier and settle time were settings in type only.
    ///
    /// Shift is held and the pointer has not rested. Both of those matter: under the reader's
    /// policy this refuses because the pointer is still moving, and under the shipped one it would
    /// refuse because Option is not held. Distinguishing the two is the assertion — and choosing a
    /// case that refuses either way keeps a failure from walking into a real screen capture.
    @Test func theReadersOwnPolicyIsTheOneTheGateUses() async {
        let app = app()
        let watcher = app.hover
        var chosen = HoverPolicy.shipped
        chosen.modifier = .shift
        chosen.settleMilliseconds = 5_000
        app.setHoverPolicy(chosen)

        let outcome = await watcher.reader.read(
            at: .zero, modifiersHeld: [.shift], pointerStillFor: .zero)
        guard case .quiet(.stillMoving) = outcome else {
            Issue.record("the gate answered \(outcome) — it is still using the shipped policy")
            return
        }
    }

    /// What the reader chooses is still there next launch, through the app rather than the store.
    @Test func theChosenPolicySurvivesALaunch() {
        let suite = UserDefaults(suiteName: "xiaolaidict.app.test.\(UUID().uuidString)")!
        var chosen = HoverPolicy.shipped
        chosen.modifier = .command
        XiaolaiDictApp(defaults: suite).setHoverPolicy(chosen)
        #expect(XiaolaiDictApp(defaults: suite).hoverPolicy.modifier == .command)
    }

    /// **Built the way the app actually builds it**, which is not the way a test does.
    ///
    /// `@NSApplicationDelegateAdaptor` instantiates the delegate through the Objective-C runtime.
    /// That path looks for `init` and finds `NSObject`'s, so a Swift designated initializer with a
    /// default argument for every parameter does not serve — it suppresses the inherited `init()`
    /// instead. Adding `init(defaults:)` did exactly that and every launch trapped with "Use of
    /// unimplemented initializer" while all 710 unit tests passed, because every one of them
    /// called the initializer Swift could see. Only `e2e.sh` noticed, at stage 1.
    ///
    /// This costs milliseconds and catches it before a bundle is ever built.
    @Test func theDelegateCanBeBuiltTheWayTheAdaptorBuildsIt() {
        let built = (XiaolaiDictApp.self as NSObject.Type).init()
        #expect(built is XiaolaiDictApp, "the adaptor's initialiser did not produce a XiaolaiDictApp")
    }
}
