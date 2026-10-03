import Foundation
import Testing
@testable import XiaolaiDictCore

/// **Hover's request lifecycle, driven by event sequences** — no clock, no screen, no AppKit.
///
/// The defect this exists for: a hover result that arrived late opened a panel anyway — after the
/// pointer had left, after the key came up, over a lookup the reader asked for meanwhile — because
/// nothing decided anything about a read once it had started.
struct HoverSessionTests {
    private static let hold = HoverSession.Settings(gesture: .hold, modifier: .option)
    private static let tap = HoverSession.Settings(gesture: .doubleTap, modifier: .option)
    private static let origin = ContinuousClock.now
    private static let word = UpPoint(x: 100, y: 100)
    private static let elsewhere = UpPoint(x: 160, y: 100)

    private final class Driver {
        var session = HoverSession(now: HoverSessionTests.origin)
        var settings: HoverSession.Settings
        var elapsed: Duration = .zero

        init(_ settings: HoverSession.Settings) {
            self.settings = settings
            _ = session.handle(.start, settings: settings, now: HoverSessionTests.origin)
        }

        func feed(_ input: HoverSession.Input, after step: Duration = .milliseconds(10)) -> [HoverEffect] {
            elapsed += step
            return session.handle(input, settings: settings, now: HoverSessionTests.origin + elapsed)
        }

        /// A rest under hold: the pointer arrives with ⌥ down and the settle timer fires.
        func rest(at point: UpPoint) -> HoverIntent? {
            _ = feed(.pointer(point, held: [.option]))
            return Self.asked(feed(.settled(point, held: [.option]), after: .milliseconds(200)))
        }

        /// Down, up, down inside the tap window, at `point`.
        func doubleTap(at point: UpPoint, from instant: TimeInterval) -> [HoverEffect] {
            _ = feed(.modifiers([.option], at: instant, pointer: point))
            _ = feed(.modifiers([], at: instant + 0.08, pointer: point))
            return feed(.modifiers([.option], at: instant + 0.2, pointer: point))
        }

        static func asked(_ effects: [HoverEffect]) -> HoverIntent? {
            for case .ask(let intent) in effects { return intent }
            return nil
        }
    }

    // MARK: - Hold

    @Test func aHoldThatStillStandsIsDelivered() throws {
        let driver = Driver(Self.hold)
        let intent = try #require(driver.rest(at: Self.word))
        let ended = driver.feed(.readEnded(serial: intent.serial, .word, pointer: Self.word, held: [.option]))
        #expect(ended == [.deliver(intent)])
    }

    /// Red if `.pointer` stops applying `stands` to the read in flight.
    @Test func aHoldIsDroppedWhenThePointerLeaves() throws {
        let driver = Driver(Self.hold)
        let intent = try #require(driver.rest(at: Self.word))
        let moved = driver.feed(.pointer(Self.elsewhere, held: [.option]))
        #expect(moved.contains(.cancelRead), "the read went on for a word the reader left")
        let ended = driver.feed(.readEnded(serial: intent.serial, .word, pointer: Self.elsewhere, held: [.option]))
        #expect(ended.first == .drop(intent, .cancelled))
        #expect(!ended.contains(.deliver(intent)))
    }

    /// Red if `stands` stops asking whether the modifier is still down.
    @Test func aHoldIsDroppedWhenTheModifierComesUp() throws {
        let driver = Driver(Self.hold)
        let intent = try #require(driver.rest(at: Self.word))
        let released = driver.feed(.pointer(Self.word, held: []))
        #expect(released.contains(.cancelRead))
        let ended = driver.feed(.readEnded(serial: intent.serial, .word, pointer: Self.word, held: []))
        #expect(ended.first == .drop(intent, .cancelled))
    }

    /// A twitch inside the rest tolerance is not leaving. Red if the tolerance is dropped.
    @Test func aTwitchDoesNotDropAHold() throws {
        let driver = Driver(Self.hold)
        let intent = try #require(driver.rest(at: Self.word))
        let twitch = UpPoint(x: 101, y: 99)
        #expect(!driver.feed(.pointer(twitch, held: [.option])).contains(.cancelRead))
        let ended = driver.feed(.readEnded(serial: intent.serial, .word, pointer: twitch, held: [.option]))
        #expect(ended.first == .deliver(intent))
    }

