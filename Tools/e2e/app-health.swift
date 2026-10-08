// app-health <bundle-id> <sentence>: can a stage use the window of that app whose text holds <sentence>? One JSON
// object, and exit 0 only for `ok`:
//
//   {"state": "ok" | "notRunning" | "noAccessibility" | "hung" | "blocked" | "noFixture", "detail": "…", "pid": 123}
//
// **Why it exists** (2026-10-08). A TextEdit left on the E2E Mac answering nothing — hung, or with a sheet over the
// fixture — made `select-text` report "no focused element" in four stages, each failure reading as a defect of its
// own stage. Asked once, before any stage, the cause has one name and the harness one remedy.
//
// - `hung`: an Accessibility request to the app did not complete within two seconds (`kAXErrorCannotComplete`).
//   A responsive app answers in milliseconds; the system default of six seconds would be paid again by every
//   request a stage makes.
// - `blocked`: a window holds a sheet, or the app shows a dialog — a stage's keys and clicks would go to it. The
//   detail carries what it says.
// - `noFixture`: no text area of the app holds <sentence>, so `select-text` would select in something else.
// - `noAccessibility`: this session may not ask (`kAXErrorAPIDisabled`) — a fact about the session, not the app.
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: app-health <bundle-id> <sentence>\n".utf8)); exit(64)
}
let bundleID = arguments[1], sentence = arguments[2]

func emit(_ state: String, _ detail: String, pid: pid_t? = nil) -> Never {
    var report: [String: Any] = ["state": state, "detail": detail]
    if let pid { report["pid"] = Int(pid) }
    let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data()
    print(String(decoding: data, as: UTF8.self))
    exit(state == "ok" ? 0 : 1)
}

/// An attribute and the error that came with it: a timeout is not an absence.
func read(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, error: AXError) {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (value, status)
}
func string(_ element: AXUIElement, _ name: String) -> String? { read(element, name).value as? String }
func children(_ element: AXUIElement) -> [AXUIElement] { read(element, kAXChildrenAttribute).value as? [AXUIElement] ?? [] }

/// Every static text and button title under `element`, breadth first and bounded — what a sheet or dialog says.
func words(under element: AXUIElement, limit: Int = 200) -> String {
    var queue = [element], head = 0, found: [String] = []
    while head < queue.count, head < limit {
        let node = queue[head]; head += 1
        for name in [kAXValueAttribute, kAXTitleAttribute] {
            if let text = string(node, name), !text.isEmpty, text.count < 200 { found.append(text) }
        }
        queue += children(node)
    }
    return found.prefix(8).joined(separator: " · ")
}

// The real process, never the -1 macOS 27 reports for some apps — `shared/running-app.swift`.
guard let app = runningApp(bundleID) else { emit("notRunning", "\(bundleID) is not running") }
let pid = app.pid
// For this process only: every request below is bounded by it.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)
let root = AXUIElementCreateApplication(pid)

let (listed, status) = read(root, kAXWindowsAttribute)
switch status {
case .success: break
case .cannotComplete:
    emit("hung", "\(bundleID) (pid \(pid)) did not answer an Accessibility request within 2 s", pid: pid)
case .apiDisabled:
    emit("noAccessibility", "this session may not use Accessibility, so \(bundleID) cannot be asked", pid: pid)
default:
    emit("noFixture", "\(bundleID) (pid \(pid)) lists no windows (AXError \(status.rawValue))", pid: pid)
}
let windows = listed as? [AXUIElement] ?? []

for window in windows {
    let title = string(window, kAXTitleAttribute) ?? "untitled"
    let subrole = string(window, kAXSubroleAttribute) ?? ""
    if subrole == kAXDialogSubrole || subrole == kAXSystemDialogSubrole {
        emit("blocked", "\(bundleID) shows a dialog, “\(title)”: \(words(under: window))", pid: pid)
    }
    for child in children(window) where string(child, kAXRoleAttribute) == kAXSheetRole {
        emit("blocked", "\(bundleID)'s window “\(title)” holds a sheet: \(words(under: child))", pid: pid)
    }
}

/// Whether a text area under `window` holds the sentence, breadth first and bounded.
func holdsFixture(_ window: AXUIElement) -> Bool {
    var queue = [window], head = 0
    while head < queue.count, head < 600 {
        let node = queue[head]; head += 1
        if string(node, kAXRoleAttribute) == kAXTextAreaRole, string(node, kAXValueAttribute)?.contains(sentence) == true {
            return true
        }
        queue += children(node)
    }
    return false
}
guard let holding = windows.first(where: holdsFixture).map({ string($0, kAXTitleAttribute) ?? "untitled" }) else {
    emit("noFixture", "no window of \(bundleID) holds “\(sentence)” (\(windows.count) window(s): "
         + windows.compactMap { string($0, kAXTitleAttribute) }.joined(separator: ", ") + ")", pid: pid)
}
emit("ok", "“\(holding)” holds the fixture, and nothing covers it", pid: pid)
