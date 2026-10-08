// word-point <bundle-id> [--page] [--assistive] [--pid <pid>]: the screen point of a word in that app's text, as "X Y"
// on stdout, and on stderr which element it chose and where — so a hover that fails can name what it pointed at.
//
// Finds a text-bearing element through Accessibility and returns a point inside its first line.
// It reads *position and size* attributes; `XiaolaiDict --read-point` then reads the word through the
// range, marker and bounds dialects — different attributes, so this is not a tautology.
//
// - `--page`: the word must be in a web page, and the page is waited for, up to ten seconds. **Never the window's own
//   controls**: a browser tab's title is an `AXStaticText`, and it is first in the tree.
// - `--assistive`: tell the app an assistive client is reading it, which Chrome needs before it builds a page tree.
//   Implies `--page`.
// - `--pid`: this process rather than the first app with the bundle identifier — for an instance the stage started
//   beside one the reader may already have open.
import AppKit
import ApplicationServices

let usage = "usage: word-point <bundle-id> [--page] [--assistive] [--pid <pid>]\n"
func refuse(_ reason: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(reason.utf8)); exit(status)
}
var arguments = Array(CommandLine.arguments.dropFirst())
guard let bundleID = arguments.first, !bundleID.hasPrefix("--") else { refuse(usage, status: 64) }
arguments.removeFirst()
/// Tell the app an assistive client is reading it — what Chrome needs before it builds a page tree, and
/// what XiaolaiDict's reader does after a hover that found nothing. **Only when asked**: it makes an app
/// build its whole tree for the rest of its run, and the stages after this one share the machine.
var assistive = false
var pageOnly = false
var named: pid_t?
while let argument = arguments.first {
    arguments.removeFirst()
    switch argument {
    case "--assistive": assistive = true; pageOnly = true
    case "--page": pageOnly = true
    case "--pid":
        guard let value = arguments.first, let pid = pid_t(value), pid > 0 else { refuse(usage, status: 64) }
        arguments.removeFirst()
        named = pid
    default: refuse(usage, status: 64)
    }
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

// The process: the one named, or the app's real one, never the -1 macOS 27 reports for some apps —
// `shared/running-app.swift`.
let pid: pid_t
if let named {
    guard NSRunningApplication(processIdentifier: named)?.bundleIdentifier == bundleID else {
        refuse("pid \(named) is not \(bundleID)\n")
    }
    pid = named
} else {
    guard let app = runningApp(bundleID) else { refuse("app not running\n") }
    pid = app.pid
}
let root = AXUIElementCreateApplication(pid)

/// A text element the probe can point at: what it is, what it says, and where.
struct TextElement {
    let role: String
    let text: String
    let box: CGRect
    /// Said on stderr, so a hover that fails names what it was pointed at.
    var description: String {
        "\(role) “\(text.prefix(40))” at \(Int(box.minX)),\(Int(box.minY)) \(Int(box.width))×\(Int(box.height))"
    }
}

/// Breadth-first search from `roots` for the first element of a text role that knows where it is.
func firstTextElement(from roots: [AXUIElement], limit: Int = 600) -> TextElement? {
    var queue = roots
    var head = 0
    while head < queue.count, head < limit {
        let node = queue[head]; head += 1
        let role = attribute(node, kAXRoleAttribute) as? String ?? ""
        let text = (attribute(node, kAXValueAttribute) as? String) ?? ""
        if textRoles.contains(role), text.count > 4, let box = frame(node), box.width > 40, box.height > 8 {
            return TextElement(role: role, text: text, box: box)
        }
        queue += attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    return nil
}

/// The page's own content, where there is one. A browser tab's *title* is an `AXStaticText` too,
/// and it is the first one in the tree — which is how this probe ended up pointing at a tab and
/// the reading fell through to the recogniser. Measured, twice.
///
/// **Depth first, as `select-web` finds the page, and not cut off after 600 nodes.** Breadth first with that cap did
/// not reach Safari's web area on the E2E Mac (2026-10-08) and the walk fell back to the window, pointing at the tab's
/// title — `AXStaticText “XiaolaiDict E2E”`, read by the recogniser where the stage wanted text markers.
func webAreas(from roots: [AXUIElement]) -> [AXUIElement] {
    var found: [AXUIElement] = []
    var visited = 0
    func walk(_ node: AXUIElement, depth: Int) {
        visited += 1
        guard visited < 20_000, depth < 60 else { return }
        if attribute(node, kAXRoleAttribute) as? String == "AXWebArea" { found.append(node); return }
        for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
    }
    for root in roots { walk(root, depth: 0) }
    return found
}

// **Woken first, and given time to fill in.** A Chromium tree exposes no page until a client sets
// `AXManualAccessibility` — the write XiaolaiDict's own reader makes — and then builds it
// asynchronously, so the first walks after waking find only the window chrome. Harmless for an app
// that has no such attribute: the write is refused and nothing else changes.
AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
if assistive { AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }

// **Where the caller asks for a page, only the page will do, and it is waited for.** Chrome builds its tree seconds after
// it is asked — the reader's own comment measures about two — and a walk that found no page took the window's controls
// instead. An app with no page at all — TextEdit — has its text found on the first walk, as before.
let deadline = Date().addingTimeInterval(pageOnly ? 10 : 3)
var windows: [AXUIElement] = []
repeat {
    windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
    let pages = webAreas(from: windows)
    // Breadth-first for the first element that both has text and knows where it is.
    if let found = firstTextElement(from: pages.isEmpty ? (pageOnly ? [] : windows) : pages) {
        // Just inside the leading edge of the first line: a point that is over a glyph rather
        // than in the margin, where AXRangeForPosition answers with the nearest character anyway.
        FileHandle.standardError.write(Data("\(found.description)\(pages.isEmpty ? "" : ", in a web page")\n".utf8))
        print("\(Int(found.box.minX + 24)) \(Int(found.box.minY + 10))")
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
} while Date() < deadline
let titles = windows.compactMap { attribute($0, kAXTitleAttribute) as? String }
refuse(pageOnly ? "no web page with text appeared in 10 s, only the window's own controls (windows: \(titles))\n"
                : "no text element found (windows: \(titles))\n")
