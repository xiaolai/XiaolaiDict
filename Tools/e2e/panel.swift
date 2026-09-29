// panel <bundle-id>: what the reader sees, as one JSON object — the frontmost app, and for each
// window of <bundle-id> both the text in it and the names of the controls that can be pressed.
//
// **The two are different questions and a text dump answers only one.** The setup board draws
// "Not now" as a button while the reader has not answered, and as the row's *status word* once
// they have — the same string either way. A stage asserting on `texts` alone therefore could not
// tell a button that had gone from one that had not, and reported a wiring defect that did not
// exist. `controls` is role-aware: only an actionable, enabled element with a frame is in it.
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
/// Roles a reader can press. The same set `click-element` will act on, so what this lists and
/// what that will click cannot drift apart.
let actionable: Set<String> = [
    kAXButtonRole, kAXRadioButtonRole, kAXCheckBoxRole, kAXPopUpButtonRole, kAXMenuButtonRole,
    kAXDisclosureTriangleRole, "AXLink", "AXTab",
]
/// Every name an enabled control in this window answers to.
func controls(of window: AXUIElement) -> [String] {
    var queue: [AXUIElement] = [window], head = 0
    var found = Set<String>()
    while head < queue.count, head < 4_000 {
        let node = queue[head]; head += 1
        queue += attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
        guard let role = attribute(node, kAXRoleAttribute) as? String, actionable.contains(role)
        else { continue }
        // Unreadable is not enabled: a control whose state could not be established must not be
        // listed as one the reader can press.
        guard attribute(node, kAXEnabledAttribute) as? Bool ?? false else { continue }
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            if let text = attribute(node, name) as? String, !text.isEmpty { found.insert(text) }
        }
    }
    return found.sorted()
}
var windows: [[String: Any]] = []
if let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1]).first {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    for window in attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        windows.append(["texts": contents(of: window), "controls": controls(of: window)])
    }
}
let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
let report: [String: Any] = ["frontmost": front, "windows": windows]
print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
