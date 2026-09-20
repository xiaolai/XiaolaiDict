import AppKit
import ApplicationServices

// window-frame <bundle-id> — prints the frontmost ordinary window's frame in Accessibility screen
// coordinates (origin top-left), as "x y width height".
//
// Exists for the recogniser's stage: an app with no Accessibility text has no word position to ask
// for, so the only way to aim at it is its window.
let bundleID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
guard !bundleID.isEmpty else { FileHandle.standardError.write(Data("usage: window-frame <bundle-id>\n".utf8)); exit(2) }
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    FileHandle.standardError.write(Data("\(bundleID) is not running\n".utf8)); exit(1)
}
let ax = AXUIElementCreateApplication(app.processIdentifier)
func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var found: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &found) == .success ? found : nil
}
guard let windows = value(ax, kAXWindowsAttribute as String) as? [AXUIElement] else {
    FileHandle.standardError.write(Data("\(bundleID) exposes no windows\n".utf8)); exit(1)
}
for window in windows {
    var origin = CGPoint.zero, size = CGSize.zero
    guard let positionValue = value(window, kAXPositionAttribute as String),
          let sizeValue = value(window, kAXSizeAttribute as String)
    else { continue }
    AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    // Skip panels and strips: the stage wants somewhere with room for text.
    guard size.width > 300, size.height > 200 else { continue }
    print("\(Int(origin.x)) \(Int(origin.y)) \(Int(size.width)) \(Int(size.height))")
    exit(0)
}
FileHandle.standardError.write(Data("\(bundleID) has no window big enough to read\n".utf8))
exit(1)
