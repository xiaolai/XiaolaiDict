import AppKit
import ApplicationServices
import Capture
import DictionaryModel
import Synchronization
import Testing
import XiaolaiDictCore
import XiaolaiDictTestSupport
@testable import XiaolaiDict

/// **The watcher, driven by event sequences.**
///
/// These replace six checks that read the watcher's source for spellings — `gestures.saw(`,
/// `event.timestamp`, `check(tappedTwice: true)` — which could not see event order and passed
/// while a chord between two presses completed a pair. Each test here drives the real watcher with
/// scripted events, a pointer, a hand-fired timer and a reader whose reads end on command.
@MainActor
struct HoverWatcherSequenceTests {
    @MainActor
    private final class Rig {
        let events = ScriptedHoverEvents()
        let pointer = ScriptedPointer()
        let timer = ManualSchedule()
        let reader = ScriptedHoverReader()
        let delivery = RecordingDelivery()
        let watcher: HoverWatcher

        init(gesture: HoverGesture = .hold) {
            var policy = HoverPolicy.shipped
            policy.gesture = gesture
            let screens = [ScreenMetrics(
                frame: UpRect(x: 0, y: 0, width: 2_000, height: 1_000),
                visibleFrame: UpRect(x: 0, y: 0, width: 2_000, height: 1_000))]
            let pointer = pointer, timer = timer
            let clock = DateBox()
            self.clock = clock
            watcher = HoverWatcher(
                policy: { policy }, screens: { screens },
                events: events, pointer: { pointer.read() },
                schedule: { timer.schedule($0, $1) }, date: { clock.now }, reader: reader)
            watcher.delivery = delivery
            watcher.start()
        }

        /// The pointer arrives with ⌥ down and the settle timer fires; waits for the read to start.
        func rest(at point: UpPoint = UpPoint(x: 100, y: 100)) async {
            let before = reader.asks.count
            pointer.at = point
            pointer.held = [.option]
            events.emit(.pointerMoved)
            timer.fire()
            await asks(before + 1)
        }

        func asks(_ count: Int) async {
            await HoverFixtures.settle { self.reader.asks.count >= count }
        }

        /// The wall clock the watcher reads, which the test moves.
        let clock: DateBox

        @MainActor
        final class DateBox {
            var now = Date(timeIntervalSince1970: 1_800_000_000)
        }

        /// Lets everything already started run, for an assertion that something did *not* happen.
        func drain() async { await HoverFixtures.drain() }
    }

    // MARK: - The gesture rule's wire

    /// **The watcher asks the gesture rule, with the reader's own gesture and key.** Under
    /// double-tap the third press is a request, asked at once; under hold the same presses are not
    /// a tap. Red if the watcher stops passing `.modifiers` events to the session.
    @Test func aDoubleTapIsAskedAtOnceUnderTheTapGestureOnly() async {
        let tapping = Rig(gesture: .doubleTap)
        tapping.events.doubleTap(from: 10)
        await tapping.asks(1)
        #expect(tapping.timer.armed > 0, "the settle timer was not what asked")
        #expect(tapping.reader.asks.map(\.tapped) == [true], "the tap was not served at once")

        let holding = Rig(gesture: .hold)
        holding.events.doubleTap(from: 10)
        await holding.drain()
        #expect(!holding.reader.asks.contains { $0.tapped }, "a tap under the hold gesture")
    }

    /// **The event's own time, not the clock's.** Three presses delivered back to back whose
    /// timestamps are a second apart are not a tap. Red if the watcher dates presses on arrival.
    @Test func theEventsOwnTimeDecidesTheTapWindow() async {
        let rig = Rig(gesture: .doubleTap)
        rig.events.emit(.modifiers([.option], at: 10, location: nil))
        rig.events.emit(.modifiers([], at: 10.5, location: nil))
        rig.events.emit(.modifiers([.option], at: 11.2, location: nil))
        await rig.drain()
        #expect(rig.reader.asks.isEmpty)
    }

    /// **The event's own flags, not the current ones.** The pointer source says nothing is held;
    /// the events say ⌥ went down, up, down — and that is a tap.
    @Test func theEventsOwnFlagsDecideThePress() async {
        let rig = Rig(gesture: .doubleTap)
        rig.pointer.held = []
        rig.events.doubleTap(from: 20)
        await rig.asks(1)
        #expect(rig.reader.asks.count == 1)
    }