    /// Without a cancellation in flight, the result is still judged when it arrives: the pointer
    /// may have moved between the last event and the end.
    @Test func standingIsJudgedAgainAtTheEnd() throws {
        let driver = Driver(Self.hold)
        let intent = try #require(driver.rest(at: Self.word))
        let ended = driver.feed(.readEnded(serial: intent.serial, .word, pointer: Self.elsewhere, held: [.option]))
        #expect(ended.first == .drop(intent, .cancelled))
    }

    // MARK: - Double tap

    /// A tap says what it wants; letting go of the key and moving off do not withdraw it.
    @Test func aDoubleTapIsDeliveredAfterTheKeyIsUpAndThePointerHasMoved() throws {
        let driver = Driver(Self.tap)
        let intent = try #require(Driver.asked(driver.doubleTap(at: Self.word, from: 10)))
        #expect(intent.tapped)
        _ = driver.feed(.modifiers([], at: 10.3, pointer: Self.word))
        #expect(!driver.feed(.pointer(Self.elsewhere, held: [])).contains(.cancelRead))
        let ended = driver.feed(.readEnded(serial: intent.serial, .word, pointer: Self.elsewhere, held: []))
        #expect(ended.first == .deliver(intent))
    }

    /// **Newest wins.** The first read is stopped and dropped as superseded, and the second tap is
    /// asked with its own point once the first has ended. Red if a tap during a read is ignored —
    /// which is what the watcher did: `.captureInFlight`, and the first tap's panel.
    @Test func aSecondTapReplacesTheFirstAndIsAskedWithItsOwnPoint() throws {
        let driver = Driver(Self.tap)
        let first = try #require(Driver.asked(driver.doubleTap(at: Self.word, from: 10)))
        _ = driver.feed(.modifiers([], at: 10.3, pointer: Self.word))
        let second = driver.doubleTap(at: Self.elsewhere, from: 11)
        // Stopped, and **its number reserved now** — the tap is the newer request from this moment,
        // not from whenever the first read lets go.
        #expect(second.first == .cancelRead)
        guard case .reserve(let reserved)? = second.last, second.count == 2 else {
            Issue.record("the second tap was not reserved: \(second)")
            return
        }
        let ended = driver.feed(.readEnded(serial: first.serial, .word, pointer: Self.elsewhere, held: []))
        #expect(ended.first == .drop(first, .superseded))
        let asked = try #require(Driver.asked(ended))
        #expect(asked.point == Self.elsewhere)
        #expect(asked.tapped)
        #expect(asked.serial != first.serial)
        #expect(asked.origin == reserved.origin, "the tap was asked under a number other than the one it reserved")
    }

    /// The tap waits at most a second for the read it replaced. Red if `tapPatience` is not checked.
    @Test func aTapThatWaitedTooLongIsDroppedNotServed() throws {
        let driver = Driver(Self.tap)
        let first = try #require(Driver.asked(driver.doubleTap(at: Self.word, from: 10)))
        _ = driver.feed(.modifiers([], at: 10.3, pointer: Self.word))
        _ = driver.doubleTap(at: Self.elsewhere, from: 11)
        let ended = driver.feed(
            .readEnded(serial: first.serial, .word, pointer: Self.elsewhere, held: []), after: .seconds(2))
        #expect(Driver.asked(ended) == nil, "a tap was served two seconds late")
        #expect(ended.contains { if case .drop(_, .cancelled) = $0 { true } else { false } })
    }

    // MARK: - Stop

    /// Red if `stop` stops cancelling the read, or a late end can still ask.
    @Test func stoppingMidReadDropsTheResultAndAsksNothing() throws {
        let driver = Driver(Self.hold)
        let intent = try #require(driver.rest(at: Self.word))
        let stopped = driver.feed(.stop)
        #expect(stopped.contains(.cancelRead))
        #expect(stopped.contains(.cancelSettle))
        let ended = driver.feed(.readEnded(serial: intent.serial, .word, pointer: Self.word, held: [.option]))
        #expect(ended == [.drop(intent, .cancelled)])
        #expect(driver.feed(.captureReleased(Self.word, held: [.option])).isEmpty)
        #expect(driver.feed(.settled(Self.word, held: [.option])).isEmpty)
    }

    // MARK: - What is owed

