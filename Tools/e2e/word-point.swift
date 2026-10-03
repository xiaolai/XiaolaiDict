// word-point <bundle-id> [--assistive]: the screen point of a word in that app's text, as "X Y".
//
// Finds a text-bearing element through Accessibility and returns a point inside its first line.
// It reads *position and size* attributes; `XiaolaiDict --read-point` then reads the word through the
// range, marker and bounds dialects — different attributes, so this is not a tautology.
import AppKit
import ApplicationServices

guard (2...3).contains(CommandLine.arguments.count) else {
    FileHandle.standardError.write(Data("usage: word-point <bundle-id> [--assistive]\n".utf8)); exit(64)
}
/// Tell the app an assistive client is reading it — what Chrome needs before it builds a page tree, and
/// what XiaolaiDict's reader does after a hover that found nothing. **Only when asked**: it makes an app
/// build its whole tree for the rest of its run, and the stages after this one share the machine.
let assistive = CommandLine.arguments.dropFirst(2).first == "--assistive"
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

// **Woken first, and given time to fill in.** A Chromium tree exposes no page until a client sets
// `AXManualAccessibility` — the write XiaolaiDict's own reader makes — and then builds it
// asynchronously, so the first walks after waking find only the window chrome. Harmless for an app
// that has no such attribute: the write is refused and nothing else changes.
AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
if assistive { AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
var queue: [AXUIElement] = []
for _ in 0..<30 {
    queue = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    let pages = webAreas(from: queue)
    // Breadth-first for the first element that both has text and knows where it is.
    if let box = firstTextElement(from: pages.isEmpty ? queue : pages) {
        print("\(Int(box.minX + 24)) \(Int(box.minY + 10))")
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
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
