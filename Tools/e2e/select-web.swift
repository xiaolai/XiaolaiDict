// select-web <bundle-id> <needle>: focus the app's frontmost web page and select needle in it
// through text markers — the dialect WebKit exposes. Exits non-zero, saying why, if it cannot.
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: select-web <bundle-id> <needle>\n".utf8)); exit(64)
}
/// Apps this helper hid to get the front, put back by **every** exit — see the activation loop.
var hidden: [NSRunningApplication] = []
func restoreHidden() { for app in hidden { app.unhide() }; hidden = [] }

func fail(_ reason: String) -> Never {
    restoreHidden()
    FileHandle.standardError.write(Data("select-web: \(reason)\n".utf8))
    exit(1)
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func parameterized(_ element: AXUIElement, _ name: String, _ argument: CFTypeRef) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, argument, &value) == .success ? value : nil
}
func webArea(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if attribute(element, kAXRoleAttribute) as? String == "AXWebArea" { return element }
    guard depth < 60, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    for child in children { if let found = webArea(child, depth: depth + 1) { return found } }
    return nil
}
// Safari may report pid -1 through NSWorkspace; the window server knows the real process.
func processID() -> pid_t? {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
        .compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }
        .first { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier == arguments[1] }
}

/// The front window's page and its text, once the page has loaded far enough to hold the needle.
func loadedPage() -> (page: AXUIElement, text: NSString)? {
    guard let pid = processID() else { return nil }
    let application = AXUIElementCreateApplication(pid)
    guard let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement], let window = windows.first,
          let page = webArea(window),
          let start = attribute(page, "AXStartTextMarker"), let end = attribute(page, "AXEndTextMarker"),
          let whole = parameterized(page, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray),
          let text = parameterized(page, "AXStringForTextMarkerRange", whole) as? NSString,
          text.range(of: arguments[2]).location != NSNotFound
    else { return nil }
    return (page, text)
}

// A page opened from outside may still be loading: wait for it, up to ten seconds.
var found: (page: AXUIElement, text: NSString)?
for _ in 0..<50 {
    found = loadedPage()
    if found != nil { break }
    Thread.sleep(forTimeInterval: 0.2)
}
guard let (page, text) = found else { fail("no page in \(arguments[1])'s front window holds '\(arguments[2])'") }

// Click into the page, as a reader does: a page opened from outside leaves the address field
// focused with the URL selected — and that is the selection a reader would get. WebKit's page
// element will not take focus through Accessibility, so it is a real click, into the page's
// blank lower-right corner, with the pointer put back afterwards.
func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero, extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGRect(origin: origin, size: extent)
}
guard let pageFrame = frame(page), pageFrame.width > 40, pageFrame.height > 40 else { fail("the page has no usable frame") }

// **Brought to the front first, like `click-element` does, and for the same measured reason:**
// the first click on an inactive app's window only raises it, and whatever it landed on is
// untouched. Without this the stage needed a desktop with nothing else on it — a YouTube window
// left open on the test Mac failed all three Safari checks with "the click did not move focus
// into the page", which reads as a defect in the selection reader rather than as a window in
// the way.
/// **An app that will not give up the front is hidden, and unhidden on the way out.**
///
/// Activating once was not enough: a background app on the test Mac raised itself between the
/// activation and the click, and the stage then reported "the click did not move focus into the
/// page" — which reads as a defect in the selection reader rather than as a window in the way.
/// A stage measures the machine it is run on, and this machine accumulates apps; what it sets
/// aside it puts back.
if let pid = processID(), let app = NSRunningApplication(processIdentifier: pid) {
    var front: NSRunningApplication?
    for attempt in 0..<3 {
        app.activate()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
            usleep(100_000)
        }
        front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == pid { break }
        // Last resort, and only for something that has already refused twice: hiding is
        // reversible, and it is the only thing that stops an app raising itself again.
        if attempt > 0, let other = front, other.processIdentifier != pid,
           other.bundleIdentifier != Bundle.main.bundleIdentifier, other.hide() {
            hidden.append(other)
        }
    }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        let name = front?.bundleIdentifier ?? "nothing"
        fail("\(arguments[1]) would not come to the front (\(name) is there, and hiding it did not help)")
    }
}
// Read again once it is in front: raising a window can move it.
guard let raisedFrame = frame(page), raisedFrame.width > 40, raisedFrame.height > 40 else {
    fail("the page has no usable frame once it is in front")
}
let target = CGPoint(x: raisedFrame.maxX - 20, y: raisedFrame.maxY - 20)
let back = CGEvent(source: nil)?.location ?? target
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    // No modifiers, said rather than inherited from the session — see `menu-click.swift`.
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: .left)
    event?.flags = []
    event?.post(tap: .cghidEventTap)
    usleep(50_000)
}
usleep(300_000)
CGWarpMouseCursorPosition(back)

func isInside(_ element: AXUIElement, _ ancestor: AXUIElement) -> Bool {
    var current: AXUIElement? = element
    for _ in 0..<40 {
        guard let node = current else { return false }
        if CFEqual(node, ancestor) { return true }
        current = attribute(node, kAXParentAttribute).map { $0 as! AXUIElement }
    }
    return false
}
guard let pid = processID(),
      let focused = attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
      CFGetTypeID(focused) == AXUIElementGetTypeID(), isInside(focused as! AXUIElement, page)
else {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nothing"
    fail("the click did not move focus into the page (\(front) is in front now)")
}

let range = text.range(of: arguments[2])
guard let first = parameterized(page, "AXTextMarkerForIndex", range.location as CFNumber),
      let last = parameterized(page, "AXTextMarkerForIndex", (range.location + range.length) as CFNumber),
      let selection = parameterized(page, "AXTextMarkerRangeForUnorderedTextMarkers", [first, last] as CFArray)
else { fail("no text markers for '\(arguments[2])'") }
let status = AXUIElementSetAttributeValue(page, "AXSelectedTextMarkerRange" as CFString, selection)
guard status == .success else { fail("setting the selection failed: AXError \(status.rawValue)") }
restoreHidden()