    /// **A rest refused because a capture was busy is asked again when it is released**, from where
    /// the pointer is then. Red if `captureReleased` stops serving what is owed.
    @Test func aBlockedReadIsAskedAgainOnRelease() throws {
        let driver = Driver(Self.hold)
        let intent = try #require(driver.rest(at: Self.word))
        let ended = driver.feed(.readEnded(serial: intent.serial, .captureBusy, pointer: Self.word, held: [.option]))
        #expect(Driver.asked(ended) == nil, "asked again while the capture was still busy")
        let released = driver.feed(.captureReleased(Self.word, held: [.option]))
        let again = try #require(Driver.asked(released))
        #expect(again.point == Self.word)
        #expect(!again.tapped)
    }

    /// A blocked tap is asked again on release too, as a tap and at its own point.
    @Test func aBlockedTapIsServedOnRelease() throws {
        let driver = Driver(Self.tap)
        let intent = try #require(Driver.asked(driver.doubleTap(at: Self.word, from: 10)))
        _ = driver.feed(.readEnded(serial: intent.serial, .captureBusy, pointer: Self.elsewhere, held: []))
        let again = try #require(Driver.asked(driver.feed(.captureReleased(Self.elsewhere, held: []))))
        #expect(again.tapped)
        #expect(again.point == Self.word)
    }

    /// A rest that arrived during a read is served when it ends, without waiting for a twitch.
    @Test func aRestDuringAReadIsAskedWhenItEnds() throws {
        let driver = Driver(Self.hold)
        let intent = try #require(driver.rest(at: Self.word))
        #expect(driver.feed(.settled(Self.word, held: [.option])).isEmpty)
        let ended = driver.feed(.readEnded(serial: intent.serial, .nothing, pointer: Self.word, held: [.option]))
        #expect(Driver.asked(ended) != nil)
    }

    /// An end for a serial that is not in flight changes nothing.
    @Test func aStaleEndIsIgnored() throws {
        let driver = Driver(Self.hold)
        let intent = try #require(driver.rest(at: Self.word))
        #expect(driver.feed(.readEnded(serial: intent.serial + 7, .word, pointer: Self.word, held: [.option])).isEmpty)
        #expect(driver.session.inFlight == intent)
    }

    /// The tap is measured from its completing press, and the rest from the anchor, as before.
    @Test func stillnessIsMeasuredFromTheLastRealMove() throws {
        let driver = Driver(Self.hold)
        _ = driver.feed(.pointer(Self.word, held: [.option]))
        _ = driver.feed(.pointer(UpPoint(x: 101, y: 100), held: [.option]), after: .milliseconds(100))
        let intent = try #require(Driver.asked(driver.feed(.settled(Self.word, held: [.option]), after: .milliseconds(200))))
        #expect(intent.stillFor == .milliseconds(300), "a twitch restarted the rest")
    }
}

/// The panel's request numbers.
struct RequestSequenceTests {
    /// **The race this closes.** A hover is given its number when the gesture is accepted; a
    /// shortcut lookup claims the panel while the hover is still reading; the hover's late claim
    /// is refused. Red if `claim` stops comparing against the floor.
    @Test func aLaterClaimSupersedesAnEarlierBegin() {
        var sequence = RequestSequence()
        let hover = sequence.begin()
        let shortcut = sequence.next()
        let claimed = sequence.claim(hover)
        #expect(!claimed, "the late hover took the panel from the shortcut's lookup")
        #expect(sequence.isCurrent(shortcut))
    }

    /// Handing out a number supersedes nothing. A twitch that ends `.samePlace` must not end the
    /// panel on screen.
    @Test func beginningDoesNotSupersedeThePanelOnScreen() {
        var sequence = RequestSequence()
        let shown = sequence.next()
        _ = sequence.begin()
        _ = sequence.begin()
        #expect(sequence.isCurrent(shown))
    }

    @Test func aNewerGestureStillWins() {
        var sequence = RequestSequence()
        let shown = sequence.next()
        let hover = sequence.begin()
        let claimed = sequence.claim(hover)
        #expect(claimed)
        #expect(!sequence.isCurrent(shown))
        #expect(sequence.isCurrent(hover))
    }

    /// Closing supersedes every number handed out, so a result that arrives late is not reopened
    /// over the reader's dismissal.
    @Test func closingSupersedesEverythingHandedOut() {
        var sequence = RequestSequence()
        let pending = sequence.begin()
        let shown = sequence.next()
        sequence.close()
        #expect(!sequence.isCurrent(shown))
        let late = sequence.claim(pending)
        #expect(!late)
        let fresh = sequence.begin()
        let freshClaimed = sequence.claim(fresh)
        #expect(freshClaimed)
    }

