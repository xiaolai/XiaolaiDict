import Foundation

/// What the pointer and the keyboard did, as hover needs to know it. Built from AppKit's events by
/// the watcher, which is the only place that touches them.
public enum HoverEvent: Sendable, Equatable {
    case pointerMoved
    /// The hover modifiers now held, when the event says the change happened, and **where the
    /// pointer was then** — a global monitor delivers late, and the pointer read when it arrives
    /// may already be over another word. Nil where the event did not say.
    case modifiers(Set<HoverModifier>, at: TimeInterval, location: UpPoint?)
    /// Anything else the reader did — a key, a click, a scroll.
    case otherInput
}

/// One request to read the word under the pointer, from the moment the gesture was accepted.
public struct HoverIntent: Sendable, Equatable {
    /// This hover's own count, which tells a read's end from a stale one.
    public let serial: Int
    /// **The serial of the request this read continues** — its own for a fresh ask; the first ask's
    /// for a tap served after the read it waited for, or a rest asked again once a busy capture
    /// freed. The panel number and the time of asking belong to the origin: a re-ask that took a
    /// fresh number could claim the panel over a lookup the reader asked for in between.
    public let origin: Int
    /// A completed double tap rather than a rest.
    public let tapped: Bool
    /// The gesture and key the reader had chosen when this was asked. **Kept with the intent**, so a
    /// change of setting during the read cannot change whether it stands: a hold asked under `.hold`
    /// is still ended by letting go, even if the reader switched to the tap meanwhile.
    public let gesture: HoverGesture
    public let modifier: HoverModifier
    public let point: UpPoint
    public let held: Set<HoverModifier>
    public let stillFor: Duration
    public let acceptedAt: ContinuousClock.Instant
}

/// What the session asks its shell to do.
public enum HoverEffect: Sendable, Equatable {
    /// Arm the settle timer, replacing any armed one.
    case scheduleSettle
    /// Take a panel number for this request **now**, though it will be read later — a tap made
    /// during a read. Numbered when served, it could claim the panel over a lookup the reader asked
    /// for after the tap.
    case reserve(HoverIntent)
    case cancelSettle
    case ask(HoverIntent)
    /// Stop the read in flight. Its result is dropped when it ends; the drop says why.
    case cancelRead
    case deliver(HoverIntent)
    case drop(HoverIntent, HoverRefusal)
}

/// **The whole of hover's request lifecycle, as a value**: events in, effects out — the shape
/// `GestureRecogniser` set for the gesture alone.
///
/// The watcher used to hold this in its own fields, read AppKit and the clock directly, and decide
/// nothing about a read once it had started — so a result that arrived after the reader had moved
/// on, let go of the key, or asked for something else still opened a panel. What it owns:
///
/// - **Whether a request still stands when its read ends.** A hold stands while the modifier is
///   down and the pointer has not moved by `restTolerance` from where it was asked — the rule that
///   already restarts the dwell, so there is no second number. A completed double tap stands until
///   a newer request replaces it; requiring the key to stay down would make it a hold with extra
///   steps.
/// - **One read at a time, and what is owed when it ends.** A tap made during a read is the newest
///   request and wins: the read is cancelled and the tap is served when it ends, if that is within
///   `tapPatience` of the tap. A rest that arrived during a read, a dropped read, and a read refused
///   because a capture was busy are each owed a fresh ask from where the pointer is *then*, rather
///   than waiting for the pointer to twitch.
public struct HoverSession: Sendable {
    /// What the reader chose, read at each input so a change takes effect at once.
    public struct Settings: Sendable, Equatable {
        public let gesture: HoverGesture
        public let modifier: HoverModifier

        public init(gesture: HoverGesture, modifier: HoverModifier) {
            self.gesture = gesture
            self.modifier = modifier
        }
    }

    public enum Input: Sendable, Equatable {
        case start
        case stop
        /// Where the pointer is and what is held — after a movement, or after a modifier change.
        case pointer(UpPoint, held: Set<HoverModifier>)
        /// A modifier change with the event's own time, for the gesture rule; `pointer` is where it
        /// was made, which is where a tap asks.
        case modifiers(Set<HoverModifier>, at: TimeInterval, pointer: UpPoint)
        case otherInput
        /// The settle timer fired.
        case settled(UpPoint, held: Set<HoverModifier>)
        case readEnded(serial: Int, ReadEnd, pointer: UpPoint, held: Set<HoverModifier>)
        /// The one capture that may be in flight has finished.
        case captureReleased(UpPoint, held: Set<HoverModifier>)
    }

    /// How a read ended, as far as the lifecycle cares.
    public enum ReadEnd: Sendable, Equatable {
        case word
        case nothing
        /// Refused because a capture was already in flight.
        case captureBusy
    }