    /// **Other input cancels a half-made pair.** ⌥←, ⌥← is two presses of ⌥ inside the window.
    @Test func otherInputBetweenPressesIsNotATap() async {
        let rig = Rig(gesture: .doubleTap)
        rig.events.emit(.modifiers([.option], at: 30, location: nil))
        rig.events.emit(.modifiers([], at: 30.05, location: nil))
        rig.events.emit(.otherInput)
        rig.events.emit(.modifiers([.option], at: 30.2, location: nil))
        await rig.drain()
        #expect(rig.reader.asks.isEmpty)
    }

    /// Keys, clicks and scrolls all reach the rule as other input, and are all watched.
    @Test func everyKindOfOtherInputIsWatchedAndMapped() {
        for (type, mask) in [(NSEvent.EventType.keyDown, NSEvent.EventTypeMask.keyDown),
                             (.leftMouseDown, .leftMouseDown), (.scrollWheel, .scrollWheel)] {
            #expect(SystemHoverEvents.event(type: type, flags: [], timestamp: 0) == .otherInput)
            #expect(SystemHoverEvents.watched.contains(mask), "\(type) is not watched")
        }
        #expect(SystemHoverEvents.event(type: .flagsChanged, flags: [.option, .capsLock], timestamp: 7)
                == .modifiers([.option], at: 7, location: nil))
    }

    /// **A tap is served at once, at the point it was made, and never again.** A tap that was
    /// stored and spent by a later read could be spent at a word the reader did not point at.
    @Test func aTapIsServedAtItsOwnPointAndNotSpentLater() async {
        let rig = Rig(gesture: .doubleTap)
        rig.pointer.at = UpPoint(x: 300, y: 900)
        rig.events.doubleTap(from: 40)
        await rig.asks(1)
        #expect(rig.reader.asks.first?.point == CGPoint(x: 300, y: 100))
        rig.reader.answer(.quiet(.samePlace))
        await HoverFixtures.settle { rig.reader.pendingReads == 0 }
        rig.pointer.at = UpPoint(x: 700, y: 500)
        rig.events.emit(.pointerMoved)
        rig.timer.fire()
        await rig.drain()
        rig.reader.answer(.quiet(.notTapped))
        await rig.drain()
        #expect(!rig.reader.asks.dropFirst().contains { $0.tapped }, "a tap was spent at another word")
    }

    /// **Stopping resets the rule.** A press before a stop and a press after a start are not a pair.
    @Test func stoppingResetsTheRule() async {
        let rig = Rig(gesture: .doubleTap)
        rig.events.emit(.modifiers([.option], at: 50, location: nil))
        rig.events.emit(.modifiers([], at: 50.05, location: nil))
        rig.watcher.stop()
        rig.watcher.start()
        rig.events.emit(.modifiers([.option], at: 50.1, location: nil))
        await rig.drain()
        #expect(rig.reader.asks.isEmpty)
    }

    /// A partial install leaves hover off rather than on with a gesture missing.
    @Test func aFailedInstallLeavesHoverOff() {
        let rig = Rig()
        rig.watcher.stop()
        rig.events.installs = false
        rig.watcher.start()
        #expect(!rig.watcher.isWatching)
    }

    // MARK: - The lifecycle (WI-2)

    /// **The race, end to end.** A hover is asked; while it reads, the reader presses the shortcut,
    /// which claims the panel; the hover's late word is not delivered and not remembered.
    @Test func aLateHoverDoesNotReplaceALookupMadeMeanwhile() async {
        let rig = Rig()
        await rig.rest()
        let shortcut = rig.delivery.requests.next()
        rig.reader.answerWord()
        await rig.drain()
        #expect(rig.delivery.delivered.isEmpty, "the late hover replaced the shortcut's lookup")
        #expect(rig.reader.remembered.isEmpty, "a word nobody was shown was remembered")
        #expect(rig.delivery.requests.isCurrent(shortcut))
    }

    /// **`requestedAt` is when the gesture was accepted**, not when the word arrived — the ledger's
    /// time of the lookup is the reader's ask. Red if delivery dates the request on arrival.
    @Test func aDeliveredWordIsDatedFromTheAsk() async {
        let rig = Rig()
        let asked = rig.clock.now
        await rig.rest()
        rig.clock.now = asked.addingTimeInterval(4)
        rig.reader.answerWord("tide")
        await HoverFixtures.settle { !rig.delivery.delivered.isEmpty }
        #expect(rig.delivery.delivered.first?.requestedAt == asked)
    }

    /// **The number is taken when the read is asked**, so a shortcut pressed before the read's task
    /// first runs is numbered after the hover, and wins. Red if the number is taken inside the task.
    @Test func aHoverAskedBeforeAShortcutIsNumberedBeforeIt() async {
        let rig = Rig()
        rig.pointer.held = [.option]
        rig.events.emit(.pointerMoved)
        rig.timer.fire()
        let shortcut = rig.delivery.requests.next()
        await rig.asks(1)
        #expect((rig.reader.asks.first?.request ?? .max) < shortcut, "the older hover was numbered after the shortcut")
    }

    /// **Letting go of the key ends the hover at once**, so a quick release and re-press can look
    /// the same word up again. Red if only a read observing the key up clears the suppression.
    @Test func releasingTheKeyEndsTheHover() {
        let rig = Rig()
        rig.events.emit(.modifiers([.option], at: 1, location: nil))
        #expect(rig.reader.hoversEnded == 0)
        rig.events.emit(.modifiers([], at: 1.1, location: nil))
        #expect(rig.reader.hoversEnded == 1)
    }

    /// **A notice for an abandoned read is not shown.** Hover stopped while the read was in flight;
    /// its refusal for Screen Recording comes back after. Red if `finish` notifies unconditionally.
    @Test func aNoticeForAnAbandonedReadIsNotShown() async {
        let rig = Rig()
        await rig.rest()
        rig.watcher.stop()
        rig.reader.answer(.needsScreenRecording(request: rig.reader.asks[0].request))
        await rig.drain()
        #expect(rig.delivery.screenRecordingNotices == 0)
    }

    /// The ordinary case still works: a word that stands is delivered and then remembered.
    @Test func aWordThatStandsIsDeliveredThenRemembered() async {
        let rig = Rig()
        await rig.rest()
        rig.reader.answerWord("tide")
        await HoverFixtures.settle { !rig.delivery.delivered.isEmpty }
        #expect(rig.delivery.delivered.map(\.text) == ["tide"])
        #expect(rig.reader.remembered.count == 1)
    }

    /// **A word whose panel never drew is forgotten** (audit round 3, #38). It was remembered on the
    /// claim, so a failed opening left the reader unable to ask for that word again by resting on it.
    @Test func aWordWhosePanelNeverDrewIsForgotten() async throws {
        let rig = Rig()
        await rig.rest()
        rig.reader.answerWord("tide")
        await HoverFixtures.settle { !rig.delivery.delivered.isEmpty }
        let seen = try #require(rig.delivery.seens.first)
        seen(false)
        #expect(rig.reader.forgotten == rig.reader.remembered, "a word nobody saw stayed remembered")
    }

    /// And one that drew stays remembered.
    @Test func aWordWhosePanelDrewStaysRemembered() async throws {
        let rig = Rig()
        await rig.rest()
        rig.reader.answerWord("tide")
        await HoverFixtures.settle { !rig.delivery.delivered.isEmpty }
        let seen = try #require(rig.delivery.seens.first)
        seen(true)
        #expect(rig.reader.forgotten.isEmpty)
    }

    /// **Leaving the word drops it**, and nothing is remembered, so coming back is a new request.
    @Test func aWordReadAfterThePointerLeftIsDropped() async {
        let rig = Rig()
        await rig.rest()
        rig.pointer.at = UpPoint(x: 400, y: 100)
        rig.events.emit(.pointerMoved)
        rig.reader.answerWord()
        await rig.drain()
        #expect(rig.delivery.delivered.isEmpty)
        #expect(rig.reader.remembered.isEmpty)
    }

    /// **A read refused for a busy capture is asked again when the capture finishes** — not when
    /// the pointer next twitches.
    @Test func aBlockedReadIsAskedAgainWhenTheCaptureFinishes() async {
        let rig = Rig()
        await rig.rest()
        rig.reader.answer(.quiet(.captureInFlight))
        await rig.drain()
        #expect(rig.reader.asks.count == 1)
        rig.reader.onCaptureReleased?()
        await rig.asks(2)
        #expect(rig.reader.asks.count == 2, "nothing asked again when the capture was released")
    }
}

