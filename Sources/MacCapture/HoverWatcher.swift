import AppKit
import Capture
import CaptureModel
import XiaolaiDictBase
import os

/// Where hover's events come from — **the seam that lets the watcher be driven by a test.**
///
/// The watcher used to install `NSEvent` monitors itself and read `NSEvent.mouseLocation` and the
/// clock inline, so the only checks possible on it were greps of its source — which cannot see
/// event order. Behind this a test hands it a sequence and watches what it asks.
@MainActor
protocol HoverEventSource: AnyObject {
    /// Starts delivering events. **False if any monitor could not be installed**, and then none is
    /// left installed: one surviving token would make hover report itself on with a gesture missing.
    func start(_ handler: @escaping @MainActor (HoverEvent) -> Void) -> Bool
    func stop()
}

/// What the watcher hands a word to, and where a request's number comes from — the app, which owns
/// the panel.
@MainActor
public protocol HoverDelivering: AnyObject {
    /// A number for a request that will claim the panel later. See `RequestSequence`.
    func beginRequest() -> Int
    /// Claims the panel for `request` and looks the word up. **False when the claim was refused** —
    /// a later request has the panel, or it was closed — and then nothing was shown.
    /// `requestedAt` is when the reader asked, for the ledger; `askedAt` is the same moment on the
    /// monotonic clock, for timings — a wall-clock date changes under a clock adjustment.
    /// `seen` is told once whether the compositor ever drew the panel — **true only then**. A claim
    /// granted is not a word shown, and a word remembered on the claim alone was never offered again.
    func deliver(_ selection: Selection, at pointer: UpPoint, request: Int, requestedAt: Date,
                 askedAt: ContinuousClock.Instant, seen: @escaping @MainActor (Bool) -> Void) -> Bool
    /// A hover needed the pixels and Screen Recording is off. Hover never asks the system; this
    /// tells the reader where to grant it — **once per launch**, and answers whether it told them.
    @discardableResult
    func screenRecordingNeeded(at pointer: UpPoint, request: Int) -> Bool
}

