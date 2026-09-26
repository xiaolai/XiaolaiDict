import Foundation
import Observation
import XiaolaiDictCore

/// Everything the reader can do to hover, and the one place each of those values lives.
///
/// **Its own type because every member here has already been a defect about identity — about there
/// being *one* value rather than a fresh one per call, or one copy rather than two.** That is the
/// thread running through all of it:
///
/// - `pause` exists because `HoverReader`'s default built a **fresh `HoverPause` on every call**, so
///   the gate asked "is XiaolaiDict paused" of an object just born, which always answered no. The
///   model was complete, unit-tested and unreachable for months under a green suite.
/// - `policy` is held in memory rather than loaded per use because `HoverWatcher` asks for it on
///   every pointer change to get `settleMilliseconds` — a JSON decode on the mouse-move path. One
///   decode at launch, one write when the reader changes something, and **no second copy** to keep
///   in step: the watcher reads this property, so there is nothing to restart.
/// - `isEnabled` reached for `UserDefaults.standard` while every other store on the delegate took
///   the injected suite, so a unit test could switch the reader's hover off.
///
/// The watcher itself is built here and handed closures onto these values rather than copies of
/// them, so a decision is made against what is true at decision time.
@Observable
@MainActor
final class HoverControl {
    /// Milestone 2's trigger. Watches the pointer and reads the word under it when the reader rests
    /// with the modifier held; the reading itself is `HoverReader`, already tested.
    ///
    /// **`lazy` so its closures can read `self`** — a stored property cannot, which is the
    /// mechanical reason the pause was never connected to anything in the first place.
    @ObservationIgnored private(set) lazy var watcher = makeWatcher()

    /// **The pause the menu offers and the gate reads — one value.**
    private(set) var pauseSwitch = HoverPause()

    /// The reader's policy, observed, with the store behind it.
    private(set) var policy: HoverPolicy

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: HoverPolicyStore

    private static let enabledKey = "hoverLookupEnabled"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let store = HoverPolicyStore(defaults: defaults)
        self.store = store
        // Loaded once, here, rather than lazily: `@Observable` makes stored properties computed, so
        // there is no `lazy` to be had — and a per-use load would be the mouse-move decode this
        // property exists to avoid.
        policy = store.load()
    }

    /// `self` is read at decision time, not captured by value — a copy taken here would be the
    /// never-changing pause this type exists to replace.
    private func makeWatcher() -> HoverWatcher {
        HoverWatcher(
            policy: { [weak self] in self?.policy ?? .shipped },
            pause: { [weak self] in self?.pauseSwitch ?? HoverPause() })
    }

    /// Whether the reader has hover on. Defaults to on for a reader who has never chosen, and
    /// remembers one who has. **Through the injected suite**, never `.standard`.
    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// Whether the watcher actually holds its monitors — **mirrored into observed state**, because
    /// `HoverWatcher` is not `@Observable` and a menu reading through it was never invalidated when
    /// hover started or stopped.
    ///
    /// **Read back from the watcher rather than assumed from the setting.** `start()` can fail to
    /// register a global monitor, so a control showing the reader's preference would say "on" for a
    /// hover that is not running — which is why the menu reads this and not `isEnabled`.
    private(set) var isWatching = false

    /// What the pause control says. Observed, so pausing redraws the menu without being told to.
    var pauseLabel: String { pauseSwitch.label(at: .now) }
    var isPaused: Bool { pauseSwitch.isPaused(at: .now) }

    func pause(for duration: Duration) { pauseSwitch.pause(for: duration, from: .now) }
    func resume() { pauseSwitch.resume() }

    /// Changing the policy saves it and takes effect immediately.
    func setPolicy(_ policy: HoverPolicy) {
        self.policy = policy
        store.save(policy)
    }

    /// Starts watching where the reader has hover on. Called once there is a window to draw a
    /// lookup into — never at launch, and never in an instrument run.
    func startIfEnabled() {
        guard isEnabled else { return }
        watcher.start()
        isWatching = watcher.isWatching
    }

    /// **Takes the value asked for, rather than inverting what is stored.** The menu's toggle reads
    /// `isWatching`, so when starting failed it draws off while the preference is on — and a `set`
    /// that ignored its argument and flipped the preference would then save *off* and never retry.
    /// Asked for `true` against a failed start, this tries again.
    func setEnabled(_ on: Bool) {
        isEnabled = on
        if on { watcher.start() } else { watcher.stop() }
        isWatching = watcher.isWatching
    }

    func toggle() { setEnabled(!isEnabled) }
}
