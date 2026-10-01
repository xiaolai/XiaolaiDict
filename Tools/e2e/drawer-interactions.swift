// Compile on the build Mac; run only on the separate E2E Mac, after all other UI stages finish.
// drawer-interactions <bundle-id> [all|exclusion|repeated|lifecycle]
// Real mouse events prove the mouse-down exclusion and mouse-up open route independently.
// No ledger/default writes. Escape closes the drawer at the end, including failed checks.
import AppKit
import ApplicationServices
import CoreGraphics

func failSetup(_ message: String) -> Never {
    FileHandle.standardError.write(Data("SETUP: \(message)\n".utf8))
    exit(2)
}

guard CommandLine.arguments.count >= 2, CommandLine.arguments.count <= 3 else {
    failSetup("usage: drawer-interactions <bundle-id> [all|exclusion|repeated|lifecycle]")
}
let mode = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "all"
guard ["all", "exclusion", "repeated", "lifecycle"].contains(mode) else { failSetup("unknown mode") }
guard AXIsProcessTrusted() else { failSetup("Accessibility is not granted to this helper") }
guard let app = NSRunningApplication.runningApplications(
    withBundleIdentifier: CommandLine.arguments[1]).first else { failSetup("app is not running") }
let ax = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(ax, 0.3)
let overallDeadline = Date().addingTimeInterval(90)
var failures = 0
var assertions = 0

func check(_ condition: Bool, _ name: String) {
    assertions += 1
    if !condition { failures += 1 }
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    fflush(stdout)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    guard Date() < overallDeadline else { failSetup("overall 90-second deadline exceeded") }
    var result: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, name as CFString, &result)
    if status == .success { return result }
    if status == .noValue || status == .attributeUnsupported || status == .invalidUIElement { return nil }
    failSetup("\(name): AXError \(status.rawValue)")
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func frame(_ element: AXUIElement) -> CGRect? {
    var point = CGPoint.zero
    var size = CGSize.zero
    guard let position = attribute(element, kAXPositionAttribute),
          let extent = attribute(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(),
          CFGetTypeID(extent) == AXValueGetTypeID(),
          AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(extent as! AXValue, .cgSize, &size),
          size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: point, size: size)
}

func closeFrame(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
        && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
}

struct DrawerSnapshot {
    let frame: CGRect
    let number: Int
}

/// AX identifies the drawer, while the compositor proves that it is drawn at that frame.
func snapshot() -> DrawerSnapshot? {
    guard Date() < overallDeadline else { failSetup("overall 90-second deadline exceeded") }
    let windows = attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
    let matches = windows.filter { attribute($0, kAXTitleAttribute) as? String == "Reading History" }
    guard matches.count <= 1 else { failSetup("multiple reading-history windows") }
    guard let window = matches.first, let rect = frame(window) else { return nil }
    guard let listed = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { failSetup("compositor did not answer") }
    for item in listed {
        guard item[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
              let bounds = item[kCGWindowBounds as String] as? [String: Any],
              let drawn = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              closeFrame(rect, drawn), let number = item[kCGWindowNumber as String] as? Int
        else { continue }
        return DrawerSnapshot(frame: drawn, number: number)
    }
    return nil
}

func pause(_ duration: TimeInterval) {
    // This command-line helper has no run-loop source; run(until:) may return immediately.
    Thread.sleep(forTimeInterval: duration)
}

func waitForVisibility(_ visible: Bool) -> Bool {
    let deadline = Date().addingTimeInterval(3)
    repeat {
        if (snapshot() != nil) == visible { return true }
        pause(0.02)
    } while Date() < deadline
    return false
}

func key(_ code: CGKeyCode) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        else { failSetup("could not make a key event") }
        event.flags = []
        event.post(tap: .cghidEventTap)
        pause(0.05)
    }
}

func mouse(_ point: CGPoint, down: Bool, right: Bool = false, control: Bool = false) {
    let type: CGEventType = right ? (down ? .rightMouseDown : .rightMouseUp)
        : (down ? .leftMouseDown : .leftMouseUp)
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                             mouseCursorPosition: point, mouseButton: right ? .right : .left)
    else { failSetup("could not make a mouse event") }
    event.flags = control ? .maskControl : []
    event.post(tap: .cghidEventTap)
}

func click(_ point: CGPoint, right: Bool = false, control: Bool = false) {
    guard let movement = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left)
    else { failSetup("could not move the pointer") }
    movement.flags = control ? .maskControl : []
    movement.post(tap: .cghidEventTap)
    pause(0.12)
    mouse(point, down: true, right: right, control: control)
    pause(0.05)
    mouse(point, down: false, right: right, control: control)
    if control { releaseControl() }
}

func releaseControl() {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: false)
    else { failSetup("could not release Control") }
    event.flags = []
    event.post(tap: .cghidEventTap)
    pause(0.05)
}

func item() -> AXUIElement {
    guard let extras = attribute(ax, "AXExtrasMenuBar"),
          CFGetTypeID(extras) == AXUIElementGetTypeID(),
          let button = children(extras as! AXUIElement).first,
          frame(button) != nil else { failSetup("owned menu-bar item has no readable frame") }
    return button
}