/// The app's half of delivery: claiming, and leaving a newer lookup alone.
@MainActor
struct HoverDeliveryTests {
    /// **A refused claim cancels nothing.** The shortcut's lookup is the newer request, and the
    /// late hover must neither replace its panel nor cancel its task.
    @Test func aLateHoverLeavesTheNewerLookupRunning() {
        let suite = TemporaryDefaults.suite()
        let app = XiaolaiDictApp(defaults: suite, models: .temporary(defaults: suite))
        let hover = app.beginRequest()
        app.lookUpWord("tide")
        let newer = app.lookup
        let claimed = app.deliver(HoverFixtures.selection("hold"), at: UpPoint(x: 1, y: 1), request: hover,
                                  requestedAt: .now, askedAt: .now, seen: { _ in })
        #expect(!claimed)
        #expect(app.lookup == newer, "the late hover replaced the newer lookup's task")
        #expect(newer?.isCancelled == false, "the late hover cancelled the newer lookup")
    }
}

/// The reader's half: what it reads, given a screen.
@MainActor
struct HoverReaderSourceTests {
    private func reader(_ screen: ScriptedScreenWords, scripts: Set<ProbeScript> = [.latin]) -> HoverReader {
        var policy = HoverPolicy.shipped
        policy.scripts = scripts
        return HoverReader(policy: { policy }, captureDeadline: HoverFixtures.patient, source: screen)
    }

