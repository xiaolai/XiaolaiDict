import AppKit
import XiaolaiDictCore
import Synchronization
import os

/// One hover: the gate, then the fast paths, then the slow one.
///
/// `HoverPolicy` decides whether to look at all — and it is asked **first**, so a reader who is
/// simply reading never pays for Accessibility, a capture, or a clock read. Only once it says yes
/// does anything touch another process.
@MainActor
final class HoverReader {
    /// Two simultaneous `SCScreenshotManager` captures deadlock each other — 6 trials out of 6,
    /// display- and window-scoped alike, both callers hanging until the deadline. A single capture
    /// immediately afterwards succeeds, so it is contention, not corruption. **Any other
    /// screen-recording app can therefore stall this one**, which is why every capture is bounded
    /// and only one may be in flight.
    static let captureDeadline: Duration = .seconds(5)

    /// What *this* reader allows. The shipped value protects the reader from a wedged capture; an
    /// instrument measuring the path needs to be allowed to finish, because a measurement that is
    /// killed at the budget can only ever report "over budget" and never by how much or why.
    private let captureDeadline: Duration

    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "hover")
    private let recogniser = ScreenTextRecogniser()
    private let policy: @MainActor () -> HoverPolicy
    private let pause: @MainActor () -> HoverPause

    /// Held while a capture is running. A second hover is refused rather than started.
    ///
    /// A reference type so the guard can be handed to the task that releases it — and because
    /// "who may release this" is the whole point, a value copy would be exactly wrong.
    final class CaptureGuard: Sendable {
        private let held = Mutex(false)

        /// True if this caller now holds it. False means someone else does.
        func claim() -> Bool {
            held.withLock { held -> Bool in
                guard !held else { return false }
                held = true
                return true
            }
        }

        func release() { held.withLock { $0 = false } }
        var isHeld: Bool { held.withLock { $0 } }
    }

    private let capturing = CaptureGuard()
    /// The word the last hover looked up, so resting on it does not look it up again.
    ///
    /// **Cleared when the modifier is released**, because that is what ends a hover. It used to be
    /// cleared only by a *different* successful lookup, so a reader who looked a word up, let go,
    /// and reached for the same word again got nothing — and the only way out was to look
    /// something else up first, which nobody would guess was the rule.
    var lastLookedUp: String?

    init(
        policy: @escaping @MainActor () -> HoverPolicy = { .shipped },
        pause: @escaping @MainActor () -> HoverPause = { HoverPause() },
        captureDeadline: Duration = HoverReader.captureDeadline
    ) {
        self.policy = policy
        self.pause = pause
        self.captureDeadline = captureDeadline
    }

    enum Outcome: Sendable {
        case selection(Selection)
        /// The gate said no. Ordinary, and not worth showing.
        case quiet(HoverRefusal)
        /// The gate said yes and nothing could be read, with why — worth a log line, not a panel.
        case nothing(String)
    }

    /// `pointerStillFor` is how long the pointer has rested. Debouncing is the caller's clock;
    /// this only enforces it, so the policy stays pure and testable.
    func read(at point: CGPoint, modifiersHeld: Set<HoverModifier>, pointerStillFor: Duration) async -> Outcome {
        let policy = policy()

        // **The cheap refusals first, before any IPC.** A reader who is simply reading pays one
        // set comparison and a clock read — not an Accessibility round trip into another process.
        // Resolving the target first, to learn which app owns the pixel, quietly undid that.
        let ungated = policy.decide(
            at: HoverSite(bundleID: nil), modifiersHeld: modifiersHeld,
            pointerStillFor: pointerStillFor, pausedUntil: pause().until, lastLookedUp: nil,
            captureInFlight: capturing.isHeld, now: .now)
        if case .stayQuiet(let refusal) = ungated {
            // Letting go of the modifier ends the hover, and with it the suppression: the next
            // hold may look the same word up again. Every other refusal here is a pause in one
            // continuing hover and leaves it alone.
            if refusal == .modifierNotHeld { lastLookedUp = nil }
            return .quiet(refusal)
        }

        // Now who owns the pixel — resolved **before** any text is read. The frontmost app is a
        // different question: hovering a visible background terminal while a browser is active
        // would otherwise read the terminal first and reject it afterwards, which is not what an
        // exclusion is for.
        //
        // A target that cannot be resolved is *not* the end of the lookup: an app exposing no
        // Accessibility element at all — a terminal, a canvas — is exactly what the recogniser
        // exists for, and returning here disabled it where it is needed most.
        var target: ScreenWordReader.Target?
        switch await Task.detached(priority: .userInitiated, operation: {
            ScreenWordReader.target(at: point)
        }).value {
        case .none(let why): log.debug("no accessibility target: \(why, privacy: .public)")
        case .ourOwnWindow: return .quiet(.samePlace)
        case .found(let found):
            if let bundleID = found.bundleID, policy.excludedApps.contains(bundleID) {
                return .quiet(.excludedApp)
            }
            target = found
        }

        // Accessibility first: 1–9 ms where it works, and it returns the **whole sentence**,
        // because it reads text rather than pixels.
        if let target {
            switch await Task.detached(priority: .userInitiated, operation: {
                ScreenWordReader.read(at: point, in: target)
            }).value {
            case .hit(let hit):
                return accept(Self.selection(from: hit), policy: policy, point: point)
            case .miss(let reason):
                log.debug("accessibility missed: \(reason, privacy: .public)")
            }
        }

        // Nothing exposed its text. Read the pixels — 250–570 ms, and it can be wrong rather than
        // merely absent, so what comes back carries the recogniser's own confidence.
        guard capturing.claim() else { return .quiet(.captureInFlight) }

        do {
            // The recogniser checks the *window's* owner against the same list before it captures
            // a single pixel — the AX target may be nil here, so this is the only exclusion the
            // OCR path gets before the fact.
            let excluded = policy.excludedApps
            let recognition = try await bounded { [recogniser] in
                try await recogniser.read(at: point, excluding: excluded)
            }
            return accept(Self.selection(from: recognition), policy: policy, point: point)
        } catch {
            return .nothing(error.localizedDescription)
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
        _ selection: Selection?, policy: HoverPolicy, point: CGPoint
    ) -> Outcome {
        guard !Task.isCancelled else { return .quiet(.cancelled) }
        guard let selection else { return .nothing("no word under the pointer") }
        if let refusal = postReadRefusal(selection, policy: policy, point: point) {
            return .quiet(refusal)
        }
        lastLookedUp = Self.key(selection, at: point)
        return .selection(selection)
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
        let finished = Task { [capturing] () async throws -> T in
            defer { capturing.release() }
            return try await work()
        }
        // **Cancelled when the deadline wins, and that is not the same as stopping it.**
        // `withDeadline` cancels the task *waiting* on `finished.value`, never `finished` itself —
        // `Task { }` does not inherit cancellation, which this project already records. So work
        // abandoned by the reader ran on with `Task.isCancelled == false`, and anything downstream
        // that asks — `ScreenRecordingAccess.ensure()`, which must not raise a permission dialog
        // for a hover nobody is waiting for — was told it was still wanted.
        //
        // The guard's contract is untouched. A capture that cannot be stopped still holds
        // `capturing` until it finishes, because the release is in the work's own `defer` and
        // ScreenCaptureKit does not honour cancellation anyway. All this changes is that the
        // abandoned work can now *find out* it was abandoned.
        defer { finished.cancel() }
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
        if let bundleID = selection.place.bundleID, policy.excludedApps.contains(bundleID) {
            return .excludedApp
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
        return Selection(
            text: hit.word.word, sentence: hit.word.sentence.text,
            rangeInSentence: hit.word.sentence.selection, quality: quality,
            place: ReadingPlace(bundleID: hit.bundleID, name: hit.appName))
    }

    private static func selection(from recognition: Recognition) -> Selection? {
        // The recogniser's own confidence, not 1. A reading at 0.5 is a guess, and the panel and
        // the ledger both have to be able to say so.
        guard let quality = CaptureQuality(
            source: .opticalRecognition,
            confidence: min(max(recognition.confidence, 0), 1),
            context: recognition.mayBeCut ? .mayBeCut : .complete)
        else { return nil }
        return Selection(
            text: recognition.word.word, sentence: recognition.word.sentence.text,
            rangeInSentence: recognition.word.sentence.selection, quality: quality,
            place: ReadingPlace(bundleID: recognition.bundleID, name: recognition.appName))
    }
}
