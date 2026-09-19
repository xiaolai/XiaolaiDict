// word-point <bundle-id>: the screen point of a word in that app's text, as "X Y".
//
// Finds a text-bearing element through Accessibility and returns a point inside its first line.
// It reads *position and size* attributes; `XiaolaiDict --read-point` then reads the word through the
// range, marker and bounds dialects — different attributes, so this is not a tautology.
import AppKit
import ApplicationServices

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: word-point <bundle-id>\n".utf8)); exit(64)
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func frame(_ element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero, extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
    return CGRect(origin: origin, size: extent)
}
// Only *text* roles. Without this the first match in Safari is an `AXRadioButton` — a tab, whose
// title is text and which no text dialect can read — so the probe pointed at the chrome and the
// reading fell through to the recogniser. Measured, not guessed.
let textRoles: Set<String> = ["AXStaticText", "AXTextArea"]

guard let app = NSRunningApplication.runningApplications(
    withBundleIdentifier: CommandLine.arguments[1]).first else {
    FileHandle.standardError.write(Data("app not running\n".utf8)); exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)

/// Breadth-first search from `roots` for the first element of a text role that knows where it is.
func firstTextElement(from roots: [AXUIElement], limit: Int = 600) -> CGRect? {
    var queue = roots
    var head = 0
    while head < queue.count, head < limit {
        let node = queue[head]; head += 1
        let role = attribute(node, kAXRoleAttribute) as? String ?? ""
        let text = (attribute(node, kAXValueAttribute) as? String) ?? ""
        if textRoles.contains(role), text.count > 4, let box = frame(node), box.width > 40, box.height > 8 {
            return box
        }
        queue += attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    return nil
}

/// The page's own content, where there is one. A browser tab's *title* is an `AXStaticText` too,
/// and it is the first one in the tree — which is how this probe ended up pointing at a tab and
/// the reading fell through to the recogniser. Measured, twice.
func webAreas(from roots: [AXUIElement], limit: Int = 600) -> [AXUIElement] {
    var queue = roots
    var head = 0
    var found: [AXUIElement] = []
    while head < queue.count, head < limit {
        let node = queue[head]; head += 1
        if attribute(node, kAXRoleAttribute) as? String == "AXWebArea" { found.append(node); continue }
        queue += attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    return found
}

// Breadth-first for the first element that both has text and knows where it is.
var queue: [AXUIElement] = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
let pages = webAreas(from: queue)
if let box = firstTextElement(from: pages.isEmpty ? queue : pages) {
    print("\(Int(box.minX + 24)) \(Int(box.minY + 10))")
    exit(0)
}
var head = 0
while head < queue.count, head < 600 {
    let node = queue[head]; head += 1
    let role = attribute(node, kAXRoleAttribute) as? String ?? ""
    let text = (attribute(node, kAXValueAttribute) as? String) ?? ""
    if textRoles.contains(role), text.count > 4, let box = frame(node), box.width > 40, box.height > 8 {
        // Just inside the leading edge of the first line: a point that is over a glyph rather
        // than in the margin, where AXRangeForPosition answers with the nearest character anyway.
        print("\(Int(box.minX + 24)) \(Int(box.minY + 10))")
        exit(0)
    }
    queue += attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
}
FileHandle.standardError.write(Data("no text element found\n".utf8))
exit(1)