func itemPoint() -> CGPoint {
    guard let rect = frame(item()) else { failSetup("status button disappeared") }
    return CGPoint(x: rect.midX, y: rect.midY)
}

func openDrawer() -> DrawerSnapshot {
    key(53)
    guard waitForVisibility(false) else { failSetup("Escape could not establish a closed baseline") }
    click(itemPoint())
    guard waitForVisibility(true) else { failSetup("ordinary left click did not open the drawer") }
    pause(0.45)
    guard let initial = snapshot() else { failSetup("drawer vanished after its first click") }
    return initial
}

/// Observe continuously through the interaction, including the down/up gap. A retained AX
/// window alone would hide a close/reopen; each sample also asks the compositor.
func remainsOpen(_ initial: DrawerSnapshot, for duration: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(duration)
    var stable = true
    repeat {
        guard let current = snapshot() else { stable = false; pause(0.01); continue }
        if current.number != initial.number || !closeFrame(current.frame, initial.frame) { stable = false }
        pause(0.01)
    } while Date() < deadline
    return stable
}

func menuIsOpen() -> Bool {
    var queue = children(item())
    var head = 0
    while head < queue.count && head < 200 {
        let node = queue[head]
        head += 1
        if attribute(node, kAXRoleAttribute) as? String == kAXMenuRole {
            guard !children(node).isEmpty, let rect = frame(node),
                  let windows = CGWindowListCopyWindowInfo(
                    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
            else { return false }
            // AppKit retains the AX menu children after tracking ends. They are not visibility.
            return windows.contains { window in
                guard window[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                      let bounds = window[kCGWindowBounds as String] as? [String: Any],
                      let drawn = CGRect(dictionaryRepresentation: bounds as CFDictionary)
                else { return false }
                return closeFrame(rect, drawn)
            }
        }
        queue += children(node)
    }
    return false
}

// Defer is scoped to a function so cleanup runs before the process exits.
func run() {
    releaseControl()
    defer { releaseControl(); key(53); _ = waitForVisibility(false) }
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let initial = openDrawer()
    check(NSWorkspace.shared.frontmostApplication?.processIdentifier == front,
          "initial tray opening preserves focus")
    if mode == "all" || mode == "exclusion" {
        let point = itemPoint()
        mouse(point, down: true)
        let heldOpen = remainsOpen(initial, for: 0.55)
        mouse(point, down: false)
        check(heldOpen, "owned-button mouse-down is excluded before its action runs (criterion 2/3)")
    }
    if mode == "all" || mode == "repeated" {
        // Reset independently so a failed exclusion check cannot invalidate the toggle check.
        let baseline = openDrawer()
        for index in 1...3 {
            click(itemPoint())
            check(remainsOpen(baseline, for: 0.55),
                  "slow repeated tray click \(index) preserves the open drawer (criterion 1)")
            if snapshot() == nil { _ = openDrawer() }
        }
        let rapid = openDrawer()
        for _ in 0..<7 { click(itemPoint()) }
        check(remainsOpen(rapid, for: 0.55), "rapid repeated tray clicks preserve the open drawer (criterion 1)")
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == front,
              "repeated tray opening preserves focus")
    }
    if mode == "all" || mode == "lifecycle" {
        let baseline = openDrawer()
        click(CGPoint(x: baseline.frame.midX, y: baseline.frame.midY))
        check(remainsOpen(baseline, for: 0.35), "drawer content click keeps it open (criterion 3)")
        key(53)
        check(waitForVisibility(false), "Escape dismisses (criterion 4)")
        click(itemPoint())
        check(waitForVisibility(true), "ordinary left click reopens after Escape (criterion 4)")
        pause(0.45)
        guard let primary = NSScreen.screens.first else { failSetup("no display") }
        let outside = CGPoint(x: 24, y: primary.frame.height / 2)
        guard let opened = snapshot() else { failSetup("reopened drawer did not remain visible") }
        guard !opened.frame.contains(outside) else { failSetup("outside-click point would hit the drawer") }
        click(outside)
        check(waitForVisibility(false), "outside click dismisses (criterion 3/4)")
        for control in [false, true] {
            click(itemPoint(), right: !control, control: control)
            let deadline = Date().addingTimeInterval(3)
            while !menuIsOpen() && Date() < deadline { pause(0.02) }
            check(menuIsOpen(), "\(control ? "control" : "right") click opens menu (criterion 4)")
            // End menu tracking with an outside click before testing the next tray action.
            // Escape above tests the drawer's hot key, not a non-frontmost menu's keyboard routing.
            click(outside)
            let dismissDeadline = Date().addingTimeInterval(3)
            while menuIsOpen() && Date() < dismissDeadline { pause(0.02) }
            guard !menuIsOpen() else { failSetup("outside click did not end menu tracking") }
            pause(0.2)
            click(itemPoint())
            check(waitForVisibility(true), "left click opens history after menu gesture (criterion 4)")
            key(53)
            _ = waitForVisibility(false)
        }
    }
}

run()
print("drawer-interactions: \(assertions) assertions, \(failures) failures, pid \(app.processIdentifier), mode \(mode)")
exit(failures == 0 ? 0 : 1)
