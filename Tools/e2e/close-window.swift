import AppKit
import ApplicationServices

// close-window <title> [<bundle-id>] — presses the close button of XiaolaiDict's window with that title — or, given a
// bundle id, that app's — and exits 0 only if the press was accepted.
//
// **The bundle id is for the harness's own documents in another app** (2026-10-09): the preflight closes TextEdit's
// `notes.txt` window when it holds an older copy of the fixture, which `open` would bring forward and never read again.
//
// Every failure is its own message and a nonzero exit. The first version ignored the press's
// result and printed success regardless, read every Accessibility error as "absent", and with no
// argument looked for an untitled window — so a window it failed to close, or one it could not see
// for want of permission, read exactly like one it had closed.
guard (2...3).contains(CommandLine.arguments.count) else {
    FileHandle.standardError.write(Data("usage: close-window <title> [<bundle-id>]\n".utf8)); exit(2)
}
let title = CommandLine.arguments[1]
let bundleID = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : "com.xiaolaidict"
guard AXIsProcessTrusted() else {
    print("this process is not trusted for Accessibility, so it cannot see or press anything"); exit(1)
}
// The real process, never the -1 macOS 27 reports for some apps — `shared/running-app.swift`.
guard let app = runningApp(bundleID) else {
    print("\(bundleID) is not running"); exit(1)
}
let ax = AXUIElementCreateApplication(app.pid)

/// The attribute, or why not — `nil` with `.noValue` or `.attributeUnsupported` is an element that
/// simply does not have it; anything else is a failure to report.
func read(_ element: AXUIElement, _ name: String) -> (AnyObject?, AXError) {
    var found: AnyObject?
    let status = AXUIElementCopyAttributeValue(element, name as CFString, &found)
    return (found, status)
}

let (list, listed) = read(ax, kAXWindowsAttribute)
guard listed == .success, let windows = list as? [AXUIElement] else {
    print("could not list \(bundleID)'s windows (AXError \(listed.rawValue))"); exit(1)
}
// A title that could not be read is reported as the failure it is, never as a title — a window
// whose name is "?" would otherwise be matched by asking for "?".
let titles: [String] = windows.map { window in
    let (value, status) = read(window, kAXTitleAttribute)
    if let name = value as? String { return name }
    return status == .noValue || status == .attributeUnsupported
        ? "<untitled>" : "<unreadable: AXError \(status.rawValue)>"
}
guard let window = zip(windows, titles).first(where: { $0.1 == title })?.0 else {
    print("no window titled '\(title)'; saw: \(titles)"); exit(1)
}
let (button, found) = read(window, kAXCloseButtonAttribute)
guard found == .success, let button else {
    print("'\(title)' has no close button Accessibility can reach (AXError \(found.rawValue))"); exit(1)
}
let pressed = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
guard pressed == .success else {
    print("pressing the close button of '\(title)' failed (AXError \(pressed.rawValue))"); exit(1)
}
print("pressed the close button of '\(title)'")