    @Test func aNumberNeverHandedOutCannotClaim() {
        var sequence = RequestSequence()
        let unissued = sequence.claim(1)
        let zero = sequence.claim(0)
        #expect(!unissued)
        #expect(!zero)
    }
}

/// Findings from the first audit-fix round.
struct HoverSessionAuditTests {
    private static let hold = HoverSession.Settings(gesture: .hold, modifier: .option)
    private static let tap = HoverSession.Settings(gesture: .doubleTap, modifier: .option)
    private static let origin = ContinuousClock.now
    private static let word = UpPoint(x: 100, y: 100)

    /// **A twitch does not re-arm the settle timer**, so a hand that never quite settles is still
    /// served. Red if every pointer event schedules.
    @Test func aTwitchDoesNotRearmTheTimer() {
        var session = HoverSession(now: Self.origin)
        _ = session.handle(.start, settings: Self.hold, now: Self.origin)
        let first = session.handle(.pointer(Self.word, held: [.option]), settings: Self.hold, now: Self.origin)
        #expect(first.contains(.scheduleSettle))
        let twitch = session.handle(.pointer(UpPoint(x: 101, y: 100), held: [.option]), settings: Self.hold, now: Self.origin)
        #expect(!twitch.contains(.scheduleSettle), "a twitch pushed the timer back")
        let released = session.handle(.pointer(UpPoint(x: 101, y: 100), held: []), settings: Self.hold, now: Self.origin)
        #expect(released.contains(.scheduleSettle), "a change of key did not re-arm the timer")
    }

    /// **A hold keeps its own gesture.** The reader switches to the tap during the read; the hold
    /// is still ended by letting go. Red if `stands` reads the current settings.
    @Test func aChangeOfGestureDoesNotKeepAHoldAlive() throws {
        var session = HoverSession(now: Self.origin)
        _ = session.handle(.start, settings: Self.hold, now: Self.origin)
        _ = session.handle(.pointer(Self.word, held: [.option]), settings: Self.hold, now: Self.origin)
        let asked = session.handle(.settled(Self.word, held: [.option]), settings: Self.hold, now: Self.origin + .seconds(1))
        guard case .ask(let intent)? = asked.first else { Issue.record("not asked"); return }
        let ended = session.handle(.readEnded(serial: intent.serial, .word, pointer: Self.word, held: []),
                                   settings: Self.tap, now: Self.origin + .seconds(1))
        #expect(ended.first == .drop(intent, .cancelled), "a hold delivered after the key came up")
    }

    /// **The newest tap waits for a busy capture**, not an older one. Red if the older tap is kept.
    @Test func theNewestTapWaitsForTheCapture() throws {
        var session = HoverSession(now: Self.origin)
        _ = session.handle(.start, settings: Self.tap, now: Self.origin)
        func tap(_ at: TimeInterval, _ point: UpPoint) -> [HoverEffect] {
            _ = session.handle(.modifiers([], at: at - 0.05, pointer: point), settings: Self.tap, now: Self.origin)
            _ = session.handle(.modifiers([.option], at: at, pointer: point), settings: Self.tap, now: Self.origin)
            _ = session.handle(.modifiers([], at: at + 0.05, pointer: point), settings: Self.tap, now: Self.origin)
            return session.handle(.modifiers([.option], at: at + 0.1, pointer: point), settings: Self.tap, now: Self.origin)
        }
        guard case .ask(let first)? = tap(1, Self.word).first else { Issue.record("not asked"); return }
        _ = session.handle(.readEnded(serial: first.serial, .captureBusy, pointer: Self.word, held: []), settings: Self.tap, now: Self.origin)
        let newer = UpPoint(x: 300, y: 300)
        guard case .ask(let second)? = tap(2, newer).first else { Issue.record("the newer tap was not asked"); return }
        _ = session.handle(.readEnded(serial: second.serial, .captureBusy, pointer: newer, held: []), settings: Self.tap, now: Self.origin)
        let released = session.handle(.captureReleased(newer, held: []), settings: Self.tap, now: Self.origin)
        guard case .ask(let served)? = released.first else { Issue.record("nothing served"); return }
        #expect(served.point == newer, "the older tap was served")
    }

