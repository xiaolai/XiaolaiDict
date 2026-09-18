// panel <bundle-id>: what the reader sees, as one JSON object — the frontmost app, and the text in
// each window of the app <bundle-id>, with the texts of any web page in it listed separately.
import AppKit
import ApplicationServices

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: panel <bundle-id>\n".utf8)); exit(64)
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
/// Every string a window shows, and separately the texts inside its web page — a page laid out
/// as a document shows many; one parsed as bare XML shows a single run, stylesheet included.
func contents(of window: AXUIElement) -> (texts: [String], webTexts: [String]?) {
    var queue: [(node: AXUIElement, inWeb: Bool)] = [(window, false)], head = 0
    var texts: [String] = [], webTexts: [String]?
    while head < queue.count, head < 4_000 {
        let (node, inWeb) = queue[head]; head += 1
        let isWeb = inWeb || attribute(node, kAXRoleAttribute) as? String == "AXWebArea"
        if isWeb, webTexts == nil { webTexts = [] }
        for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            guard let text = attribute(node, name) as? String, !text.isEmpty else { continue }
            texts.append(text)
            if isWeb, attribute(node, kAXRoleAttribute) as? String == "AXStaticText" { webTexts?.append(text) }
        }
        queue += (attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { ($0, isWeb) }
    }
    return (texts, webTexts)
}
var windows: [[String: Any]] = []
if let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1]).first {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    for window in attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        let (texts, webTexts) = contents(of: window)
        var entry: [String: Any] = ["texts": texts]
        if let webTexts { entry["webTexts"] = webTexts }
        windows.append(entry)
    }
}
let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
let report: [String: Any] = ["frontmost": front, "windows": windows]
print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
