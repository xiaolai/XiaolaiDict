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
/// An attribute, and **why** it is missing when it is. An error is not an absence: a messaging
/// timeout, a stale element and a permission failure all read as "this window has no text",
/// which is how an unreadable window comes to look like a closed one.
func read(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, error: AXError) {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (value, status)
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    let (value, status) = read(element, name)
    return status == .success ? value : nil
}
/// True only where the attribute is genuinely not offered.
func isAbsent(_ error: AXError) -> Bool { error == .noValue || error == .attributeUnsupported }

/// Roles a reader can press. **Identical to `click-element`'s set**, because what this lists and
/// what that will click must be the same question — a stage reads one and acts through the other.
let actionable: Set<String> = [
    kAXButtonRole, kAXRadioButtonRole, kAXCheckBoxRole, kAXPopUpButtonRole, kAXMenuButtonRole,
    kAXDisclosureTriangleRole, "AXLink", "AXTab",
]

/// A frame, or nil where the element has none — `click-element` refuses a control without one,
/// so listing it here would offer a stage something it cannot act on.
func frame(_ element: AXUIElement) -> CGRect? {
    var origin = CGPoint.zero, size = CGSize.zero
    guard let position = attribute(element, kAXPositionAttribute),
          let extent = attribute(element, kAXSizeAttribute) else { return nil }
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    AXValueGetValue(extent as! AXValue, .cgSize, &size)
    guard size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: origin, size: size)
}

/// Every name a control answers to. **Includes `kAXValueAttribute`**, which `click-element`
/// matches on: a control named only through its value could be clicked and was absent from this
/// report, so the two helpers disagreed about what was on screen.
func names(_ element: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
        .compactMap { attribute(element, $0) as? String }
        .filter { !$0.isEmpty }
}

/// `click-element`'s own rule, spelled the same way: an actionable role, a readable frame, and
/// enabled — where *unreadable* enabled counts as enabled only when the attribute is genuinely
/// not offered. Treating a missing attribute as disabled made this helper hide controls the
/// other one would happily click.
func isEnabledControl(_ element: AXUIElement) -> Bool {
    guard let role = attribute(element, kAXRoleAttribute) as? String, actionable.contains(role)
    else { return false }
    let enabled = read(element, kAXEnabledAttribute)
    if let flag = enabled.value as? Bool { return flag }
    return isAbsent(enabled.error)
}

/// One window, walked **once**, returning both what it says and what can be pressed.
///
/// Two walks read every child hierarchy twice and kept the traversal rule in two places. The
/// walk is bounded by a node count *and* a deadline — thousands of synchronous Accessibility
/// reads can outrun any patience the calling stage has — and it says when either bound stopped
/// it, because a truncated report that looks complete is how absent content gets asserted.
func inspect(_ window: AXUIElement, until deadline: Date) -> (texts: [String], controls: [String], complete: Bool) {
    var queue: [AXUIElement] = [window], head = 0
    var texts: [String] = []
    var controls = Set<String>()
    var complete = true
    while head < queue.count {
        if head >= 4_000 || Date() >= deadline { complete = false; break }
        let node = queue[head]; head += 1
        for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            guard let text = attribute(node, name) as? String, !text.isEmpty else { continue }
            texts.append(text)
        }
        if isEnabledControl(node), frame(node) != nil { controls.formUnion(names(node)) }
        queue += attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    return (texts, controls.sorted(), complete)
}

var windows: [[String: Any]] = []
var complete = true
if let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1]).first {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    // A synchronous Accessibility call to a busy app otherwise waits as long as the system
    // default, which is longer than any stage's patience.
    AXUIElementSetMessagingTimeout(element, 2)
    let deadline = Date().addingTimeInterval(10)
    for window in attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        let seen = inspect(window, until: deadline)
        if !seen.complete { complete = false }
        windows.append(["texts": seen.texts, "controls": seen.controls])
    }
}
let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
// **Said, so a truncated report cannot be read as a complete one.** A walk stopped by its node
// cap or its deadline returns what it found, and a caller asserting something is absent needs to
// know whether the walk actually finished looking.
let report: [String: Any] = ["frontmost": front, "windows": windows, "complete": complete]
print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
