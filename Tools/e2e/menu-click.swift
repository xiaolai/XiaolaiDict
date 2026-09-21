import AppKit
import ApplicationServices

// menu-click <bundle-id> <item title> — opens an app's menu-bar item with a real click and clicks
// the named entry.
//
// Real mouse events, not `AXPress`: pressing through Accessibility opens the menu without
// activating the app, so a window opened from it never becomes key and never sees a key press.
// That difference made a working recorder look broken, and a broken one would look working.
let bundleID = CommandLine.arguments.count > 2 ? CommandLine.arguments[1] : ""
let wanted = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
guard !bundleID.isEmpty, !wanted.isEmpty else {
    FileHandle.standardError.write(Data("usage: menu-click <bundle-id> <item title>\n".utf8)); exit(2)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    FileHandle.standardError.write(Data("\(bundleID) is not running\n".utf8)); exit(1)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)
func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var found: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &found) == .success ? found : nil
}
func children(_ element: AXUIElement) -> [AXUIElement] {
    (value(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}
func centre(of element: AXUIElement) -> CGPoint? {
    var origin = CGPoint.zero, size = CGSize.zero
    guard let position = value(element, kAXPositionAttribute as String),
          let extent = value(element, kAXSizeAttribute as String) else { return nil }
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    AXValueGetValue(extent as! AXValue, .cgSize, &size)
    return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
}
func click(_ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(120_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(80_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

guard let extras = value(ax, "AXExtrasMenuBar"),
      let item = children(extras as! AXUIElement).first,
      let itemCentre = centre(of: item)
else { FileHandle.standardError.write(Data("no menu-bar item\n".utf8)); exit(1) }

// `--ready`: is the menu-bar item there *yet*, without clicking it.
//
// The process existing is not the menu existing. `e2e.sh` waited for the pid and then drove the
// menu, and immediately after a restart the status item is not in the Accessibility tree yet —
// measured, 3 restarts out of 3. That made whichever menu-driven assertion ran first fail, and
// the failure moved between stages from run to run, which reads like a flaky product rather than
// a harness that never checked its own precondition.
if wanted == "--ready" { print("menu-bar item present"); exit(0) }

click(itemCentre)
usleep(700_000)

guard let menu = children(item).first,
      let entry = children(menu).first(where: {
          (value($0, kAXTitleAttribute as String) as? String) == wanted
      }),
      let entryCentre = centre(of: entry)
else {
    let titles = children(children(item).first ?? item)
        .compactMap { value($0, kAXTitleAttribute as String) as? String }
    FileHandle.standardError.write(Data("no menu item \"\(wanted)\"; saw: \(titles)\n".utf8))
    exit(1)
}
click(entryCentre)
usleep(900_000)
print("clicked \(wanted)")