    private func read(_ reader: HoverReader) async -> HoverReader.Outcome {
        await reader.read(at: CGPoint(x: 10, y: 10), modifiersHeld: [.option], tappedTwice: false,
                          pointerStillFor: .seconds(1), begin: { 7 })
    }

    /// **The hover path asks whether the script is studied** — by behaviour: a Han word read
    /// through Accessibility is refused for a Latin-only reader, and a Latin word is not.
    @Test func aWordInAScriptNotStudiedIsRefused() async {
        let screen = ScriptedScreenWords()
        screen.targetOutcome = .found(HoverFixtures.target())
        screen.readOutcome = HoverFixtures.hit("学习")
        guard case .quiet(.scriptNotStudied) = await read(reader(screen)) else {
            Issue.record("a word outside the studied scripts was not refused")
            return
        }
        screen.readOutcome = HoverFixtures.hit("tide")
        guard case .selection(let selection, let request, _) = await read(reader(screen)) else {
            Issue.record("a Latin word was refused")
            return
        }
        #expect(selection.text == "tide")
        #expect(request == 7, "the word did not carry the request it was read for")
    }

    /// **Remembered on delivery, not on reading.** Reading twice without delivering is two words;
    /// after `remember`, the same word at the same place is `.samePlace`.
    @Test func aWordIsSuppressedOnlyOnceRemembered() async {
        let screen = ScriptedScreenWords()
        screen.targetOutcome = .found(HoverFixtures.target())
        screen.readOutcome = HoverFixtures.hit("tide")
        let reader = reader(screen)
        guard case .selection(_, _, let key) = await read(reader) else {
            Issue.record("no word")
            return
        }
        guard case .selection = await read(reader) else {
            Issue.record("a word that was never delivered was suppressed")
            return
        }
        reader.remember(key)
        guard case .quiet(.samePlace) = await read(reader) else {
            Issue.record("a delivered word was not suppressed")
            return
        }
    }
}

/// The capture reads the window of the app Accessibility named.
@MainActor
struct HoverCaptureTargetTests {
    /// **Accessibility named TextEdit and read nothing; another app's window comes first at the
    /// point.** The capture reads TextEdit's window, not the first ordinary one. Red if the reader
    /// stops passing the owner to `PointerTarget`.
    @Test func theCaptureReadsTheNamedAppsWindow() async {
        let target = HoverFixtures.target()
        let named = ListedWindow(pid: target.pid, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 2)
        let other = ListedWindow(pid: target.pid + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 3)
        let screen = ScriptedScreenWords()
        screen.windows = [other, named]
        screen.targetOutcome = .found(target)
        screen.readOutcome = .miss("no text here")
        let reader = HoverReader(policy: { .shipped }, captureDeadline: HoverFixtures.patient, source: screen)
        _ = await reader.read(at: CGPoint(x: 10, y: 10), modifiersHeld: [.option], tappedTwice: false,
                              pointerStillFor: .seconds(1), begin: { 1 })
        #expect(screen.recognisedWindows == [named])
    }

