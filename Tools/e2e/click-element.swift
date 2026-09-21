import AppKit
import ApplicationServices

// click-element <bundle-id> <title> [more titles…] — clicks named controls inside an app's own
// windows, in order, with real mouse events.
//
// Real events rather than `AXPress`, for the reason `menu-click` gives: pressing through
// Accessibility does not activate the app, so a control that only responds when its window is key
// — a field waiting for a key press, for instance — reads as broken when it is not. Several titles
// in one run because the interesting sequences are sequences: select the pane, then arm the field
// that is on it.
//
// **Every way this can go wrong is a nonzero exit that says which.** It clicks global screen
// coordinates, so a mistake does not fail quietly — it lands on something else, possibly in
// another app. So: only enabled controls match, never a label or a container; a title two controls
// share is refused rather than guessed; the point is hit-tested before it is clicked, so a covered
// control is refused rather than clicked through; and each target is waited for until its frame is
// still, rather than assumed ready after a fixed pause.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: click-element <bundle-id> <title>…\n".utf8)); exit(2)
}
func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
guard AXIsProcessTrusted() else { die("this process is not trusted for Accessibility, so it can see nothing") }
let bundleID = arguments[0]
let wanted = Array(arguments.dropFirst())
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    die("\(bundleID) is not running")
}
let ax = AXUIElementCreateApplication(app.processIdentifier)
let systemWide = AXUIElementCreateSystemWide()
// A synchronous Accessibility call to a busy app otherwise waits as long as the system default.
AXUIElementSetMessagingTimeout(ax, 2)
AXUIElementSetMessagingTimeout(systemWide, 2)
/// How long a target may take to appear and stop moving.
let targetDeadline: TimeInterval = 6
/// The most elements one search visits: a bound on a tree that is wide, or that cycles.
let visitLimit = 4_000

/// An attribute, and why it is missing when it is. **An error is not an absence**: a messaging
/// timeout, a stale element and a permission failure all used to read as "this control does not
/// have that", which is how a helper comes to report "no such control" for a window it simply
/// could not talk to.
func read(_ element: AXUIElement, _ name: String) -> (value: AnyObject?, error: AXError) {
    var found: AnyObject?
    let status = AXUIElementCopyAttributeValue(element, name as CFString, &found)
    return (found, status)
}
func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
    let (found, status) = read(element, name)
    return status == .success ? found : nil
}
/// True where the attribute is genuinely not offered; false where the read failed for another
/// reason, which the caller must not treat as an answer.
func isAbsent(_ error: AXError) -> Bool {
    error == .noValue || error == .attributeUnsupported
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
/// Every name a control might answer to. A SwiftUI `Tab` reaches Accessibility as a button whose
/// title is the tab's name; a `Button` whose label is its shortcut carries that as its title; some
/// controls carry only a description.
func names(_ element: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
        .compactMap { value(element, $0) as? String }
}
func frame(_ element: AXUIElement) -> CGRect? {
    var origin = CGPoint.zero, size = CGSize.zero
    guard let position = value(element, kAXPositionAttribute),
          let extent = value(element, kAXSizeAttribute) else { return nil }
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    AXValueGetValue(extent as! AXValue, .cgSize, &size)
    guard size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: origin, size: size)
}
/// Roles a click means something to. A static text or a group that happens to carry the same
/// name is not a control, and clicking it clicks whatever is underneath.
let actionable: Set<String> = [
    kAXButtonRole, kAXRadioButtonRole, kAXCheckBoxRole, kAXPopUpButtonRole, kAXMenuButtonRole,
    kAXDisclosureTriangleRole, "AXLink", "AXTab",
]
func isEnabledControl(_ element: AXUIElement) -> Bool {
    guard let role = value(element, kAXRoleAttribute) as? String, actionable.contains(role) else { return false }
    let enabled = read(element, kAXEnabledAttribute)
    if let flag = enabled.value as? Bool { return flag }
    // Offered and unreadable is not "enabled": a control whose state could not be established is
    // one this must not click.
    return isAbsent(enabled.error)
}

