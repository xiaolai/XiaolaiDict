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
    FileHandle.standardError.write(
        Data("usage: menu-click <bundle-id> <item title>|--ready|--describe|--left-click\n".utf8))
    exit(2)
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
/// A real click, with the button the surface expects.
///
/// **The menu bar item takes a right click now**; a left one opens the reading history, which is
/// the point of the split. A menu *entry* is still chosen with the left button, the way a reader
/// chooses one — so the button is an argument rather than a constant, and the two call sites below
/// say which they mean.
func click(_ point: CGPoint, button: CGMouseButton = .left) {
    let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(120_000)
    CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button)?
        .post(tap: .cghidEventTap)
    usleep(80_000)
    CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: button)?
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

// `--describe`: what the icon says about itself, without clicking it.
//
// **The witness that the lookup hot key is registered.** It used to be the menu's first item,
// `Look Up Selection    ⌃⌥D`, which named the combination and nothing when there was none. That
// item was cut — a reader does not reach for it, they press the shortcut — and the naming moved to
// the item's tooltip, which Accessibility reports as `AXHelp`. Read passively on purpose: the
// stage asks this *after* the settings field has been used, and opening a menu to find out would
// itself move the focus the answer depends on.
if wanted == "--describe" {
    guard let help = value(item, kAXHelpAttribute as String) as? String, !help.isEmpty else {
        FileHandle.standardError.write(Data("the menu-bar item says nothing about itself\n".utf8))
        exit(1)
    }
    print(help)
    exit(0)
}

// `--left-click`: the reading history, which is what a left click on the icon opens.
//
// Not a menu item any more, and deliberately not: an item that repeats the click which opened the
// menu is a line the reader reads past. So the surface is still driven the way a reader drives it,
// with the button they would use.
if wanted == "--left-click" {
    click(itemCentre, button: .left)
    usleep(900_000)
    print("clicked the menu-bar item")
    exit(0)
}

click(itemCentre, button: .right)
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
