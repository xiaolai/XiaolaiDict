import AppKit
import Capture
import CaptureModel
import DictionaryModel
import XiaolaiDictBase
import Synchronization
import os

/// What `HoverWatcher` needs of a reader — the seam its event-sequence tests replace.
@MainActor
protocol HoverReading: AnyObject {
    /// Called when the one capture that may be in flight finishes, so a hover refused
    /// `.captureInFlight` can be asked again rather than waiting for the pointer to twitch.
    var onCaptureReleased: (@MainActor () -> Void)? { get set }
    /// Called when reading the screen stops answering, and again when it answers.
    var onCaptureHealth: (@MainActor (CaptureHealth) -> Void)? { get set }
    func read(
        at point: CGPoint, modifiersHeld: Set<HoverModifier>, tappedTwice: Bool,
        pointerStillFor: Duration, begin: @MainActor () -> Int
    ) async -> HoverReader.Outcome
    /// The word under `key` was delivered: resting on it again is not a new request.
    func remember(_ key: String)
    /// The word under `key` never reached the reader — its panel did not draw — so resting on it
    /// again **is** a new request. Forgets only that word: a later one remembered since stands.
    func forget(_ key: String)
    /// The hold key came up: the hover is over, and the next one may look the same word up again.
    func endHover()
}

/// Whether the one screen capture that may be in flight is answering.
public enum CaptureHealth: Sendable, Equatable {
    case answering
    /// Held past the capture deadline, for this long when it was noticed. Until it finishes no
    /// other capture may start — two at once deadlock — so hover cannot read apps that expose no text.
    case stuck(for: Duration)
}

/// One hover: the gate, then the fast paths, then the slow one.
///
/// `HoverPolicy` decides whether to look at all — and it is asked **first**, so a reader who is
/// simply reading never pays for Accessibility, a capture, or a clock read. Only once it says yes
/// does anything touch another process.
@MainActor
public final class HoverReader: HoverReading {
    /// Two simultaneous `SCScreenshotManager` captures deadlock each other — 6 trials out of 6,
    /// display- and window-scoped alike, both callers hanging until the deadline. A single capture
    /// immediately afterwards succeeds, so it is contention, not corruption. **Any other
    /// screen-recording app can therefore stall this one**, which is why every capture is bounded
    /// and only one may be in flight.
    static let captureDeadline: Duration = .seconds(5)
    /// How long past the deadline an unwatched capture is looked at again — enough that "held past
    /// the deadline" is true when it is.
    static let stuckCheckMargin: Duration = .milliseconds(100)

