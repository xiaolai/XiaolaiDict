import ApplicationServices
import XiaolaiDictBase
import XiaolaiDictCore
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
}

extension AccessibilityReading {
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
        guard let value = cast(try attribute(element, name, ofApplication: false), AXValueGetTypeID(), as: AXValue.self) else {
            return nil
        }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
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
        var current = element
        for _ in 0..<Self.webAreaAncestorLimit {
            if try string(current, kAXRoleAttribute) == "AXWebArea" { return current }
            guard let parent = try self.element(current, kAXParentAttribute), parent != current else { return nil }
            current = parent
        }
        return nil
    }

    /// A CF value as `type`, checked by type ID first: `as?` on a CF type always succeeds.
    private func cast<T>(_ value: CFTypeRef?, _ typeID: CFTypeID, as _: T.Type) -> T? {
        guard let value, CFGetTypeID(value) == typeID else { return nil }
        return (value as! T)
    }
}

/// One read of another app's Accessibility tree. Every request is bounded by the messaging timeout,
/// all of them together by `deadline`, the read stops when its task is cancelled, and every
/// failure is classified rather than collapsed into "no value".
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
    private let log = Logger(subsystem: XiaolaiDictIdentity.app, category: "accessibility")

    /// The read ends at `budget` from now, checked before every request — so it overruns by at
    /// most the one request in flight.
    init(budget: Duration) {
        // On the system-wide element the timeout applies to every element this process asks. Set on
        // the application element, it would bind that one object only — not the windows, children
        // and web areas asked after it (AXUIElement.h).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
        deadline = .now + budget
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
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return try settle(status, name, ofApplication: ofApplication) ? value : nil
    }

    func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) throws(CaptureError) -> CFTypeRef? {
        try checkStillWanted()
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &value)
        return try settle(status, name, ofApplication: false) ? value : nil
    }

    static func rangeValue(_ range: CFRange) -> AXValue? {
        var range = range
        return AXValueCreate(.cfRange, &range)
    }

    private func checkStillWanted() throws(CaptureError) {
        if Task.isCancelled { throw .cancelled }
        guard ContinuousClock.now < deadline else { throw .deadlineExceeded }
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
