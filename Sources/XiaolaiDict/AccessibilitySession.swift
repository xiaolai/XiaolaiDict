import ApplicationServices
import Synchronization
import XiaolaiDictBase
import os

/// Why a selection could not be read. Kept apart, because each needs a different answer for the
/// reader: "try again", "grant access" and "nothing is selected" are not the same message.
enum CaptureError: Error, Equatable {
    /// The app did not answer one request within the messaging timeout: busy or hung.
    case notResponding
    /// The read as a whole ran past its deadline, one slow answer after another.
    case deadlineExceeded
    /// Accessibility is off for XiaolaiDict.
    case accessibilityDisabled
    /// The app quit, or no longer answers for the process XiaolaiDict asked.
    case appUnavailable
    /// The app's Accessibility refused outright (`kAXErrorFailure` on the app itself) — what a
    /// locked screen looks like (screen-word spike, finding 11).
    case accessibilityRefused
    /// A newer lookup replaced this one.
    case cancelled
}

/// Everything the selection reader asks of Accessibility — the seam tests replace. Every read is
/// typed: a value of the wrong type is an absent one.
protocol AccessibilityReading {
    func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef?
    func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef?
    /// Asks Electron to build its Accessibility tree. Every other app ignores it.
    func wake(_ application: AXUIElement) throws(CaptureError)
    /// Tells the app an assistive client is reading it — what Chrome needs before it builds a page tree.
    /// **Heavier than `wake`**: the app builds its whole tree, so it is asked only of an app that
    /// answered nothing (`ScreenWordReader.read`).
    func enhance(_ application: AXUIElement) throws(CaptureError)
}

extension AccessibilityReading {
    /// A test's client has no tree to build.
    func wake(_ application: AXUIElement) throws(CaptureError) {}
    func enhance(_ application: AXUIElement) throws(CaptureError) {}

    func element(_ element: AXUIElement, _ name: String, ofApplication: Bool = false) throws(CaptureError) -> AXUIElement? {
        cast(try attribute(element, name, ofApplication: ofApplication), AXUIElementGetTypeID(), as: AXUIElement.self)
    }

    func elements(_ element: AXUIElement, _ name: String) throws(CaptureError) -> [AXUIElement] {
        guard let list = try attribute(element, name, ofApplication: false) as? [CFTypeRef] else { return [] }
        return list.compactMap { cast($0, AXUIElementGetTypeID(), as: AXUIElement.self) }
    }

    func string(_ element: AXUIElement, _ name: String) throws(CaptureError) -> String? {
        try attribute(element, name, ofApplication: false) as? String
    }

