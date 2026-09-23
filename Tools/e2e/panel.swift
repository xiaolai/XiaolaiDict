// panel <bundle-id>: what the reader sees, as one JSON object — the frontmost app, and the text in
// each window of the app <bundle-id>.
import AppKit
import ApplicationServices

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: panel <bundle-id>\n".utf8)); exit(64)
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
/// Every string a window shows.
func contents(of window: AXUIElement) -> [String] {
    var queue: [AXUIElement] = [window], head = 0
    var texts: [String] = []
    while head < queue.count, head < 4_000 {
        let node = queue[head]; head += 1
        for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            guard let text = attribute(node, name) as? String, !text.isEmpty else { continue }
            texts.append(text)
        }
        queue += attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    return texts
}
var windows: [[String: Any]] = []
if let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1]).first {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    for window in attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        windows.append(["texts": contents(of: window)])
    }
}
let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
let report: [String: Any] = ["frontmost": front, "windows": windows]
print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
