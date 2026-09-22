// on-screen <bundle-id> [title-fragment] — whether the **compositor** draws that app's window, as one
// JSON object.
//
// Accessibility is not evidence that a reader can see a window. A `UtilityWindow` reports
// `isVisible` while never being composited, and the scenes stage once passed a drawer that was
// never drawn because it only asked whether the window existed. `CGWindowListCopyWindowInfo` with
// `.optionOnScreenOnly` is what the reader's screen actually holds.
//
// **The window is identified by Accessibility and confirmed by the compositor, and the two answer
// different halves.** The compositor's titles (`kCGWindowName`) need Screen Recording, which this
// helper does not have: it is started over SSH, and TCC refuses screen capture to anything launched
// that way, whatever the app has been granted. Matching on a title there reported a board plainly on
// the screen as absent — a fact about the harness that reads exactly like a fact about the app. A
// window's *bounds* need no such grant, and Accessibility reads titles over SSH (measured on the E2E
// machine). So: Accessibility finds the window with that title and says where it is; the compositor
// is asked whether it draws a window of that app at exactly that frame.
//
// Exits 0 whether or not anything matched — "not drawn" is an answer the caller asserts on, not an
// error. Exits non-zero only when it could not ask at all.
import AppKit
import ApplicationServices
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: on-screen <bundle-id> [title-fragment]\n".utf8))
    exit(64)
}
let bundleID = arguments[1]
let fragment = arguments.count > 2 ? arguments[2] : ""

func emit(_ report: [String: Any]) -> Never {
    print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    exit(0)
}

let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    emit(["running": false, "frontmost": front, "matches": [], "windows": []])
}
let pid = app.processIdentifier

guard let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("the compositor did not answer\n".utf8))
    exit(1)
}

/// The app's windows as the compositor draws them.
struct Drawn {
    let frame: CGRect
    let layer: Int
    let name: String
}
var drawn: [Drawn] = []
for window in listed {
    guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
    else { continue }
    drawn.append(Drawn(
        frame: frame, layer: window[kCGWindowLayer as String] as? Int ?? 0,
        name: window[kCGWindowName as String] as? String ?? ""))
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func frame(of window: AXUIElement) -> CGRect? {
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard let position = attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let extent = attribute(window, kAXSizeAttribute), CFGetTypeID(extent) == AXValueGetTypeID(),
          AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(extent as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
}

// Both are top-left-origin global coordinates, so a drawn window matches its Accessibility frame to
// within rounding. Two points of slack, the same tolerance the settings stage uses for a frame that
// lands a half-point either side of a pixel.
func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
        && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
}

var matches: [[String: Any]] = []
if !fragment.isEmpty {
    let element = AXUIElementCreateApplication(pid)
    for window in attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        guard let title = attribute(window, kAXTitleAttribute) as? String, title.contains(fragment)
        else { continue }
        var entry: [String: Any] = ["title": title]
        // Whether the window is the app's main and focused one — which, with the app frontmost, is
        // what "the reader has it" means. Reported so a window that is drawn but never became key
        // can be told from one that was never drawn.
        entry["main"] = (attribute(window, kAXMainAttribute) as? Bool) ?? false
        entry["focused"] = (attribute(window, kAXFocusedAttribute) as? Bool) ?? false
        if let rect = frame(of: window) {
            entry["x"] = Int(rect.minX)
            entry["y"] = Int(rect.minY)
            entry["width"] = Int(rect.width)
            entry["height"] = Int(rect.height)
            // Listed at that frame *and* with some area: a window listed at no size is listed and
            // not drawn, and the two must not read the same.
            entry["drawn"] = rect.width > 0 && rect.height > 0 && drawn.contains { sameFrame($0.frame, rect) }
        } else {
            entry["drawn"] = false
        }
        matches.append(entry)
    }
}

emit([
    "running": true,
    "frontmost": front,
    // Accessibility's windows with the title asked for, each with whether the compositor draws it.
    "matches": matches,
    // Every window the compositor draws for the app, titled where titles are readable.
    "windows": drawn.map { ["x": Int($0.frame.minX), "y": Int($0.frame.minY), "width": Int($0.frame.width),
                            "height": Int($0.frame.height), "layer": $0.layer, "name": $0.name] },
    // Whether the compositor's titles were readable at all. Reported, never relied on.
    "titlesReadable": drawn.isEmpty || drawn.contains { !$0.name.isEmpty },
])