/// Watches the pointer and asks `HoverReader` once the reader has rested somewhere with the
/// modifier held, or tapped it twice.
///
/// **A shell around `HoverSession`**, which holds every decision about a request's lifecycle: when
/// to ask, whether a result still stands, what is owed when a read ends. This file turns AppKit
/// events into the session's inputs and the session's effects into timers, reads and deliveries,
/// and decides nothing itself — which is what makes the lifecycle testable by event sequence.
///
/// Whether to read at all is still `HoverPolicy.decide`, asked inside `HoverReader` and in cost
/// order, so a reader who is simply reading pays a set comparison and a clock read rather than an
/// Accessibility round trip.
@MainActor
public final class HoverWatcher {
    /// Cancels a scheduled piece of work.
    typealias Cancel = @MainActor () -> Void
    /// Runs `work` after `delay`, on the main actor, and returns how to cancel it.
    typealias Schedule = @MainActor (Duration, @escaping @MainActor () -> Void) -> Cancel

    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "hover")
    /// Not private, so a test can ask the reader what it decided. The watcher's job is to hand the
    /// reader the gate's inputs, and "it was handed them" is exactly what went untested while the
    /// pause was dropped on the floor.
    let reader: any HoverReading
    private let policy: @MainActor () -> HoverPolicy
    private let screens: () -> [ScreenMetrics]
    private let events: any HoverEventSource
    private let pointer: @MainActor () -> (UpPoint, Set<HoverModifier>)
    private let schedule: Schedule
    private let now: @MainActor () -> ContinuousClock.Instant
    private let date: @MainActor () -> Date

    private var session: HoverSession
    private var watching = false
    private var cancelSettle: Cancel?
    private var readTask: Task<Void, Never>?
    /// What a read found, kept until the session says whether to deliver it.
    private var found: [Int: (selection: Selection, request: Int, key: String)] = [:]
    /// Each request's panel number and when it was asked — **by origin**, so a tap served after the
    /// read it waited for, or a rest asked again once a capture freed, keeps the number and the time
    /// of the gesture that asked. Re-numbered, an older gesture could claim the panel over a lookup
    /// the reader made in between; re-dated, the ledger would record the wrong moment.
    private var origins: [Int: (request: Int, date: Date, instant: ContinuousClock.Instant)] = [:]
    /// How many origins are remembered; more than one or two are never live at once.
    private static let rememberedOrigins = 16
    /// Inputs that arrived while effects were being carried out, handled in arrival order.
    private var queued: [HoverSession.Input] = []
    private var handling = false

    /// Where a delivered word goes. Weak: the app owns the watcher through `HoverControl`.
    public weak var delivery: (any HoverDelivering)?
    /// Whether reading the screen is answering — forwarded from the reader for `HoverControl`.
    public var onCaptureHealth: (@MainActor (CaptureHealth) -> Void)?

    init(
        policy: @escaping @MainActor () -> HoverPolicy = { .shipped },
        pause: @escaping @MainActor () -> HoverPause = { HoverPause() },
        screens: @escaping () -> [ScreenMetrics] = { NSScreen.screens.map(ScreenMetrics.init) },
        events: any HoverEventSource = SystemHoverEvents(),
        pointer: @escaping @MainActor () -> (UpPoint, Set<HoverModifier>) = HoverWatcher.systemPointer,
        schedule: @escaping Schedule = HoverWatcher.onMainQueue,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        date: @escaping @MainActor () -> Date = { .now },
        reader: (any HoverReading)? = nil
    ) {
        self.policy = policy
        self.screens = screens
        self.events = events
        self.pointer = pointer
        self.schedule = schedule
        self.now = now
        self.date = date
        // **Forwarded, not defaulted.** This built `HoverReader(policy:)` and left the reader's
        // pause on its own default — `{ HoverPause() }`, a fresh never-paused value per call — so
        // `.paused` could not fire however long the reader paused for.
        self.reader = reader ?? HoverReader(
            policy: policy, pause: pause, captureDeadline: HoverReader.captureDeadline,
            accessibilityBudget: ScreenWordReader.budget)
        session = HoverSession(now: now())
        self.reader.onCaptureHealth = { [weak self] health in self?.onCaptureHealth?(health) }
        self.reader.onCaptureReleased = { [weak self] in
            guard let self else { return }
            let (at, held) = self.pointer()
            self.feed(.captureReleased(at, held: held))
        }
    }

    /// **The watcher the app runs**: the system's events, pointer, screens, timer and clocks, and a reader on the same
    /// policy and pause. The one public initialiser — every seam above is for the tests that drive this by event
    /// sequence, and stays internal. `events` is named only so this does not resolve to itself.
    public convenience init(policy: @escaping @MainActor () -> HoverPolicy, pause: @escaping @MainActor () -> HoverPause) {
        self.init(policy: policy, pause: pause, events: SystemHoverEvents())
    }

    public var isWatching: Bool { watching }

    public func start() {
        guard !watching else { return }
        guard events.start({ [weak self] event in self?.handle(event) }) else {
            log.error("hover: could not watch the pointer and keys")
            return
        }
        watching = true
        feed(.start)
    }

    public func stop() {
        events.stop()
        watching = false
        // A key let go while stopped is never seen, so the suppression it would have lifted is
        // lifted here: the hover is over either way.
        reader.endHover()
        // **The session's state does not outlive the watching.** Left set, a modifier released
        // while stopped makes the first press after a restart invisible, and a half-finished pair
        // from minutes ago can complete against an unrelated press.
        feed(.stop)
    }

    private func handle(_ event: HoverEvent) {
        switch event {
        case .pointerMoved:
            let (at, held) = pointer()
            feed(.pointer(at, held: held))
        case .modifiers(let held, let instant, let location):
            // **From the event, not from current state.** Global monitors deliver asynchronously,
            // so `NSEvent.modifierFlags`, a clock read and the pointer's position describe when this
            // process looked, not when the reader pressed.
            let at = location ?? pointer().0
            // **Letting go of the hold key ends the hover, and with it the suppression** — said to
            // the reader directly. Left to a read observing the key up, a release and re-press inside
            // the rest interval cancelled that read, and the same word stayed suppressed.
            if !held.contains(policy().modifier) { reader.endHover() }
            feed(.modifiers(held, at: instant, pointer: at))
            feed(.pointer(at, held: held))
        case .otherInput:
            feed(.otherInput)
        }
    }

    private func feed(_ input: HoverSession.Input) {
        queued.append(input)
        guard !handling else { return }
        handling = true
        defer { handling = false }
        while !queued.isEmpty {
            let next = queued.removeFirst()
            let policy = policy()
            let settings = HoverSession.Settings(gesture: policy.gesture, modifier: policy.modifier)
            for effect in session.handle(next, settings: settings, now: now()) { perform(effect) }
        }
    }

    private func perform(_ effect: HoverEffect) {
        switch effect {
        case .scheduleSettle:
            cancelSettle?()
            cancelSettle = schedule(.milliseconds(policy().settleMilliseconds)) { [weak self] in
                guard let self else { return }
                self.cancelSettle = nil
                let (at, held) = self.pointer()
                self.feed(.settled(at, held: held))
            }
        case .cancelSettle:
            cancelSettle?()
            cancelSettle = nil
        case .ask(let intent):
            ask(intent)
        case .reserve(let intent):
            guard let delivery else { return }
            _ = number(for: intent, from: delivery)
        case .cancelRead:
            readTask?.cancel()
        case .deliver(let intent):
            deliver(intent)
        case .drop(let intent, let why):
            // **With the capture source**, so drops can be counted by path: the 2 pt rule ends a
            // hold mid-read, and a hand drifting during a 250–570 ms capture is the case to watch.
            let source = found.removeValue(forKey: intent.serial)?.selection.quality.source.rawValue ?? "no word"
            log.notice("hover dropped: \(why.rawValue, privacy: .public) · \(source, privacy: .public)")
        }
    }

    private func ask(_ intent: HoverIntent) {
        guard let delivery else {
            // Started before anything could receive a word — `armTriggers` wires the delivery first.
            log.fault("hover: asked with nowhere to deliver a word")
            queued.append(.readEnded(serial: intent.serial, .nothing, pointer: intent.point, held: intent.held))
            return
        }
        guard let height = Self.primaryHeight(among: screens()) else {
            log.error("hover: no display to measure from")
            queued.append(.readEnded(serial: intent.serial, .nothing, pointer: intent.point, held: intent.held))
            return
        }
        // **The number is taken now, synchronously**, so its place in line is this moment. Taken
        // inside the task, a shortcut handled before the task first ran would get the lower number,
        // and this older hover could then claim the panel over it. A number nothing claims costs
        // nothing: `begin` supersedes nothing. A request asked again keeps its origin's number.
        let request = number(for: intent, from: delivery)
        readTask = Task { [weak self, reader] in
            // `.cg` here is the y-**down** Accessibility point the reader works in, produced by the
            // one explicit conversion on this line. The two spaces are only ever bridged here.
            let outcome = await reader.read(
                at: intent.point.flipped(aboutPrimaryHeight: height).cg, modifiersHeld: intent.held,
                tappedTwice: intent.tapped, pointerStillFor: intent.stillFor,
                begin: { request })
            self?.finish(intent, outcome)
        }
    }

    /// The panel number for `intent`'s origin — taken the first time it is asked or reserved, and
    /// the same number every time after, with the moment it was taken.
    private func number(for intent: HoverIntent, from delivery: any HoverDelivering) -> Int {
        if let known = origins[intent.origin] { return known.request }
        let request = delivery.beginRequest()
        origins[intent.origin] = (request, date(), now())
        while origins.count > Self.rememberedOrigins, let oldest = origins.keys.min() { origins[oldest] = nil }
        return request
    }

    private func finish(_ intent: HoverIntent, _ outcome: HoverReader.Outcome) {
        if session.inFlight?.serial == intent.serial { readTask = nil }
        let end: HoverSession.ReadEnd
        switch outcome {
        case .selection(let selection, let request, let key):
            found[intent.serial] = (selection, request, key)
            end = .word
        case .quiet(.captureInFlight):
            end = .captureBusy
        case .quiet:
            // The ordinary case, and the commonest by far: no modifier, too soon, same word.
            end = .nothing
        case .nothing(let why):
            log.debug("hover read nothing: \(why, privacy: .public)")
            end = .nothing
        case .needsScreenRecording(let request):
            // **Only for a hover that still stands**, and under its own number — a notice for a read
            // the reader abandoned, or one that took a fresh number, could replace a newer lookup or
            // reopen a panel the reader had just dismissed.
            let (at, held) = pointer()
            if !Task.isCancelled, HoverSession.stands(intent, pointer: at, held: held) {
                delivery?.screenRecordingNeeded(at: intent.point, request: request)
            }
            end = .nothing
        }
        let (at, held) = pointer()
        feed(.readEnded(serial: intent.serial, end, pointer: at, held: held))
    }

    private func deliver(_ intent: HoverIntent) {
        guard let word = found.removeValue(forKey: intent.serial) else { return }
        let asked = origins[intent.origin] ?? (word.request, date(), now())
        guard let delivery,
              delivery.deliver(word.selection, at: intent.point, request: word.request,
                               requestedAt: asked.date, askedAt: asked.instant,
                               seen: { [weak self] shown in if !shown { self?.reader.forget(word.key) } })
        else {
            log.debug("hover dropped: a later request has the panel")
            return
        }
        // Remembered on delivery so a rest on the same word does not ask again while its panel comes
        // up — and **forgotten if that panel never draws**, so a word nobody saw can be asked for.
        reader.remember(word.key)
    }

    // MARK: - The system's own sources

    /// The pointer and the hover modifiers held, read now.
    static func systemPointer() -> (UpPoint, Set<HoverModifier>) {
        (UpPoint(NSEvent.mouseLocation), modifiers(of: NSEvent.modifierFlags))
    }

    static func onMainQueue(_ delay: Duration, _ work: @escaping @MainActor () -> Void) -> Cancel {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        let parts = delay.components
        let nanoseconds = Int(parts.seconds) * 1_000_000_000 + Int(parts.attoseconds / 1_000_000_000)
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds), execute: item)
        return { item.cancel() }
    }

    // MARK: - What only the watcher decides
    //
    // `nonisolated` because they are pure: they read their arguments and nothing else. Inheriting
    // the class's isolation would make them unusable from a test without an actor hop, for no
    // safety they actually need.

    /// The hover modifiers among whatever is held. Caps lock, function and the rest are not hover
    /// modifiers, and dropping them is what keeps the policy's set comparison exact.
    nonisolated static func modifiers(of flags: NSEvent.ModifierFlags) -> Set<HoverModifier> {
        var held: Set<HoverModifier> = []
        if flags.contains(.option) { held.insert(.option) }
        if flags.contains(.control) { held.insert(.control) }
        if flags.contains(.command) { held.insert(.command) }
        if flags.contains(.shift) { held.insert(.shift) }
        return held
    }

    /// The height CGEvent measures down from: the display holding the global origin.
    ///
    /// Identified by *containing* the origin rather than by its stored origin, because `UpRect`
    /// deliberately does not expose one — an origin does not read the same in both screen spaces,
    /// which is the whole reason these types exist. Containment answers the same question without
    /// handing out a value that could be read in the wrong convention. A display to the left ends
    /// at x = 0 exclusive, so it never claims the origin.
    ///
    /// Nil rather than zero when there is no display at all. A flip about zero would put every
    /// lookup at the top of the screen — a plausible-looking answer, which is worse than none.
    nonisolated static func primaryHeight(among screens: [ScreenMetrics]) -> CGFloat? {
        guard let primary = screens.first(where: { $0.frame.contains(.zero) }) ?? screens.first
        else { return nil }
        return primary.frame.size.height
    }
}