    /// The named app has no window at the point: nothing is captured at all.
    @Test func noCaptureWhenTheNamedAppHasNoWindowThere() async {
        let target = HoverFixtures.target()
        let screen = ScriptedScreenWords()
        screen.windows = [ListedWindow(pid: target.pid + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 3)]
        screen.targetOutcome = .found(target)
        screen.readOutcome = .miss("no text here")
        let reader = HoverReader(policy: { .shipped }, captureDeadline: HoverFixtures.patient, source: screen)
        _ = await reader.read(at: CGPoint(x: 10, y: 10), modifiersHeld: [.option], tappedTwice: false,
                              pointerStillFor: .seconds(1), begin: { 1 })
        #expect(screen.recognitions == 0, "another app's window was captured")
    }
}

/// The real reader tells the watcher when its capture finishes.
@MainActor
struct HoverCaptureReleaseTests {
    /// **A finished capture is reported**, so a hover refused for the busy guard is asked again.
    /// The watcher's own test calls the callback by hand; this one proves the reader calls it. Red if
    /// `bounded` stops reporting the release.
    @Test func aFinishedCaptureIsReported() async {
        let screen = ScriptedScreenWords()
        screen.windows = [ListedWindow(pid: getpid() + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 4)]
        let reader = HoverReader(policy: { .shipped }, captureDeadline: HoverFixtures.patient, source: screen)
        var released = 0
        reader.onCaptureReleased = { released += 1 }
        _ = await reader.read(at: CGPoint(x: 10, y: 10), modifiersHeld: [.option], tappedTwice: false,
                              pointerStillFor: .seconds(1), begin: { 1 })
        #expect(screen.recognitions == 1)
        await HoverFixtures.settle { released > 0 }
        #expect(released == 1, "the capture finished and nobody was told")
    }
}

/// **A capture that never returns says so** (WI-5).
@MainActor
struct CaptureWedgeTests {
    /// A clock the test moves.
    private final class Clock: Sendable {
        private let offset = Mutex(Duration.zero)
        let origin = ContinuousClock.now
        func now() -> ContinuousClock.Instant { origin + offset.withLock { $0 } }
        func advance(_ by: Duration) { offset.withLock { $0 += by } }
    }

    /// The first hover's capture hangs and its read gives up at the deadline. The next hover, past
    /// the deadline, is told the capture is stuck — not refused quietly as one more capture in
    /// flight — and the reader is told once. When the capture finally returns, it answers again.
    /// Red if the gate's `.captureInFlight` is returned without asking whether it is overdue.
    @Test func aWedgedCaptureIsReportedOnceAndClearedOnRelease() async throws {
        let clock = Clock()
        let screen = ScriptedScreenWords()
        screen.windows = [ListedWindow(pid: getpid() + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 5)]
        screen.hangs = true
        let reader = HoverReader(
            policy: { .shipped }, captureDeadline: .milliseconds(20), source: screen,
            capturing: HoverReader.CaptureGuard(now: { clock.now() }))
        var health: [CaptureHealth] = []
        reader.onCaptureHealth = { health.append($0) }
        func read() async -> HoverReader.Outcome {
            await reader.read(at: CGPoint(x: 10, y: 10), modifiersHeld: [.option], tappedTwice: false,
                              pointerStillFor: .seconds(1), begin: { 1 })
        }

        // The read gives up at its deadline with the capture still held: stuck **now**, not when a
        // later hover happens to ask — which may be never.
        guard case .nothing = await read() else {
            Issue.record("a capture past its deadline was not given up on")
            return
        }
        #expect(health == [.stuck(for: .milliseconds(20))], "the wedge was not reported at the deadline")
        // Later hovers are still refused as a capture in flight — so they are asked again on release —
        // and the wedge is not reported a second time.
        clock.advance(.seconds(30))
        guard case .quiet(.captureInFlight) = await read() else {
            Issue.record("a hover during a wedge lost its retry on release")
            return
        }
        _ = await read()
        #expect(health.count == 1, "the wedge was reported \(health.count) times")

        // **Waits for the report**, sent from the capture's own task, which a busy run schedules
        // whenever it likes — patiently, and bounded, so a regression fails instead of hanging.
        screen.finishCapture()
        await HoverFixtures.settle { health.count == 2 }
        #expect(health.last == .answering, "the capture answered and nobody was told")
    }
}