    /// **An older tap is not served after a newer one was answered.** The first tap waits for a busy
    /// capture; the second is read through Accessibility and delivered; when the capture frees,
    /// nothing is asked — the older word must not replace the newer. Red if a tap asked while one
    /// waits leaves the waiting one in place.
    @Test func anOlderTapIsDroppedOnceANewerOneIsAnswered() throws {
        var session = HoverSession(now: Self.origin)
        _ = session.handle(.start, settings: Self.tap, now: Self.origin)
        func tap(_ at: TimeInterval, _ point: UpPoint) -> [HoverEffect] {
            _ = session.handle(.modifiers([], at: at - 0.05, pointer: point), settings: Self.tap, now: Self.origin)
            _ = session.handle(.modifiers([.option], at: at, pointer: point), settings: Self.tap, now: Self.origin)
            _ = session.handle(.modifiers([], at: at + 0.05, pointer: point), settings: Self.tap, now: Self.origin)
            return session.handle(.modifiers([.option], at: at + 0.1, pointer: point), settings: Self.tap, now: Self.origin)
        }
        guard case .ask(let first)? = tap(1, Self.word).first else { Issue.record("not asked"); return }
        _ = session.handle(.readEnded(serial: first.serial, .captureBusy, pointer: Self.word, held: []), settings: Self.tap, now: Self.origin)
        let newer = UpPoint(x: 300, y: 300)
        guard case .ask(let second)? = tap(2, newer).first else { Issue.record("the newer tap was not asked"); return }
        let delivered = session.handle(.readEnded(serial: second.serial, .word, pointer: newer, held: []), settings: Self.tap, now: Self.origin)
        #expect(delivered.first == .deliver(second))
        let released = session.handle(.captureReleased(newer, held: []), settings: Self.tap, now: Self.origin)
        #expect(released.isEmpty, "the older tap was served after the newer one was answered")
    }
}

/// Findings from the second audit-fix round.
struct HoverSessionRoundTwoTests {
    private static let hold = HoverSession.Settings(gesture: .hold, modifier: .option)
    private static let tap = HoverSession.Settings(gesture: .doubleTap, modifier: .option)
    private static let origin = ContinuousClock.now
    private static let word = UpPoint(x: 100, y: 100)

    private static func rested() -> (HoverSession, HoverIntent?) {
        var session = HoverSession(now: origin)
        _ = session.handle(.start, settings: hold, now: origin)
        _ = session.handle(.pointer(word, held: [.option]), settings: hold, now: origin)
        let asked = session.handle(.settled(word, held: [.option]), settings: hold, now: origin + .seconds(1))
        guard case .ask(let intent)? = asked.first else { return (session, nil) }
        return (session, intent)
    }

    /// **A rest asked again once a busy capture frees continues the same request.** Its origin is
    /// the first ask's, so it keeps that panel number. Red if the re-ask is a fresh origin.
    @Test func aBlockedRestKeepsItsOrigin() throws {
        var (session, first) = Self.rested()
        let intent = try #require(first)
        _ = session.handle(.readEnded(serial: intent.serial, .captureBusy, pointer: Self.word, held: [.option]), settings: Self.hold, now: Self.origin)
        let released = session.handle(.captureReleased(Self.word, held: [.option]), settings: Self.hold, now: Self.origin)
        guard case .ask(let again)? = released.first else { Issue.record("not asked again"); return }
        #expect(again.origin == intent.origin, "a re-ask took a new origin, and with it a newer number")
        first = nil
    }

    /// **A tap started outright supersedes what an older rest was owed** (audit round 3, #44). The
    /// rest blocked on a busy capture kept its owed ask and its origin, and the capture freeing after
    /// the tap asked it again — under the older number, behind the tap the reader made since.
    @Test func aTapStartedOutrightClearsAnOlderOwedRest() throws {
        var session = HoverSession(now: Self.origin)
        _ = session.handle(.start, settings: Self.tap, now: Self.origin)
        _ = session.handle(.pointer(Self.word, held: []), settings: Self.tap, now: Self.origin)
        let rested = session.handle(.settled(Self.word, held: []), settings: Self.tap, now: Self.origin + .seconds(1))
        guard case .ask(let rest)? = rested.first else { Issue.record("the rest was not asked"); return }
        _ = session.handle(.readEnded(serial: rest.serial, .captureBusy, pointer: Self.word, held: []), settings: Self.tap, now: Self.origin + .seconds(1))
        _ = session.handle(.modifiers([.option], at: 10, pointer: Self.word), settings: Self.tap, now: Self.origin + .seconds(2))
        _ = session.handle(.modifiers([], at: 10.08, pointer: Self.word), settings: Self.tap, now: Self.origin + .seconds(2))
        let tapped = session.handle(.modifiers([.option], at: 10.2, pointer: Self.word), settings: Self.tap, now: Self.origin + .seconds(2))
        guard case .ask(let tap)? = tapped.first else { Issue.record("the tap was not asked: \(tapped)"); return }
        _ = session.handle(.readEnded(serial: tap.serial, .word, pointer: Self.word, held: []), settings: Self.tap, now: Self.origin + .seconds(2))
        let released = session.handle(.captureReleased(Self.word, held: []), settings: Self.tap, now: Self.origin + .seconds(3))
        for case .ask(let stale) in released {
            #expect(stale.origin != rest.origin, "the superseded rest was asked again under its older number")
        }
    }