    func string(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> String? {
        try parameterized(element, name, argument) as? String
    }

    func integer(_ element: AXUIElement, _ name: String) throws(CaptureError) -> Int? {
        try attribute(element, name, ofApplication: false) as? Int
    }

    func integer(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> Int? {
        try parameterized(element, name, argument) as? Int
    }

    func range(_ element: AXUIElement, _ name: String) throws(CaptureError) -> CFRange? {
        decodedRange(try attribute(element, name, ofApplication: false))
    }

    func marker(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> AXTextMarker? {
        cast(try parameterized(element, name, argument), AXTextMarkerGetTypeID(), as: AXTextMarker.self)
    }

    func markerRange(_ element: AXUIElement, _ name: String) throws(CaptureError) -> AXTextMarkerRange? {
        cast(try attribute(element, name, ofApplication: false), AXTextMarkerRangeGetTypeID(), as: AXTextMarkerRange.self)
    }

    func markerRange(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> AXTextMarkerRange? {
        cast(try parameterized(element, name, argument), AXTextMarkerRangeGetTypeID(), as: AXTextMarkerRange.self)
    }

    func range(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFRange? {
        decodedRange(try parameterized(element, name, argument))
    }

    /// A range out of whatever came back: an `AXValue` of the range type, or nothing.
    private func decodedRange(_ value: CFTypeRef?) -> CFRange? {
        guard let value = cast(value, AXValueGetTypeID(), as: AXValue.self) else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    func rect(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CGRect? {
        guard let value = cast(try parameterized(element, name, argument), AXValueGetTypeID(), as: AXValue.self) else {
            return nil
        }
        var rect = CGRect.zero
        return AXValueGetValue(value, .cgRect, &rect) ? rect : nil
    }

    /// Parents walked up from an element to the page containing it. A browser's web area sits a
    /// few levels under toolbars and tab groups; a tree deeper than this is one with no page in it.
    static var webAreaAncestorLimit: Int { 40 }

    /// The web area containing `element`, walking up its parents — the page a word was read on.
    ///
    /// **One walk, for the selection path and the hover path alike.** There were two, with the same
    /// algorithm and the same bound, and only one of them refused an element that reports itself as
    /// its own parent — so on the hover path such an element cost forty rounds of synchronous
    /// Accessibility IPC before the bound stopped it. The guard is what makes the bound the worst
    /// case rather than the usual one.
    func webArea(containing element: AXUIElement) throws(CaptureError) -> AXUIElement? {
        guard case .page(let area) = try walkToPage(from: element) else { return nil }
        return area
    }

    /// The walk itself, **saying how it ended** — the one traversal both callers share (audit round 3,
    /// #34). The selection and marker paths want a page or nothing; the site check must not mistake a
    /// walk that stopped short for one that reached the application, because "no page" lets an
    /// excluded site through. Each applies its own policy to the answer rather than walking again.
    func walkToPage(from element: AXUIElement) throws(CaptureError) -> PageWalk {
        var current = element
        for _ in 0..<Self.webAreaAncestorLimit {
            switch try string(current, kAXRoleAttribute) {
            case "AXWebArea": return .page(current)
            case kAXApplicationRole: return .application
            default: break
            }
            guard let parent = try self.element(current, kAXParentAttribute), parent != current else { return .stoppedShort }
            current = parent
        }
        return .stoppedShort
    }

    /// A CF value as `type`, checked by type ID first: `as?` on a CF type always succeeds.
    private func cast<T>(_ value: CFTypeRef?, _ typeID: CFTypeID, as _: T.Type) -> T? {
        guard let value, CFGetTypeID(value) == typeID else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! T)
    }
}

/// Where a walk up from an element towards its page ended.
enum PageWalk {
    case page(AXUIElement)
    /// Reached the application without passing a web area: there is no page.
    case application
    /// A parent could not be read, or the bound ran out — **not** "no page".
    case stoppedShort
}

/// The two raw Accessibility requests — the seam that lets a test count them.
struct AccessibilityRequests: Sendable {
    var attribute: @Sendable (AXUIElement, String) -> (AXError, CFTypeRef?)
    var parameterized: @Sendable (AXUIElement, String, CFTypeRef) -> (AXError, CFTypeRef?)
    /// `AXManualAccessibility`, which wakes an Electron tree. **Not Chrome's**: measured 2026-10-03,
    /// Chrome refuses it as unsupported and builds no page tree for it.
    var wake: @Sendable (AXUIElement) -> AXError = { _ in .success }
    /// `AXEnhancedUserInterface`, which Chrome does honour — answering "not implemented" while it
    /// builds the tree anyway, about two seconds later.
    var enhance: @Sendable (AXUIElement) -> AXError = { _ in .success }

    static let system = AccessibilityRequests(
        attribute: { element, name in
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (status, value)
        },
        parameterized: { element, name, argument in
            var value: CFTypeRef?
            let status = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &value)
            return (status, value)
        },
        wake: { AXUIElementSetAttributeValue($0, "AXManualAccessibility" as CFString, kCFBooleanTrue) },
        enhance: { AXUIElementSetAttributeValue($0, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) })
}

/// One read of another app's Accessibility tree. Every request is bounded by the messaging timeout,
/// all of them together by `deadline`, the read stops when its task is cancelled, and every
/// failure is classified rather than collapsed into "no value".
///
/// **Both the selection shortcut and hover read through this**, each with its own budget. Hover
/// had a copy of its own that classified nothing — a value it could not read was a value it did not
/// have — so an app that stopped answering was asked a few hundred more times, a quarter of a
/// second each, before hover gave up on it.
///
/// The messaging timeout is not set here. It is process-wide, so it is set by `AccessibilityLane`
/// on entry, for the one read the lane lets run.
struct AccessibilitySession: AccessibilityReading {
    /// Per request. Long enough for a busy app — Safari repainting a fresh selection missed 0.5 s —
    /// short enough that a hung one cannot hold the lookup.
    static let messagingTimeout: Float = 1.0

    /// What an Accessibility status means for the read.
    enum Answer: Equatable {
        case value
        /// The element has no such value: normal, and the read goes on.
        case absent
        case failed(CaptureError)
    }

    let deadline: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant
    private let requests: AccessibilityRequests
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "accessibility")

    /// The read ends at `budget` from now, checked before every request — so it overruns by at
    /// most the one request in flight.
    init(
        budget: Duration, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        requests: AccessibilityRequests = .system
    ) {
        self.now = now
        self.requests = requests
        deadline = now() + budget
    }

    /// `ofApplication`: asked of the app itself, an invalid element means the app is gone and a
    /// plain failure means Accessibility refused it outright — a locked screen. Deeper in the tree
    /// both only mean that one element had nothing: a closed popover, an unsupported attribute.
    static func answer(for status: AXError, ofApplication: Bool = false) -> Answer {
        switch status {
        case .success: .value
        case .cannotComplete: .failed(.notResponding)
        case .apiDisabled: .failed(.accessibilityDisabled)
        case .invalidUIElement: ofApplication ? .failed(.appUnavailable) : .absent
        case .failure: ofApplication ? .failed(.accessibilityRefused) : .absent
        default: .absent
        }
    }

    func attribute(_ element: AXUIElement, _ name: String, ofApplication: Bool) throws(CaptureError) -> CFTypeRef? {
        try checkStillWanted()
        let (status, value) = requests.attribute(element, name)
        return try settle(status, name, ofApplication: ofApplication) ? value : nil
    }

    func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
        try checkStillWanted()
        let (status, value) = requests.parameterized(element, name, argument)
        return try settle(status, name, ofApplication: false) ? value : nil
    }

    /// **Inside the budget, and classified like any request.** The write used to run before the
    /// deadline started, its failure ignored — so a hung app cost a timeout outside the budget and was
    /// then asked everything else. An app that does not know the attribute answers, and that is fine;
    /// one that does not answer at all ends the read.
    func wake(_ application: AXUIElement) throws(CaptureError) {
        try checkStillWanted()
        // Classified as a request to the app itself: not answering, Accessibility off, the app gone
        // or refusing (a locked screen) all end the read. An unknown attribute is an answer.
        // Through `settle`, so a failure is logged with its status like every other request's.
        _ = try settle(requests.wake(application), "AXManualAccessibility", ofApplication: true)
    }

    /// Classified like `wake`. Chrome's "not implemented" is an answer, not a failure.
    func enhance(_ application: AXUIElement) throws(CaptureError) {
        try checkStillWanted()
        _ = try settle(requests.enhance(application), "AXEnhancedUserInterface", ofApplication: true)
    }

    static func rangeValue(_ range: CFRange) -> AXValue? {
        var range = range
        return AXValueCreate(.cfRange, &range)
    }

    private func checkStillWanted() throws(CaptureError) {
        if Task.isCancelled { throw .cancelled }
        guard now() < deadline else { throw .deadlineExceeded }
    }

    /// Absent values are normal and pass quietly; statuses that are neither success nor the usual
    /// "no such attribute" are logged, so an app that answers oddly can be diagnosed.
    private func settle(_ status: AXError, _ name: String, ofApplication: Bool) throws(CaptureError) -> Bool {
        switch Self.answer(for: status, ofApplication: ofApplication) {
        case .value: return true
        case .failed(let error):
            log.error("\(name, privacy: .public): AXError \(status.rawValue) — \(String(describing: error), privacy: .public)")
            throw error
        case .absent:
            if ![.noValue, .attributeUnsupported, .parameterizedAttributeUnsupported].contains(status) {
                log.debug("\(name, privacy: .public): AXError \(status.rawValue), read as absent")
            }
            return false
        }
    }
}

/// **Every out-of-process Accessibility read, one at a time** — hover's and the selection
/// shortcut's alike.
///
/// Two reasons, both about other apps. A read cancelled mid-way is still finishing the one request
/// in flight, and the next must not run beside it into the same app. And the messaging timeout is
/// process-wide — set on the system-wide element it binds every element this process asks
/// (`AXUIElement.h`) — so hover's quarter second and a selection read's full second, set by two
/// reads at once, changed each other's mid-read. The lane sets the timeout on entry, for the one
/// read it lets run.
///
/// An Accessibility request about *this* process is not IPC and does not come through here: it is
/// serviced on the calling thread, which must be the main actor (`SelectionReader.read(from:)`).
final class AccessibilityLane: Sendable {
    static let system = AccessibilityLane { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), $0) }

    private let setTimeout: @Sendable (Float) -> Void
    private let last = Mutex<Task<Void, Never>?>(nil)

    init(setTimeout: @escaping @Sendable (Float) -> Void) {
        self.setTimeout = setTimeout
    }

    /// Runs `work` detached, after every earlier read has finished, under `timeout`. A read whose
    /// caller is cancelled before its turn does no work; cancellation during the work is passed on,
    /// and the work sees it between requests.
    ///
    /// **A cancelled caller is answered at once with `cancelled()`.** It used to wait for every read
    /// ahead of it — up to a selection read's whole budget — before learning it had been cancelled.
    /// The read stays in the lane as the barrier the next one waits on; only the caller is let go.
    func run<T: Sendable>(
        timeout: Float, _ work: @escaping @Sendable () -> T, cancelled: @escaping @Sendable () -> T
    ) async -> T {
        // **A caller cancelled already does no work.** The detached read below would start before the
        // cancellation handler could reach it, and on an idle lane it would run.
        if Task.isCancelled { return cancelled() }
        let setTimeout = setTimeout
        // **The work waits to be let in**: opened once the caller's cancellation handler is in place,
        // closed if the caller is cancelled first — whichever comes first. The check above and that
        // handler leave a moment between them, and on an idle lane a detached read started in it ran
        // for a caller that had already gone.
        let gate = FirstAnswer<Bool>()
        let task = last.withLock { last -> Task<T, Never> in
            let previous = last
            let next = Task.detached(priority: .userInitiated) { () -> T in
                _ = await previous?.value
                let admitted = await withCheckedContinuation { gate.install($0) }
                guard admitted, !Task.isCancelled else { return cancelled() }
                setTimeout(timeout)
                return work()
            }
            last = Task.detached { _ = await next.value }
            return next
        }
        return await value(of: task, orOnCancel: {
            gate.give(false)
            return cancelled()
        }, watching: { gate.give(true) })
    }
}