    /// What *this* reader allows. The shipped value protects the reader from a wedged capture; an
    /// instrument measuring the path needs to be allowed to finish, because a measurement that is
    /// killed at the budget can only ever report "over budget" and never by how much or why.
    private let captureDeadline: Duration
    /// The whole Accessibility read's budget — `ScreenWordReader.budget` for the reader, longer for
    /// an instrument, for the reason `captureDeadline` gives.
    private let accessibilityBudget: Duration

    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "hover")
    private let source: any ScreenWordSource
    var onCaptureReleased: (@MainActor () -> Void)?
    var onCaptureHealth: (@MainActor (CaptureHealth) -> Void)?
    private let policy: @MainActor () -> HoverPolicy
    private let pause: @MainActor () -> HoverPause

    /// Held while a capture is running. A second hover is refused rather than started.
    ///
    /// A reference type so the guard can be handed to the task that releases it — and because
    /// "who may release this" is the whole point, a value copy would be exactly wrong.
    ///
    /// **It records when it was claimed**, so a capture that has stopped answering can say so. The
    /// guard is right to stay held — while one capture is wedged, no other may start — but holding
    /// it silently made hover over a terminal stop working with nothing said anywhere.
    final class CaptureGuard: Sendable {
        private struct State {
            var claimedAt: ContinuousClock.Instant?
            /// This wedge has been reported. Cleared on release, so each wedge is reported once.
            var reported = false
        }

        private let state = Mutex(State())
        private let now: @Sendable () -> ContinuousClock.Instant

        init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
            self.now = now
        }

        /// True if this caller now holds it. False means someone else does.
        func claim() -> Bool {
            let at = now()
            return state.withLock { state -> Bool in
                guard state.claimedAt == nil else { return false }
                state.claimedAt = at
                return true
            }
        }

        /// Releases it, and answers how long it was held and whether that wedge had been reported.
        @discardableResult
        func release() -> (held: Duration, wasReported: Bool) {
            let at = now()
            return state.withLock { state in
                let held = state.claimedAt.map { at - $0 } ?? .zero
                let reported = state.reported
                state = State()
                return (held, reported)
            }
        }

        var isHeld: Bool { state.withLock { $0.claimedAt != nil } }

        /// How long the capture in flight has been held so far, or nil where none is.
        func heldFor() -> Duration? {
            let at = now()
            return state.withLock { $0.claimedAt.map { at - $0 } }
        }

        /// How long the capture in flight has been held, where that is past `deadline`.
        func overdue(after deadline: Duration) -> Duration? {
            let at = now()
            return state.withLock { state in
                guard let claimed = state.claimedAt, at - claimed > deadline else { return nil }
                return at - claimed
            }
        }

        /// True the first time a wedge is reported, false after — so the fault is logged once.
        func markReported() -> Bool {
            state.withLock { state in
                guard !state.reported else { return false }
                state.reported = true
                return true
            }
        }
    }

    private let capturing: CaptureGuard
    /// The word the last hover looked up, so resting on it does not look it up again.
    ///
    /// **Written when a word is delivered, not when it is read** — by `remember`, which the watcher
    /// calls once the panel has been claimed. Written at read time, a result the watcher then
    /// dropped would suppress the reader's next hover on the very word they never got.
    ///
    /// **Cleared when the modifier is released**, because that is what ends a hover. It used to be
    /// cleared only by a *different* successful lookup, so a reader who looked a word up, let go,
    /// and reached for the same word again got nothing — and the only way out was to look
    /// something else up first, which nobody would guess was the rule.
    var lastLookedUp: String?

    init(
        policy: @escaping @MainActor () -> HoverPolicy = { .shipped },
        pause: @escaping @MainActor () -> HoverPause = { HoverPause() },
        captureDeadline: Duration = HoverReader.captureDeadline,
        accessibilityBudget: Duration = ScreenWordReader.budget,
        source: any ScreenWordSource = SystemScreenWords(),
        capturing: CaptureGuard = CaptureGuard()
    ) {
        self.capturing = capturing
        self.policy = policy
        self.pause = pause
        self.captureDeadline = captureDeadline
        self.accessibilityBudget = accessibilityBudget
        self.source = source
    }

    /// **The reader on the real screen, with deadlines of the caller's own** — the one public initialiser. The watcher
    /// builds hover's reader through it with the shipped deadlines, and `--read-point` with its own: an instrument sets
    /// its own deadline, because a measurement killed at the product's budget can only ever report "over budget". The
    /// seams above are for tests. `source` is named only so this does not resolve to itself.
    public convenience init(
        policy: @escaping @MainActor () -> HoverPolicy, pause: @escaping @MainActor () -> HoverPause,
        captureDeadline: Duration, accessibilityBudget: Duration
    ) {
        self.init(policy: policy, pause: pause, captureDeadline: captureDeadline,
                  accessibilityBudget: accessibilityBudget, source: SystemScreenWords())
    }

    public enum Outcome: Sendable {
        /// A word, the panel request it was read for, and the key that suppresses it once shown.
        case selection(Selection, request: Int, key: String)
        /// The gate said no. Ordinary, and not worth showing.
        case quiet(HoverRefusal)
        /// The gate said yes and nothing could be read, with why — worth a log line, not a panel.
        case nothing(String)
        /// Only the pixels could answer, and Screen Recording is off. **Nothing was asked of the
        /// system**: the reader is told once where to grant it.
        case needsScreenRecording(request: Int)
    }

    /// `pointerStillFor` is how long the pointer has rested. Debouncing is the caller's clock;
    /// this only enforces it, so the policy stays pure and testable.
    public func read(
        at point: CGPoint, modifiersHeld: Set<HoverModifier>, tappedTwice: Bool,
        pointerStillFor: Duration, begin: @MainActor () -> Int
    ) async -> Outcome {
        let policy = policy()

        // **A completed double-tap is a new request, and says so.** Repeat suppression is lifted
        // by the *absence* of the gesture — under `.hold` that is the key coming up, which happens
        // constantly. Under `.doubleTap` the clearing read is skipped whenever a capture is in
        // flight, so a reader who taps the same word twice in a row was refused as `.samePlace`
        // for a request they had plainly just made.
        if tappedTwice { lastLookedUp = nil }

        // **The cheap refusals first, before any IPC.** A reader who is simply reading pays one
        // set comparison and a clock read — not an Accessibility round trip into another process.
        // Resolving the target first, to learn which app owns the pixel, quietly undid that.
        let ungated = policy.decide(
            at: HoverSite(bundleID: nil), modifiersHeld: modifiersHeld, tappedTwice: tappedTwice,
            pointerStillFor: pointerStillFor, pausedUntil: pause().until, lastLookedUp: nil,
            // **Not refused for a capture in flight here.** Only the capture path needs the one guard;
            // refusing at the gate stopped every hover — Accessibility ones too — while a capture was
            // wedged. The capture path is still refused below, which is the whole of the rule.
            captureInFlight: false, now: .now)
        if case .stayQuiet(let refusal) = ungated {
            // A busy capture stays `.captureInFlight` even when it is wedged, so the watcher still
            // asks again on release; the wedge is reported beside it, once.
            // Letting go of the modifier ends the hover, and with it the suppression: the next
            // hold may look the same word up again. Every other refusal here is a pause in one
            // continuing hover and leaves it alone.
            // **Both gestures' "the reader is not asking" refusal.** Under `.hold` that is the
            // key being up; under `.doubleTap` it is simply no tap, which is every moment between
            // them. Either way the hover has ended, and the next ask may look the same word up
            // again — every other refusal is a pause inside one continuing hover and leaves it.
            if refusal == .modifierNotHeld || refusal == .notTapped { lastLookedUp = nil }
            return .quiet(refusal)
        }
        // **The request's place in line is now**, when the gate accepted the gesture — not when the
        // word has been read. It supersedes nothing: claiming the panel is a separate act, at
        // delivery, and fails if anything was claimed after this.
        let request = begin()

        // **Listed once per hover**, and the same list serves both paths — see `PointerTarget`.
        let listed = WindowList(source)
        let target: ScreenWordReader.Target?
        switch await authorise(at: point, listed: listed, policy: policy) {
        case .refused(let refusal): return .quiet(refusal)
        case .allowed(let found): target = found
        }

        // Accessibility first: 1–9 ms where it works, and it returns the **whole sentence**,
        // because it reads text rather than pixels.
        if let target {
            switch await source.read(at: point, in: target, budget: accessibilityBudget) {
            case .hit(let hit):
                return accept(Self.selection(from: hit), request: request, policy: policy, point: point)
            case .miss(let reason):
                log.debug("accessibility missed: \(reason, privacy: .public)")
            case .cancelled:
                return .quiet(.cancelled)
            }
        }

        return await readThePixels(at: point, owner: target?.pid, windows: listed.value, request: request, policy: policy)
    }

    /// Whether `authorise` let the hover through, and to what.
    private enum Authorisation {
        case refused(HoverRefusal)
        /// The element Accessibility named, or nil where it named none — the capture path still runs.
        case allowed(ScreenWordReader.Target?)
    }

    /// **Who owns the pixel, and may this reader read it** — resolved before any text or pixel is read
    /// (audit round 3, #11: `read` did this inline beside the gate and both reading paths).
    private func authorise(at point: CGPoint, listed: WindowList, policy: HoverPolicy) async -> Authorisation {
        // Now who owns the pixel — resolved **before** any text is read. The frontmost app is a
        // different question: hovering a visible background terminal while a browser is active
        // would otherwise read the terminal first and reject it afterwards, which is not what an
        // exclusion is for.
        //
        // A target that cannot be resolved is *not* the end of the lookup: an app exposing no
        // Accessibility element at all — a terminal, a canvas — is exactly what the recogniser
        // exists for, and returning here disabled it where it is needed most.
        var target: ScreenWordReader.Target?
        let source = source
        // **Our own window first, from the compositor, with or without the Accessibility grant.**
        // The check inside `target` runs only once the grant is known; without it, the capture path
        // read the app underneath XiaolaiDict's own panel.
        if PointerWindow.ours(at: point, in: listed.value, ours: getpid()) { return .refused(.samePlace) }
        switch await source.target(at: point, windows: { listed.value }) {
        case .none(let why): log.debug("no accessibility target: \(why, privacy: .public)")
        case .ourOwnWindow: return .refused(.samePlace)
        case .found(let found):
            if let refusal = CaptureAuthorization.refusal(bundleID: found.bundleID, policy: policy) {
                return .refused(refusal)
            }
            target = found
        }
        // **A reader who moved on starts nothing new.** The target's own cancellation answers
        // `.none`, which would otherwise fall through to a capture nobody is waiting for.
        guard !Task.isCancelled else { return .refused(.cancelled) }

        // **The site, before any text or pixel is read — and only where the reader excluded one**,
        // so a reader who never did pays nothing. With no element to ask there is no page to name,
        // and an unnamed page is refused rather than assumed to be a different site.
        if !policy.excludedHosts.isEmpty {
            let host: HostReading
            if let target { host = await source.host(of: target, budget: accessibilityBudget) } else { host = .unreadable }
            if let refusal = CaptureAuthorization.refusal(host: host, policy: policy) { return .refused(refusal) }
            guard !Task.isCancelled else { return .refused(.cancelled) }
        }
        return .allowed(target)
    }

    /// **The capture path, once Accessibility had nothing.** Read the pixels — 250–570 ms, and it can
    /// be wrong rather than merely absent, so what comes back carries the recogniser's own confidence.
    private func readThePixels(
        at point: CGPoint, owner: pid_t?, windows: [ListedWindow], request: Int, policy: HoverPolicy
    ) async -> Outcome {
        let source = source
        // **The window read is the one the app Accessibility named**, where it named one.
        let pointer = PointerTarget(point: point, windows: windows, accessibilityOwner: owner)
        let window: ListedWindow
        switch pointer.captureWindow(excludingProcess: getpid()) {
        case .window(let chosen, let obscuredBy):
            if let obscuredBy {
                log.notice("capture: reading window \(chosen.windowID, privacy: .public) of pid \(chosen.pid, privacy: .public) under window \(obscuredBy.windowID, privacy: .public) of pid \(obscuredBy.pid, privacy: .public)")
            }
            window = chosen
        case .ownerHasNoWindow(let owner):
            return .nothing("the app Accessibility named (pid \(owner)) has no window under the pointer")
        case .noWindow:
            return .nothing("no window under the pointer")
        }
        guard capturing.claim() else {
            reportIfStuck()
            return .quiet(.captureInFlight)
        }

        do {
            // The recogniser checks the *window's* owner against the same rule before it captures
            // a single pixel — the AX target may be nil here, so this is the only exclusion the
            // OCR path gets before the fact.
            let recognition = try await bounded {
                try await source.recognise(at: point, window: window, policy: policy)
            }
            return accept(Self.selection(from: recognition), request: request, policy: policy, point: point)
        } catch RecognitionError.screenRecordingDenied {
            // A reader who moved on is not told anything.
            return Task.isCancelled ? .quiet(.cancelled) : .needsScreenRecording(request: request)
        } catch is DeadlineExceeded {
            // **The deadline passed and the capture is still running**: it is stuck now, not when
            // the next hover happens to ask — which may be never.
            if capturing.isHeld { reportStuck(for: captureDeadline) }
            return .nothing("reading the screen did not answer within \(captureDeadline)")
        } catch {
            return Task.isCancelled ? .quiet(.cancelled) : .nothing(error.localizedDescription)
        }
    }

    /// The one place a read becomes an answer.
    ///
    /// **Written once because both capture paths reach it.** Accessibility and OCR each had their
    /// own copy of "is there a word, is it refused, remember it, return it" — four lines apiece,
    /// and any change to what acceptance means had to be made twice or drift.
    ///
    /// **Cancellation is checked here, after the read and before anything is remembered.** The
    /// capture runs on a detached task, which does not inherit this call's cancellation — so a
    /// reader who switches hover off, or a watcher that tears down mid-read, still had a selection
    /// delivered and `lastLookedUp` written under them. The work cannot be stopped; accepting its
    /// result can be.
    private func accept(
        _ selection: Selection?, request: Int, policy: HoverPolicy, point: CGPoint
    ) -> Outcome {
        guard !Task.isCancelled else { return .quiet(.cancelled) }
        guard let selection else { return .nothing("no word under the pointer") }
        if let refusal = postReadRefusal(selection, policy: policy, point: point) {
            return .quiet(refusal)
        }
        return .selection(selection, request: request, key: Self.key(selection, at: point))
    }

    func remember(_ key: String) { lastLookedUp = key }

    func forget(_ key: String) { if lastLookedUp == key { lastLookedUp = nil } }

    func endHover() { lastLookedUp = nil }

    /// Why a capture is refused when the one in flight has run past its deadline — **said, not
    /// swallowed**: a quiet `.captureInFlight` is the ordinary case, and a wedged capture looked
    /// exactly like it. Logged as a fault once per wedge, and handed to whoever shows the reader.
    private func reportIfStuck() {
        guard let held = capturing.overdue(after: captureDeadline) else { return }
        reportStuck(for: held)
    }

    /// Once per wedge: a fault in the log, and the reader told through `onCaptureHealth`.
    private func reportStuck(for held: Duration) {
        guard capturing.markReported() else { return }
        log.fault("capture: the screen capture has not answered for \(held.seconds, privacy: .public) s; no other may start until it does")
        onCaptureHealth?(.stuck(for: held))
    }

    /// Runs `work` under the capture deadline, and **releases the capture guard only when `work`
    /// itself finishes** — which may be long after the deadline returned.
    ///
    /// This is the distinction the guard lives or dies on. `withDeadline` answers the caller when
    /// the clock runs out and *abandons* the losing work; it does not cancel a `SCScreenshotManager`
    /// call that has stopped responding. Releasing the guard on return would therefore let the next
    /// hover start a second capture while the first is still in flight — which is precisely the
    /// contention that deadlocked 6 trials out of 6, rebuilt by the code meant to prevent it.
    ///
    /// So the guard is released by the work's own continuation. A capture that never finishes holds
    /// it forever, and that is the correct outcome: while one is wedged, no other may start.
    private func bounded<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        // **The guard is released by the work's own continuation, not by this function's return.**
        // A capture that never finishes holds it forever, and that is the correct outcome: while
        // one is wedged, no other may start. Nothing is caught here — an earlier version wrapped
        // the call in a `do/catch` that only rethrew, under a comment asserting the deadline had
        // won. It had not necessarily: a capture error and a cancellation arrive by the same path,
        // and the comment claimed to know which.
        let finished = Task { [capturing, weak self] () async throws -> T in
            defer {
                let (held, wasReported) = capturing.release()
                if wasReported {
                    Logger(subsystem: XiaolaiDictIdentity.app, category: "hover")
                        .notice("capture: answered after \(held.seconds, privacy: .public) s; reading the screen works again")
                    Task { @MainActor in self?.onCaptureHealth?(.answering) }
                }
                // Told on the main actor, after the release, so whatever was refused for the busy
                // guard is asked again against a guard it can claim.
                Task { @MainActor in self?.onCaptureReleased?() }
            }
            return try await work()
        }
        // **Cancelled when the deadline wins, and that is not the same as stopping it.**
        // `withDeadline` cancels the task *waiting* on `finished.value`, never `finished` itself —
        // `Task { }` does not inherit cancellation, which this project already records. So work
        // abandoned by the reader ran on with `Task.isCancelled == false`, and anything downstream
        // that asks was told it was still wanted. (That once included a permission prompt; hover
        // no longer has one to raise.)
        //
        // The guard's contract is untouched. A capture that cannot be stopped still holds
        // `capturing` until it finishes, because the release is in the work's own `defer` and
        // ScreenCaptureKit does not honour cancellation anyway. All this changes is that the
        // abandoned work can now *find out* it was abandoned.
        defer {
            finished.cancel()
            // **A wedge is noticed even if nobody waits for it.** A hover cancelled mid-capture left
            // the capture holding the guard and nothing to look at it again; checked once the
            // deadline has passed, it is reported whether or not another hover ever asks.
            if let held = capturing.heldFor() {
                // The deadline's remaining time, not a fresh one: a capture abandoned near its end is
                // already almost overdue.
                let wait = max(.zero, captureDeadline - held) + Self.stuckCheckMargin
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: wait)
                    self?.reportIfStuck()
                }
            }
        }
        return try await withDeadline(captureDeadline) { try await finished.value }
    }

    /// The refusals that need the reading itself, so they cannot be part of the gate.
    ///
    /// Named for *when* it runs rather than for what it happened to check first: it began as
    /// `repeatOrExcluded`, then grew the script filter, and the name went on describing two of its
    /// three reasons. Exclusion is enforced before the read as well — this is the second line, not
    /// the only one: the recogniser reports the *window's* owner, which is not always the owner of
    /// the element the pointer is over.
    private func postReadRefusal(
        _ selection: Selection, policy: HoverPolicy, point: CGPoint
    ) -> HoverRefusal? {
        if let refusal = CaptureAuthorization.refusal(bundleID: selection.place.bundleID, policy: policy) {
            return refusal
        }
        // **The script the word is written in, which could not be asked before it was read.**
        // Everything the gate refuses, it refuses before paying for anything; this one costs the
        // Accessibility round trip or the capture that already happened, and saves what comes
        // after — the XPC lookup and the sense ladder, which on an ambiguous entry is a prompt
        // through the model on the GPU for an answer the reader never wanted.
        //
        // Hover only. `XiaolaiDictApp.lookUpSelection` does not come through here and must not:
        // the reader selected that text and pressed the shortcut, and refusing what was explicitly
        // asked for is a different product from declining to volunteer.
        if !policy.studies(selection.text) { return .scriptNotStudied }
        if Self.key(selection, at: point) == lastLookedUp { return .samePlace }
        return nil
    }

    /// Identifies the word *and* roughly where it was, so the same word twice in a sentence is two
    /// hovers but resting on one is one.
    /// **The app is part of the identity, not just the word and the place.** The key was the word
    /// and an 8-point cell, so `run` in a terminal and `run` at the same screen position in a
    /// browser were one lookup and the second was dropped in silence — the likeliest way to meet
    /// this being a reader comparing the same word in two windows.
    ///
    /// Not `private`, so the identity can be asserted directly rather than inferred from a hover
    /// that needs a real screen to fire.
    /// `nonisolated` for the reason `HoverWatcher`'s helpers are: it reads its arguments and
    /// nothing else, and inheriting the class's isolation would cost a test an actor hop for no
    /// safety it needs.
    nonisolated static func key(_ selection: Selection, at point: CGPoint) -> String {
        let place = selection.place.bundleID ?? "—"
        // The sentence as well, because the same word at the same point in the same app can
        // still be a different lookup: the page scrolled, or the pane behind the pointer was
        // replaced. Hashed rather than carried whole — this is an identity, not a record, and
        // a sentence held here would keep a copy of the reader's text alive in the reader.
        //
        // `hashValue` is allowed *here* and banned for the word colours, and the difference
        // is lifetime: `Hasher` is seeded per process, so a value that outlives the run is
        // unusable. This key is compared only against `lastLookedUp`, which is memory and
        // dies with the process. Nothing derived from it is stored or drawn.
        let context = selection.sentence.map { String($0.hashValue, radix: 16) } ?? "—"
        return "\(place)|\(context)|\(selection.text)@\(Int(point.x / 8))x\(Int(point.y / 8))"
    }

    private static func selection(from hit: ScreenWordReader.Hit) -> Selection? {
        // Accessibility hands over the app's own characters, so the capture is exact.
        guard let quality = CaptureQuality(
            source: hit.source, confidence: 1, context: hit.word.sentence.mayBeCut ? .mayBeCut : .complete)
        else { return nil }
        return selection(of: hit.word, quality: quality, bundleID: hit.bundleID, appName: hit.appName)
    }

    private static func selection(from recognition: Recognition) -> Selection? {
        // The recogniser's own confidence, not 1. A reading at 0.5 is a guess, and the panel and
        // the ledger both have to be able to say so.
        guard let quality = CaptureQuality(
            source: .opticalRecognition,
            confidence: min(max(recognition.confidence, 0), 1),
            context: recognition.mayBeCut ? .mayBeCut : .complete)
        else { return nil }
        return selection(of: recognition.word, quality: quality, bundleID: recognition.bundleID, appName: recognition.appName)
    }

    /// The one construction both sources share; what differs between them is the quality, which each
    /// works out for itself (audit round 3, #12).
    private static func selection(
        of word: WordAtPoint, quality: CaptureQuality, bundleID: String?, appName: String?
    ) -> Selection {
        Selection(text: word.word, sentence: word.sentence.text, rangeInSentence: word.sentence.selection,
                  quality: quality, place: ReadingPlace(bundleID: bundleID, name: appName))
    }
}

/// The compositor's window list, taken at most once per hover and only when first wanted — the
/// refused-grant path never pays for it, and both paths that do read the same list.
private final class WindowList: Sendable {
    private let source: any ScreenWordSource
    private let taken = Mutex<[ListedWindow]?>(nil)

    init(_ source: any ScreenWordSource) { self.source = source }

    var value: [ListedWindow] {
        taken.withLock { taken in
            if let taken { return taken }
            let listed = source.listedWindows()
            taken = listed
            return listed
        }
    }
}