    /// **A hold that no longer stands when it ends is owed a fresh ask** from where the pointer is.
    @Test func aHoldDroppedAtItsEndIsFollowedByAFreshAsk() throws {
        var (session, first) = Self.rested()
        let intent = try #require(first)
        let elsewhere = UpPoint(x: 300, y: 100)
        let ended = session.handle(.readEnded(serial: intent.serial, .word, pointer: elsewhere, held: [.option]), settings: Self.hold, now: Self.origin)
        #expect(ended.first == .drop(intent, .cancelled))
        guard case .ask(let fresh)? = ended.dropFirst().first else { Issue.record("the reader waited for a twitch"); return }
        #expect(fresh.point == elsewhere)
        first = nil
    }

    /// **A read that ends after a stop owes nothing**, so a capture freed after a restart serves
    /// nothing stale. Red if the read's end re-sets what stopping cleared.
    @Test func aReadEndingAfterAStopOwesNothing() throws {
        var (session, first) = Self.rested()
        let intent = try #require(first)
        _ = session.handle(.stop, settings: Self.hold, now: Self.origin)
        _ = session.handle(.readEnded(serial: intent.serial, .captureBusy, pointer: Self.word, held: [.option]), settings: Self.hold, now: Self.origin)
        _ = session.handle(.start, settings: Self.hold, now: Self.origin)
        #expect(session.handle(.captureReleased(Self.word, held: [.option]), settings: Self.hold, now: Self.origin).isEmpty)
        first = nil
    }
}

struct SiteHostRoundTwoTests {
    /// **A Unicode name is stored as the IDNA name a page reports**, and an IPv6 literal is a host.
    @Test func internationalAndIPv6HostsAreReadAsPagesReportThem() {
        #expect(HoverPolicy.siteHost(fromTyped: "bücher.de") == "xn--bcher-kva.de")
        #expect(HoverPolicy.siteHost(fromTyped: "https://[::1]/page") == "::1")
        #expect(HoverPolicy.siteHost(fromTyped: "-.com") == nil)
        let policy = HoverPolicy(modifier: .option, excludedApps: [], excludedHosts: ["bücher.de"], settleMilliseconds: 0)
        #expect(policy.refuses(.known("xn--bcher-kva.de")), "a Unicode exclusion did not match its own page")
    }
    /// **A colon is an IPv6 literal or a port, and nothing else** (audit round 3, #41). Malformed input
    /// holding one was stored as typed — an exclusion no page's host could ever equal.
    @Test func aColonIsAPortOrAnIPv6LiteralAndNothingElse() {
        #expect(HoverPolicy.siteHost(fromTyped: "example.com:443") == "example.com")
        #expect(HoverPolicy.siteHost(fromTyped: "[2001:db8::1]:8443") == "2001:db8::1")
        #expect(HoverPolicy.siteHost(fromTyped: "2001:db8::1") == "2001:db8::1")
        for malformed in ["example.com:abc", "a:b", ":::", "1:2:3"] {
            #expect(HoverPolicy.siteHost(fromTyped: malformed) == nil, "\(malformed) was stored as a host")
        }
    }
}

struct PointerWindowRoundTwoTests {
    /// **Any window of ours at the point counts**, under another app's too — a click-through overlay
    /// can sit above our panel while Accessibility's hit test goes through to it.
    @Test func ourPanelUnderAnotherAppsWindowIsStillOurs() {
        let point = CGPoint(x: 10, y: 10)
        let overlay = ListedWindow(pid: 50, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 20)
        let panel = ListedWindow(pid: 99, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), layer: 3)
        #expect(PointerWindow.ours(at: point, in: [overlay, panel], ours: 99))
        #expect(!PointerWindow.ours(at: point, in: [overlay], ours: 99))
    }
}
