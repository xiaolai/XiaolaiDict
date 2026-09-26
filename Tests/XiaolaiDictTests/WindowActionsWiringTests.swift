import AppKit
import Foundation
import Testing
import XiaolaiDictCore
import XiaolaiDictTestSupport

@testable import XiaolaiDict

/// **A lookup must never be recorded for a panel that was never drawn.**
///
/// `WindowActions.shared` is a global whose three actions are nil until `MenuBarLabel`'s `.task`
/// runs, which is after `applicationDidFinishLaunching`. The app already knew —
/// `openSetupOnFirstLaunch` waits five seconds for it — but the hot key was registered and hover
/// started *at* launch, before it. A shortcut pressed in that window made `LookupPanel.show` a
/// silent no-op while `isCurrent(ticket)` went on answering true, so `LookupRunner` ran the whole
/// lookup, resolved a sense and returned a row to write. That breaks "a lookup nobody saw is not
/// recorded" by exactly the mechanism `WindowActions`' own doc comment describes for the drawer.
///
/// These assert the **wire** and not the values — the lesson `AGENTS.md` records twice, from
/// `HoverPause` and again from `LookupRunner.priorEncounters`: a model can be complete, unit-tested
/// and unreachable, and only a test of what actually reached the surface can tell.
@MainActor
struct WindowActionsWiringTests {
    private static let selection = Selection(
        text: "fine", sentence: "He paid the fine.", rangeInSentence: NSRange(location: 12, length: 4),
        quality: .accessibility(.accessibilityTextRange, context: .complete),
        place: ReadingPlace(bundleID: "com.apple.Preview", name: "Preview"))

    /// **The check that matters: nothing happens, rather than happening invisibly.**
    ///
    /// With the panel unable to draw, the runner must answer nil — no ledger row — and must not have
    /// filled a panel that does not exist.
    @Test func aPanelThatCannotOpenRecordsNothing() async {
        let panel = RecordingPanel()
        panel.canShow = false
        let runner = LookupRunner(
            client: DictionaryClient(
                deadline: .milliseconds(50), connect: { _ in NeverReplies() }, fallback: { _ in nil }),
            panel: panel)

        let row = await runner.run(
            Self.selection, near: .zero, requestedAt: .now, ticket: panel.newRequest())

        #expect(row == nil, "a lookup the reader never saw was returned for recording")
        #expect(panel.contents.isEmpty, "a panel that refused to open recorded content anyway")
        #expect(panel.updates.isEmpty, "a panel that never opened was filled in")
    }

    /// The control, so the check above cannot pass by the runner being broken for every input.
    @Test func aPanelThatOpensStillRecords() async {
        let panel = RecordingPanel()
        let runner = LookupRunner(
            client: DictionaryClient(
                deadline: .milliseconds(50), connect: { _ in NeverReplies() }, fallback: { _ in nil }),
            panel: panel)

        let row = await runner.run(
            Self.selection, near: .zero, requestedAt: .now, ticket: panel.newRequest())

        #expect(row != nil, "a lookup the reader saw was not recorded")
        #expect(panel.contents.count == 1)
    }

    /// **An unwired action is loud and answers `false`.** The five call sites optional-chained it,
    /// so a nil action was indistinguishable from a window that opened.
    @Test func anUnwiredActionRefusesRatherThanDoingNothingQuietly() {
        let actions = WindowActions()
        #expect(!actions.areWired)
        #expect(!actions.openWindow(id: "lookup"))
        #expect(!actions.dismissWindow(id: "lookup"))
        #expect(!actions.openSettings())
    }

    /// **A capture must not take the key back from a reader who is recording a new one.**
    ///
    /// `suspendShortcut(true)` sets `hotkey` to nil so the combination reaches the field, and
    /// `registerShortcut` puts it back unconditionally — so arming from a late capture would undo
    /// it. The two states look identical from `hotkey == nil` and mean opposite things, which is
    /// why `shortcutIsSuspended` is recorded rather than inferred.
    @Test func aLateCaptureDoesNotUndoAnArmedRecorder() {
        let suite = TemporaryDefaults.suite()
        let backend = FakeBackend()
        let app = XiaolaiDictApp(
            defaults: suite, hotkeys: HotkeyCenter(backend: backend),
            models: .temporary(defaults: suite))

        app.armTriggers(because: "launch")
        #expect(app.shortcuts.isRegistered)

        app.shortcuts.suspend(true)
        #expect(!app.shortcuts.isRegistered, "the recorder cannot receive keys while a hot key holds them")
        let registeredSoFar = backend.registered.count
        app.armTriggers(because: "a capture arrived while the reader was recording")
        #expect(!app.shortcuts.isRegistered, "arming took the combination back from the field")
        #expect(backend.registered.count == registeredSoFar)

        app.shortcuts.suspend(false)
        #expect(app.shortcuts.isRegistered, "the hot key was not put back when the recorder disarmed")
    }

    /// Arming twice is arming once — `.task` is tied to a view's lifetime, not to any documented
    /// ordering against the app delegate, so a second capture has to be harmless.
    @Test func armingTwiceRegistersOnce() {
        let suite = TemporaryDefaults.suite()
        let backend = FakeBackend()
        let app = XiaolaiDictApp(
            defaults: suite, hotkeys: HotkeyCenter(backend: backend),
            models: .temporary(defaults: suite))

        app.armTriggers(because: "first")
        let after = backend.registered.count
        app.armTriggers(because: "second")
        #expect(backend.registered.count == after, "a second capture registered the hot key again")
    }

    /// **Nothing is armed before the actions arrive.** The property this whole change exists for:
    /// a delegate that has launched but whose menu-bar label has not rendered holds no hot key.
    @Test func launchingAloneArmsNothing() {
        let suite = TemporaryDefaults.suite()
        let app = XiaolaiDictApp(
            defaults: suite, hotkeys: HotkeyCenter(backend: FakeBackend()),
            models: .temporary(defaults: suite))
        #expect(!app.shortcuts.isRegistered, "the hot key was registered before there was a panel to draw into")
        #expect(!app.hoverIsWatching, "hover was started before there was a panel to draw into")
    }
}
