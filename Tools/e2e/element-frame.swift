// element-frame <bundle-id> <dom-id>: the frame, y down, of the element a web page gave that id — "X Y W H" on stdout.
//
// Read through Accessibility's `AXDOMIdentifier` and the element's position and size, never through any text attribute:
// the `hover` stage uses it to know where a page put a word drawn only in pixels (`canvas.html`), independently of what
// the recogniser reports about the same word. The page is waited for, up to ten seconds, as `word-point` waits for one.
import AppKit
import ApplicationServices

func refuse(_ reason: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(reason.utf8)); exit(status)
}
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else { refuse("usage: element-frame <bundle-id> <dom-id>\n", status: 64) }
let (bundleID, domID) = (arguments[0], arguments[1])

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero, extent = CGSize.zero
    // swiftlint:disable:next force_cast
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent)
    else { return nil }
    return CGRect(origin: origin, size: extent)
}

/// Depth first, as `word-point` finds a page: a browser's page sits under toolbars and tab groups.
func element(withID id: String, from roots: [AXUIElement]) -> AXUIElement? {
    var visited = 0
    func walk(_ node: AXUIElement, depth: Int) -> AXUIElement? {
        visited += 1
        guard visited < 20_000, depth < 60 else { return nil }
        if attribute(node, "AXDOMIdentifier") as? String == id { return node }
        for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = walk(child, depth: depth + 1) { return found }
        }
        return nil
    }
    for root in roots { if let found = walk(root, depth: 0) { return found } }
    return nil
}

guard let app = runningApp(bundleID) else { refuse("app not running\n") }
let root = AXUIElementCreateApplication(app.pid)
let deadline = Date().addingTimeInterval(10)
repeat {
    let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    if let found = element(withID: domID, from: windows), let box = frame(found), box.width > 0, box.height > 0 {
        print("\(box.minX) \(box.minY) \(box.width) \(box.height)")
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.25)
} while Date() < deadline
refuse("no element with the DOM id “\(domID)” and a frame in \(bundleID)\n")