/// The reader names the site before it reads (WI-7).
@MainActor
struct HoverSiteTests {
    private func reader(_ screen: ScriptedScreenWords, sites: Set<String>) -> HoverReader {
        var policy = HoverPolicy.shipped
        policy.excludedHosts = sites
        return HoverReader(policy: { policy }, captureDeadline: HoverFixtures.patient, source: screen)
    }

    private func read(_ reader: HoverReader) async -> HoverReader.Outcome {
        await reader.read(at: CGPoint(x: 10, y: 10), modifiersHeld: [.option], tappedTwice: false,
                          pointerStillFor: .seconds(1), begin: { 1 })
    }

    /// **An excluded site is refused before its text is read.** The scripted page would answer a
    /// word; the refusal comes first. Red if the host is never asked, or asked after the read.
    @Test func anExcludedSiteIsRefusedBeforeItsTextIsRead() async {
        let screen = ScriptedScreenWords()
        screen.targetOutcome = .found(HoverFixtures.target(bundleID: "com.apple.Safari"))
        screen.readOutcome = HoverFixtures.hit("secret")
        screen.hostReading = .known("bank.example.com")
        guard case .quiet(.excludedSite) = await read(reader(screen, sites: ["example.com"])) else {
            Issue.record("an excluded site was read")
            return
        }
    }

    /// With no element to ask there is no page to name, and the capture is refused rather than
    /// taken — while the list has a site in it.
    @Test func withoutAnElementThePixelsAreNotReadWhileSitesAreExcluded() async {
        let screen = ScriptedScreenWords()
        screen.windows = [ListedWindow(pid: getpid() + 1, bounds: CGRect(x: 0, y: 0, width: 500, height: 500), windowID: 6)]
        guard case .quiet(.excludedSite) = await read(reader(screen, sites: ["example.com"])) else {
            Issue.record("an unnamed page was captured")
            return
        }
        #expect(screen.recognitions == 0)
    }

    /// **A reader who excluded nothing pays nothing**: the host is never asked.
    @Test func noSiteListNoHostQuestion() async {
        let screen = ScriptedScreenWords()
        screen.targetOutcome = .found(HoverFixtures.target())
        screen.readOutcome = HoverFixtures.hit("tide")
        _ = await read(reader(screen, sites: []))
        #expect(screen.hostsAsked == 0)
    }
}

/// The host is read from the page's own address.
struct ScreenWordHostTests {
    /// Answers a scripted tree: the element is a web area whose address is `url`.
    /// The element is a web area, or a text area whose parent is the application — or, where
    /// `reachesApp` is false, whose parent could not be read.
    private struct Page: AccessibilityReading {
        let url: CFTypeRef?
        let isPage: Bool
        var reachesApp = true
        static var application: AXUIElement { AXUIElementCreateApplication(70_002) }
        func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
            let isApplication = CFEqual(element, Self.application)
            switch name {
            case kAXRoleAttribute: return (isApplication ? kAXApplicationRole : isPage ? "AXWebArea" : "AXTextArea") as CFString
            case kAXURLAttribute: return url
            case kAXParentAttribute: return isApplication || !reachesApp ? nil : Self.application
            default: return nil
            }
        }
        func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? { nil }
    }

    /// **A walk that stops short of the application is not "no page"** — a parent that could not be
    /// read is taken as unreadable, so an excluded site is not let through. Red if a missing parent
    /// ends the walk as `.notWebContent`.
    @Test func aWalkThatStopsShortIsUnreadable() {
        #expect(ScreenWordReader.host(of: Self.target, with: Page(url: nil, isPage: false, reachesApp: false)) == .unreadable)
    }

    /// A Unicode host is reported in the IDNA form exclusions are stored in.
    @Test func aUnicodeHostIsReportedInItsIDNAForm() {
        let page = Page(url: URL(string: "https://bücher.de/x")! as CFURL, isPage: true)
        #expect(ScreenWordReader.host(of: Self.target, with: page) == .known("xn--bcher-kva.de"))
    }

    private static let target = HoverFixtures.target()

    @Test func aPagesHostIsKnown() {
        let page = Page(url: URL(string: "https://docs.example.com/a")! as CFURL, isPage: true)
        #expect(ScreenWordReader.host(of: Self.target, with: page) == .known("docs.example.com"))
    }

    @Test func noPageIsNotWebContent() {
        #expect(ScreenWordReader.host(of: Self.target, with: Page(url: nil, isPage: false)) == .notWebContent)
    }

    /// A page whose address is missing is not assumed to be harmless.
    @Test func aPageWithNoAddressIsUnreadable() {
        #expect(ScreenWordReader.host(of: Self.target, with: Page(url: nil, isPage: true)) == .unreadable)
    }

    @Test func aLocalFileIsNotASite() {
        let page = Page(url: URL(fileURLWithPath: "/tmp/a.html") as CFURL, isPage: true)
        #expect(ScreenWordReader.host(of: Self.target, with: page) == .notWebContent)
    }
}