/// One bounded breadth-first walk over the app's windows, shared by the search and the failure
/// message. A head index rather than `removeFirst`, which shifts the whole queue on every visit —
/// and an elapsed-time bound as well as a visit count, because thousands of synchronous
/// Accessibility requests can outrun any deadline the caller meant to keep even without cycling.
func walk(until deadline: Date, _ visit: (AXUIElement) -> Void) {
    var queue = (value(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    var head = 0
    while head < queue.count, head < visitLimit, Date() < deadline {
        let element = queue[head]
        head += 1
        visit(element)
        queue += children(element)
    }
}

func matches(_ title: String, until deadline: Date) -> [AXUIElement] {
    var found: [AXUIElement] = []
    walk(until: deadline) { if names($0).contains(title), isEnabledControl($0), frame($0) != nil { found.append($0) } }
    return found
}
func clickable(until deadline: Date) -> [String] {
    var seen = Set<String>()
    walk(until: deadline) { if isEnabledControl($0), frame($0) != nil { seen.formUnion(names($0)) } }
    return seen.sorted()
}

/// The one enabled control called `title`, once it exists and **both it and its window** have held
/// still between two reads — or the reason there is none.
///
/// The window as well as the control: a settings pane that grows animates its window for a third of
/// a second, during which the toolbar's buttons do not move at all — so a tab clicked then looked
/// perfectly still and the click was dropped, leaving the pane unswitched and the check that
/// followed testing the pane it thought it had left.
func target(_ title: String) -> (AXUIElement, CGRect) {
    let deadline = Date().addingTimeInterval(targetDeadline)
    var last: (element: CGRect, window: CGRect)?
    while Date() < deadline {
        let found = matches(title, until: deadline)
        if found.count > 1 { die("\(found.count) enabled controls are called \"\(title)\"; refusing to guess which") }
        // The window's frame must be readable to count as still: two failed reads are not a window
        // that held still, and taking them for one is how a click lands mid-animation.
        if let element = found.first, let now = frame(element),
           let container = value(element, kAXWindowAttribute), let window = frame(container as! AXUIElement) {
            if let last, last.element == now, last.window == window { return (element, now) }
            last = (now, window)
        } else {
            last = nil
        }
        usleep(100_000)
    }
    let seen = clickable(until: Date().addingTimeInterval(1))
    die("no enabled control called \"\(title)\" came to rest within \(Int(targetDeadline)) s; clickable: \(seen.prefix(40))")
}

/// What is actually on top at `point`: nil when it is `element` or inside it, otherwise a
/// description of the thing that is — so a refusal says what covered the control.
func cover(of element: AXUIElement, at point: CGPoint) -> String? {
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
          let top = hit else { return "nothing Accessibility can name" }
    var node = top
    for _ in 0..<visitLimit {
        if CFEqual(node, element) { return nil }
        guard let parent = value(node, kAXParentAttribute) else { break }
        node = parent as! AXUIElement
    }
    var pid: pid_t = 0
    AXUIElementGetPid(top, &pid)
    let owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
    let role = value(top, kAXRoleAttribute) as? String ?? "?"
    return "\(role) \(names(top).first.map { "\"\($0)\"" } ?? "") of \(owner)"
}

/// All three events, made before any is posted: an event that cannot be made must not leave a
/// button pressed down with nothing to release it.
func click(_ point: CGPoint, on element: AXUIElement, called title: String) {
    let sequence: [(CGEventType, useconds_t)] = [(.mouseMoved, 120_000), (.leftMouseDown, 80_000), (.leftMouseUp, 0)]
    let events = sequence.compactMap { type, pause in
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left).map { ($0, pause) }
    }
    guard events.count == sequence.count else { die("could not create the mouse events for a click") }
    for (index, (event, pause)) in events.enumerated() {
        // Checked again with the pointer already there, immediately before the press: moving the
        // pointer can put something over the target — a tooltip, a menu opening under the cursor —
        // between the check and the click.
        if index == 1, let covering = cover(of: element, at: point) {
            die("\"\(title)\" was covered by \(covering) as the pointer reached it; refusing to click")
        }
        event.post(tap: .cghidEventTap)
        if pause > 0 { usleep(pause) }
    }
}

/// The app must be frontmost, or the click does not do what the caller means: **the first click on
/// an inactive app's window only brings it forward**, and the control it landed on is untouched.
/// Measured: a settings tab clicked that way did not switch panes, and the check that followed
/// read the pane it thought it had left.
func waitToBeFrontmost() {
    let deadline = Date().addingTimeInterval(targetDeadline)
    while Date() < deadline {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
        usleep(100_000)
    }
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nothing"
    die("\(bundleID) is not frontmost (\(front) is); a click would only bring it forward")
}

for title in wanted {
    waitToBeFrontmost()
    let (element, rect) = target(title)
    let point = CGPoint(x: rect.midX, y: rect.midY)
    if let covering = cover(of: element, at: point) {
        die("\"\(title)\" is covered at (\(Int(point.x)), \(Int(point.y))) by \(covering); refusing to click it")
    }
    click(point, on: element, called: title)
    print("clicked \(title)")
}
