// on-screen <bundle-id> [name-fragment] — the windows the **compositor** lists for that app, as one
// JSON object.
//
// Accessibility is not evidence that a reader can see a window. A `UtilityWindow` reports
// `isVisible` while never being composited, and the scenes stage once passed a drawer that was
// never drawn because it only asked whether the window existed. `CGWindowListCopyWindowInfo` with
// `.optionOnScreenOnly` is what the reader's screen actually holds.
//
// Exits 0 whether or not anything matched — "no windows" is an answer the caller asserts on, not an
// error. Exits non-zero only when it could not ask at all.
import AppKit
import CoreGraphics

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: on-screen <bundle-id> [name-fragment]\n".utf8))
    exit(64)
}
let bundleID = arguments[1]
let fragment = arguments.count > 2 ? arguments[2] : ""

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    print(#"{"running":false,"windows":[]}"#)
    exit(0)
}
let pid = app.processIdentifier

// Screen recording is not needed for the window *list* — only for its pixels — so this works from
// any GUI session. It does still need a window server, which is why the caller runs it through
// LaunchServices rather than over SSH.
guard let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("the compositor did not answer\n".utf8))
    exit(1)
}

var windows: [[String: Any]] = []
for window in listed {
    guard window[kCGWindowOwnerPID as String] as? pid_t == pid else { continue }
    let name = window[kCGWindowName as String] as? String ?? ""
    if !fragment.isEmpty, !name.contains(fragment) { continue }
    var entry: [String: Any] = ["name": name]
    if let bounds = window[kCGWindowBounds as String] as? [String: Any],
       let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
        entry["x"] = Int(rect.origin.x)
        entry["y"] = Int(rect.origin.y)
        entry["width"] = Int(rect.width)
        entry["height"] = Int(rect.height)
        // A window listed at no size is listed and not drawn. Reported rather than filtered, so a
        // caller asserting "on screen" can say which of the two it got.
        entry["hasArea"] = rect.width > 0 && rect.height > 0
    } else {
        entry["hasArea"] = false
    }
    entry["layer"] = window[kCGWindowLayer as String] as? Int ?? 0
    windows.append(entry)
}

let report: [String: Any] = [
    "running": true,
    "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
    "windows": windows,
]
print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