    /// How long a tap made during a read may wait for it. The reader is promised a panel within a
    /// second (`feature-ledger-ux.md` B3); a tap served later than that answers a question they
    /// may no longer be asking.
    public static let tapPatience: Duration = .seconds(1)

    /// How far a resting pointer may drift and still be resting. A pointer held on a word twitches
    /// by a point or two; counting that as movement restarts the dwell every time.
    public static let restTolerance: CGFloat = 2

    private struct Reading: Sendable {
        let intent: HoverIntent
        var dropped: HoverRefusal?
        /// Dropped by a stop: it owes nothing, even if watching has restarted before it ends.
        var stopped = false
    }

    private var watching = false
    private var gestures = GestureRecogniser()
    private var anchor = UpPoint.zero
    private var restingSince: ContinuousClock.Instant
    private var reading: Reading?
    private var pendingTap: HoverIntent?
    /// A fresh ask from the current pointer is owed when the read in flight ends.
    private var owed = false
    /// Where what is owed is the same request asked again — a rest refused for a busy capture — the
    /// request it continues.
    private var owedOrigin: Int?
    /// The last read was refused for a busy capture, and waits for it.
    private var waitingForCapture = false
    private var serials = 0
    /// The settle timer is armed. A twitch inside the rest tolerance leaves it alone: re-arming on
    /// every event let a hand that never quite settles push the timer back for ever.
    private var settleArmed = false
    /// What was held at the last pointer input, so a modifier change re-arms the timer.
    private var lastHeld: Set<HoverModifier> = []

    public init(now: ContinuousClock.Instant) {
        restingSince = now
    }

    /// The request in flight, if any. Read by the shell to tell a stale end from a live one.
    public var inFlight: HoverIntent? { reading?.intent }

    public mutating func handle(
        _ input: Input, settings: Settings, now: ContinuousClock.Instant
    ) -> [HoverEffect] {
        switch input {
        case .start:
            watching = true
            return []
        case .stop:
            return stop()
        case .readEnded(let serial, let end, let pointer, let held):
            return readEnded(serial: serial, end, pointer: pointer, held: held, settings: settings, now: now)
        case .captureReleased(let pointer, let held):
            waitingForCapture = false
            guard reading == nil else { return [] }
            return serve(pointer: pointer, held: held, settings: settings, now: now)
        case .otherInput:
            guard watching else { return [] }
            _ = gestures.saw(.otherInput, gesture: settings.gesture, modifier: settings.modifier)
            return []
        case .modifiers(let held, let instant, let pointer):
            guard watching else { return [] }
            return modifiersChanged(held, at: instant, pointer: pointer, settings: settings, now: now)
        case .pointer(let pointer, let held):
            guard watching else { return [] }
            return pointerMoved(to: pointer, held: held, now: now)
        case .settled(let pointer, let held):
            settleArmed = false
            guard watching else { return [] }
            guard reading == nil else {
                owed = true
                return []
            }
            // A rest while a blocked hold waits for the capture continues that hold, not a new one.
            let origin = waitingForCapture ? owedOrigin : nil
            return ask(intent(tapped: false, at: pointer, held: held, settings: settings, now: now, origin: origin))
        }
    }

    private mutating func modifiersChanged(
        _ held: Set<HoverModifier>, at instant: TimeInterval, pointer: UpPoint,
        settings: Settings, now: ContinuousClock.Instant
    ) -> [HoverEffect] {
        guard gestures.saw(.modifiers(held, at: instant), gesture: settings.gesture, modifier: settings.modifier)
        else { return [] }
        let tap = intent(tapped: true, at: pointer, held: held, settings: settings, now: now)
        guard var current = reading else {
            // **The newest tap wins over one still waiting** for a busy capture, too — and over a
            // rest owed an ask, which would otherwise be asked after it under its older number.
            pendingTap = nil
            owed = false
            owedOrigin = nil
            return ask(tap)
        }
        // **The newest request wins.** The read in flight is stopped and this tap waits for it.
        pendingTap = tap
        if current.dropped == nil { current.dropped = .superseded }
        reading = current
        return [.cancelRead, .reserve(tap)]
    }

    private mutating func pointerMoved(to pointer: UpPoint, held: Set<HoverModifier>, now: ContinuousClock.Instant) -> [HoverEffect] {
        let moved = Self.hasMoved(from: anchor, to: pointer)
        if moved {
            anchor = pointer
            restingSince = now
        }
        var effects: [HoverEffect] = []
        if var current = reading, current.dropped == nil,
           !Self.stands(current.intent, pointer: pointer, held: held) {
            current.dropped = .cancelled
            reading = current
            effects.append(.cancelRead)
        }
        // Re-armed on a genuine move or a change of key, and armed if nothing is — never for a twitch.
        if moved || held != lastHeld || !settleArmed {
            settleArmed = true
            effects.append(.scheduleSettle)
        }
        lastHeld = held
        return effects
    }

