import AppKit
import ApplicationServices

// drag-card <bundle-id> <window-title> <text> <dx> <dy> — drags an app's window by a piece of its text, as a reader takes
// a card by its paper, with real mouse events: the button down at the middle of the first static text in the window
// titled <window-title> whose value holds <text>, moved by <dx>,<dy> points in steps of two, and up. Prints the window's
// frame before and after, in Accessibility screen coordinates (origin top-left), as one line of JSON:
// {"before": {"x":…, "y":…, "width":…, "height":…}, "after": {…}}.
//
// Exists for the lookup stage's check that a followed suggestion replaces the card where the reader dragged it (the
// audit of 2026-10-10). Text, never a control: a press on a button would press it, and the card's paper is what a
// reader drags. **Every event states its modifiers — none — never inheriting the session's** (`EndToEndTextTests`).
// Every way this can go wrong is a nonzero exit that says which.
let arguments = Array(CommandLine.arguments.dropFirst())
func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1)
}
// **Bounded before anything is asked, let alone the button pressed** (third audit of 2026-10-10): `1e100` trapped on the
// step count after the button went down, and a smaller huge distance looped for hours. No card travels farther.
let limit = 2_000.0
guard arguments.count == 5, let dx = Double(arguments[3]), let dy = Double(arguments[4]),
      dx.isFinite, dy.isFinite, abs(dx) <= limit, abs(dy) <= limit else {
    FileHandle.standardError.write(Data(
        "usage: drag-card <bundle-id> <window-title> <text> <dx> <dy>, each move at most \(Int(limit)) points\n".utf8))
    exit(2)
}
guard AXIsProcessTrusted() else { die("this process is not trusted for Accessibility, so it can see nothing") }
let (bundleID, title, text) = (arguments[0], arguments[1], arguments[2])
// The real process, never the -1 macOS 27 reports for some apps — `shared/running-app.swift`.
guard let app = runningApp(bundleID) else { die("\(bundleID) is not running") }
let ax = AXUIElementCreateApplication(app.pid)
AXUIElementSetMessagingTimeout(ax, 2)

func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var found: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &found) == .success ? found : nil
}
func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = value(element, kAXPositionAttribute as String),
          let size = value(element, kAXSizeAttribute as String) else { return nil }
    var origin = CGPoint.zero, extent = CGSize.zero
    // swiftlint:disable:next force_cast
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    // swiftlint:disable:next force_cast
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    // Finite or none: a grip at NaN is nowhere to press, and a report JSON cannot hold (`shared/report.swift`).
    return finite(CGRect(origin: origin, size: extent))
}
func box(_ rect: CGRect) -> [String: Double] {
    ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
}

guard let windows = value(ax, kAXWindowsAttribute as String) as? [AXUIElement],
      let window = windows.first(where: { value($0, kAXTitleAttribute as String) as? String == title })
else { die("\(bundleID) has no window titled \(title)") }
guard let before = frame(window) else { die("the window titled \(title) has no frame") }

// Breadth first, bounded: the first static text that holds `text`.
var queue = [window], head = 0, grip: CGRect?
while head < queue.count, head < 4_000, grip == nil {
    let node = queue[head]
    head += 1
    if value(node, kAXRoleAttribute as String) as? String == kAXStaticTextRole as String,
       (value(node, kAXValueAttribute as String) as? String)?.contains(text) == true,
       let found = frame(node), found.width > 0, found.height > 0 {
        grip = found
    }
    queue += value(node, kAXChildrenAttribute as String) as? [AXUIElement] ?? []
}
guard let grip else { die("no text holding “\(text)” in the window titled \(title)") }

/// One event, its modifiers stated. False where it could not be made.
func post(_ type: CGEventType, _ point: CGPoint) -> Bool {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    else { return false }
    event.flags = []
    event.post(tap: .cghidEventTap)
    return true
}
let start = CGPoint(x: grip.midX, y: grip.midY)
guard post(.leftMouseDown, start) else { die("the button could not be pressed") }
usleep(120_000)
// Steps of at most two points, as a hand's are: a drag begins on its first move (`PlacementReport.dragStep`). A thousand
// at most, by the bound above. **The button comes up however the drag ends**, where the pointer last went.
let steps = max(1, Int((max(abs(dx), abs(dy)) / 2).rounded(.up)))
var at = start
for step in 1...steps {
    let part = Double(step) / Double(steps)
    let next = CGPoint(x: start.x + dx * part, y: start.y + dy * part)
    guard post(.leftMouseDragged, next) else {
        _ = post(.leftMouseUp, at)
        die("a drag event could not be made; the button was released at \(at)")
    }
    at = next
    usleep(10_000)
}
guard post(.leftMouseUp, at) else { die("the button could not be released") }
usleep(400_000)
guard let after = frame(window) else { die("the window titled \(title) went during the drag") }
let report: [String: Any] = ["before": box(before), "after": box(after)]
// Through `jsonLine`, which asks before it serialises (`shared/report.swift`).
guard let line = jsonLine(report) else { die("the report holds a value JSON cannot") }
print(line)