/// **The wire to Settings** (WI-5): a stuck capture reported by the watcher reaches the observed
/// state Settings reads. Red if `HoverControl` stops listening.
@MainActor
struct CaptureHealthWiringTests {
    @Test func aStuckCaptureReachesTheObservedState() {
        let control = HoverControl(defaults: TemporaryDefaults.suite())
        #expect(!control.isCaptureStuck)
        control.watcher.onCaptureHealth?(.stuck(for: .seconds(9)))
        #expect(control.isCaptureStuck)
        control.watcher.onCaptureHealth?(.answering)
        #expect(!control.isCaptureStuck)
    }
}

/// Findings from the second audit-fix round, at the watcher.
@MainActor
struct HoverWatcherRoundTwoTests {
    @MainActor
    private final class Rig {
        let events = ScriptedHoverEvents()
        let pointer = ScriptedPointer()
        let timer = ManualSchedule()
        let reader = ScriptedHoverReader()
        let delivery = RecordingDelivery()
        let watcher: HoverWatcher

        init() {
            let screens = [ScreenMetrics(
                frame: UpRect(x: 0, y: 0, width: 2_000, height: 1_000),
                visibleFrame: UpRect(x: 0, y: 0, width: 2_000, height: 1_000))]
            let pointer = pointer, timer = timer
            watcher = HoverWatcher(policy: { .shipped }, screens: { screens }, events: events,
                                   pointer: { pointer.read() }, schedule: { timer.schedule($0, $1) }, reader: reader)
            watcher.delivery = delivery
            watcher.start()
        }

        func rest() async {
            let before = reader.asks.count
            pointer.at = UpPoint(x: 100, y: 100)
            pointer.held = [.option]
            events.emit(.pointerMoved)
            timer.fire()
            await HoverFixtures.settle { self.reader.asks.count > before }
        }
    }

    /// **A read asked again after a busy capture keeps its first number.** Red if the re-ask takes
    /// a fresh one, which would let it claim the panel over a lookup made in between.
    @Test func aReAskKeepsItsNumber() async {
        let rig = Rig()
        await rig.rest()
        rig.reader.answer(.quiet(.captureInFlight))
        await HoverFixtures.drain()
        rig.reader.onCaptureReleased?()
        await HoverFixtures.settle { rig.reader.asks.count == 2 }
        #expect(rig.reader.asks.map(\.request) == [1, 1], "the re-ask was numbered \(rig.reader.asks.map(\.request))")
    }

    /// **Stopping ends the hover**, so a key let go while stopped does not leave the word suppressed.
    @Test func stoppingEndsTheHover() {
        let rig = Rig()
        rig.watcher.stop()
        #expect(rig.reader.hoversEnded >= 1)
    }

    /// **A notice for a hover that no longer stands is not shown** — the pointer moved off before
    /// the read came back. Red if `finish` checks only cancellation.
    @Test func aNoticeForAHoverThatNoLongerStandsIsNotShown() async {
        let rig = Rig()
        await rig.rest()
        rig.pointer.at = UpPoint(x: 600, y: 100)
        rig.reader.answer(.needsScreenRecording(request: rig.reader.asks[0].request))
        await HoverFixtures.drain()
        #expect(rig.delivery.screenRecordingNotices == 0)
    }
}