    /// Whether `intent` still stands with the pointer at `pointer` and `held` down.
    public static func stands(_ intent: HoverIntent, pointer: UpPoint, held: Set<HoverModifier>) -> Bool {
        // A tap has said what it wants; only a newer request replaces it. A rest under the
        // double-tap gesture never yields a word — the gate refuses it — so it has nothing to keep.
        guard !intent.tapped, intent.gesture == .hold else { return true }
        return held.contains(intent.modifier) && !hasMoved(from: intent.point, to: pointer)
    }

    /// True when the pointer has genuinely moved rather than drifted. Measured as a distance, not
    /// per axis: a pointer sliding along a diagonal moves less than the tolerance on either axis
    /// while going further than it on both.
    public static func hasMoved(from: UpPoint, to: UpPoint, tolerance: CGFloat = restTolerance) -> Bool {
        hypot(to.cg.x - from.cg.x, to.cg.y - from.cg.y) > tolerance
    }

    // MARK: - Steps

    private mutating func stop() -> [HoverEffect] {
        watching = false
        gestures.reset()
        settleArmed = false
        pendingTap = nil
        owed = false
        owedOrigin = nil
        waitingForCapture = false
        var effects: [HoverEffect] = [.cancelSettle]
        if var current = reading {
            if current.dropped == nil { current.dropped = .cancelled }
            current.stopped = true
            reading = current
            effects.append(.cancelRead)
        }
        return effects
    }

    private mutating func readEnded(
        serial: Int, _ end: ReadEnd, pointer: UpPoint, held: Set<HoverModifier>,
        settings: Settings, now: ContinuousClock.Instant
    ) -> [HoverEffect] {
        guard let ended = reading, ended.intent.serial == serial else { return [] }
        reading = nil
        var effects: [HoverEffect] = []
        switch end {
        case .word:
            if let reason = ended.dropped {
                effects.append(.drop(ended.intent, reason))
            } else if !Self.stands(ended.intent, pointer: pointer, held: held) {
                effects.append(.drop(ended.intent, .cancelled))
                // Owed a fresh ask from where the pointer is now — or the reader who stayed on the
                // new word with the key down would wait for a twitch.
                owed = true
            } else {
                effects.append(.deliver(ended.intent))
            }
        case .nothing:
            break
        case .captureBusy:
            // **Nothing is owed by a read that ended after a stop**: what it would owe is exactly
            // what stopping cleared, and a capture freed after a restart would serve it.
            guard watching, !ended.stopped else { break }
            waitingForCapture = true
            if ended.dropped == nil {
                // The ended tap is the newest: a tap waiting already was replaced when it was asked.
                if ended.intent.tapped {
                    pendingTap = ended.intent
                } else {
                    owed = true
                    owedOrigin = ended.intent.origin
                }
            }
        }
        if ended.dropped != nil, watching, !ended.stopped { owed = true }
        guard watching, !waitingForCapture else { return effects }
        return effects + serve(pointer: pointer, held: held, settings: settings, now: now)
    }

    /// Whatever is owed, now that nothing is in flight: a waiting tap first, then a fresh rest.
    private mutating func serve(
        pointer: UpPoint, held: Set<HoverModifier>, settings: Settings, now: ContinuousClock.Instant
    ) -> [HoverEffect] {
        guard watching else { return [] }
        if let tap = pendingTap {
            pendingTap = nil
            owed = false
            owedOrigin = nil
            guard now - tap.acceptedAt <= Self.tapPatience else { return [.drop(tap, .cancelled)] }
            // Asked again under a serial of its own, from the point where it was made.
            return ask(HoverIntent(
                serial: nextSerial(), origin: tap.origin, tapped: true, gesture: tap.gesture, modifier: tap.modifier,
                point: tap.point, held: tap.held, stillFor: tap.stillFor, acceptedAt: tap.acceptedAt))
        }
        guard owed else { return [] }
        owed = false
        let origin = owedOrigin
        owedOrigin = nil
        return ask(intent(tapped: false, at: pointer, held: held, settings: settings, now: now, origin: origin))
    }

    private mutating func ask(_ intent: HoverIntent) -> [HoverEffect] {
        reading = Reading(intent: intent, dropped: nil)
        return [.ask(intent)]
    }

    private mutating func intent(
        tapped: Bool, at pointer: UpPoint, held: Set<HoverModifier>, settings: Settings,
        now: ContinuousClock.Instant, origin: Int? = nil
    ) -> HoverIntent {
        let serial = nextSerial()
        return HoverIntent(
            serial: serial, origin: origin ?? serial, tapped: tapped, gesture: settings.gesture,
            modifier: settings.modifier, point: pointer, held: held, stillFor: now - restingSince, acceptedAt: now)
    }

    private mutating func nextSerial() -> Int {
        serials += 1
        return serials
    }
}
