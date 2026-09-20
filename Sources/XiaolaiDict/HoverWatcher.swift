import AppKit
import XiaolaiDictCore
import os

/// Watches the pointer and asks `HoverReader` once the reader has rested somewhere with the
/// modifier held.
///
/// This is Milestone 2's trigger, and the only part of hover that was missing: the Accessibility
/// dialects and the recogniser were built, tested and verified end to end, but nothing in the app
/// ever called them — `HoverReader`'s only caller was the `--read-point` instrument.
///
/// The watcher deliberately holds no policy of its own. Whether to read at all is
/// `HoverPolicy.decide`, asked inside `HoverReader` and in cost order, so a reader who is simply
/// reading pays a set comparison and a clock read rather than an Accessibility round trip.
@MainActor
final class HoverWatcher {
    /// How far a resting pointer may drift and still be resting. A pointer held on a word twitches
    /// by a point or two; counting that as movement restarts the dwell every time and the popup
    /// never fires at all.
    nonisolated static let restTolerance: CGFloat = 2

    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "hover")
    private let reader: HoverReader
    private let policy: () -> HoverPolicy
    private let screens: () -> [ScreenMetrics]

    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var restingSince = ContinuousClock.now
    private var lastSeen = UpPoint.zero
    /// One read at a time. A second while the first is still going would queue captures behind
    /// each other, and two simultaneous screen captures deadlock.
    private var inFlight: Task<Void, Never>?

    /// A word the reader rested on, with where they rested — so the panel opens under the pointer.
    var onWord: (@MainActor (Selection, UpPoint) -> Void)?

    init(
        policy: @escaping () -> HoverPolicy = { .shipped },
        screens: @escaping () -> [ScreenMetrics] = { NSScreen.screens.map(ScreenMetrics.init) }
    ) {
        self.policy = policy
        self.screens = screens
        self.reader = HoverReader(policy: policy)
    }

    var isWatching: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        // Movement and modifiers both, because they are two ways to arrive at the same state.
        // Watching movement alone would never fire for a reader who parks the pointer on a word
        // and *then* presses Option, which is the natural way to use it.
        for mask in [NSEvent.EventTypeMask.mouseMoved, .flagsChanged] {
            guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerChanged() }
            }) else {
                log.error("hover: could not watch \(String(describing: mask), privacy: .public)")
                continue
            }
            monitors.append(monitor)
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        inFlight?.cancel()
        inFlight = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }

    private func pointerChanged() {
        let now = UpPoint(NSEvent.mouseLocation)
        if Self.hasMoved(from: lastSeen, to: now) {
            lastSeen = now
            restingSince = ContinuousClock.now
        }
        // Rescheduled on every event rather than run on every event: the check happens once the
        // pointer has been still for the settle interval, however many events arrived meanwhile.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.check() } }
        pending = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(policy().settleMilliseconds), execute: work)
    }

    private func check() {
        guard inFlight == nil else { return }
        guard let height = Self.primaryHeight(among: screens()) else {
            log.error("hover: no display to measure from")
            return
        }
        let at = UpPoint(NSEvent.mouseLocation)
        let held = Self.modifiers(of: NSEvent.modifierFlags)
        let resting = ContinuousClock.now - restingSince

        inFlight = Task { [weak self] in
            guard let self else { return }
            defer { self.inFlight = nil }
            // `.cg` here is the y-**down** Accessibility point the reader works in, produced by the
            // one explicit conversion on the line above. The two spaces are only ever bridged here.
            let outcome = await self.reader.read(
                at: at.flipped(aboutPrimaryHeight: height).cg, modifiersHeld: held, pointerStillFor: resting)
            switch outcome {
            case .selection(let selection):
                self.onWord?(selection, at)
            case .quiet:
                // The ordinary case, and the commonest by far: no modifier, too soon, same word.
                break
            case .nothing(let why):
                self.log.debug("hover read nothing: \(why, privacy: .public)")
            }
        }
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

    /// True when the pointer has genuinely moved rather than drifted. Measured as a distance, not
    /// per axis: a pointer sliding along a diagonal moves less than the tolerance on either axis
    /// while going further than it on both.
    nonisolated static func hasMoved(from: UpPoint, to: UpPoint, tolerance: CGFloat = HoverWatcher.restTolerance) -> Bool {
        hypot(to.cg.x - from.cg.x, to.cg.y - from.cg.y) > tolerance
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