/// The `NSEvent` monitors hover listens through.
@MainActor
final class SystemHoverEvents: HoverEventSource {
    private var monitors: [Any] = []

    /// Movement and modifiers both, because they are two ways to arrive at the same state: watching
    /// movement alone would never fire for a reader who parks the pointer on a word and *then*
    /// presses Option. The rest are watched only to cancel a pending tap; none of them starts a
    /// lookup.
    static let watched: [NSEvent.EventTypeMask] = [
        .mouseMoved, .flagsChanged,
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]

    func start(_ handler: @escaping @MainActor (HoverEvent) -> Void) -> Bool {
        guard monitors.isEmpty else { return true }
        for mask in Self.watched {
            guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
                // A global monitor's event has no window, so its location is already on screen.
                let mapped = Self.event(type: event.type, flags: event.modifierFlags, timestamp: event.timestamp,
                                        location: UpPoint(event.locationInWindow))
                MainActor.assumeIsolated { if let mapped { handler(mapped) } }
            }) else {
                // **A partial install is a failure.** Under the double-tap gesture a missing
                // `.flagsChanged` monitor makes the reader's chosen gesture unreachable while hover
                // reports itself as on. Rolling back is what lets a retry mean something.
                stop()
                return false
            }
            monitors.append(monitor)
        }
        return true
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    /// An AppKit event as hover sees it. **Anything that is not a modifier or a movement is other
    /// input**: two ⌥-arrows, or ⌘C then ⌘V, are two presses of one modifier inside the tap window,
    /// and without this they read as the gesture.
    nonisolated static func event(
        type: NSEvent.EventType, flags: NSEvent.ModifierFlags, timestamp: TimeInterval, location: UpPoint? = nil
    ) -> HoverEvent? {
        switch type {
        case .mouseMoved: .pointerMoved
        case .flagsChanged: .modifiers(HoverWatcher.modifiers(of: flags), at: timestamp, location: location)
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel: .otherInput
        default: nil
        }
    }
}
