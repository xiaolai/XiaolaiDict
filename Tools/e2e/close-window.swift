import AppKit
import ApplicationServices

// close-window <title> [<bundle-id>] — presses the close button of XiaolaiDict's window with that title — or, given a
// bundle id, that app's — and exits 0 only if the press was accepted.
//
// close-window --document <path> <bundle-id> — presses the close button of the one window of that app whose document is
// the file at <path>. **By the file, never the title, for the harness's own document in another app** (audit round 3,
// 2026-10-09): the preflight puts away TextEdit's window when it holds an older copy of the fixture, which `open` would
// bring forward and never read again, and by title it took the first window called notes.txt — which could be someone
// else's document of that name, closed or answered with a Save sheet on a Mac that may be theirs. A file that no window
// holds, that two windows hold, or that a window whose document cannot be read might hold, is refused.
//
// close-window --decide <path> <document>... — which window `--document` would choose among windows holding these
// documents (a file URL, `none`, or `unreadable`), printed and nothing pressed, with no Accessibility asked: the choice,
// as a test can ask it.
//
// Every failure is its own message and a nonzero exit. The first version ignored the press's
// result and printed success regardless, read every Accessibility error as "absent", and with no
// argument looked for an untitled window — so a window it failed to close, or one it could not see
// for want of permission, read exactly like one it had closed.

/// What a window says it holds.
enum WindowDocument {
    case url(String)
    case none
    case unreadable(Int32)
}

/// Which window holds the file: the one that does, or why none can be named.
enum DocumentChoice {
    case window(Int)
    case noWindow
    case ambiguous([Int])
    case unverifiable([Int])
}

/// One spelling of a file, whatever path reached it: `/tmp/x` and `/private/tmp/x` are one file.
func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

func choose(_ file: URL, among documents: [WindowDocument]) -> DocumentChoice {
    // A window whose document cannot be read could be the one holding the file — or the one the others are not.
    let unreadable = documents.indices.filter { if case .unreadable = documents[$0] { true } else { false } }
    guard unreadable.isEmpty else { return .unverifiable(unreadable) }
    let target = canonical(file)
    let holding = documents.indices.filter { index in
        guard case .url(let text) = documents[index], let url = URL(string: text), url.isFileURL else { return false }
        return canonical(url) == target
    }
    switch holding.count {
    case 0: return .noWindow
    case 1: return .window(holding[0])
    default: return .ambiguous(holding)
    }
}

func describe(_ choice: DocumentChoice) -> String {
    switch choice {
    case .window(let index): "window \(index)"
    case .noWindow: "no window"
    case .ambiguous(let all): "ambiguous " + all.map(String.init).joined(separator: ",")
    case .unverifiable(let all): "unverifiable " + all.map(String.init).joined(separator: ",")
    }
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: close-window <title> [<bundle-id>]
               close-window --document <path> <bundle-id>
               close-window --decide <path> <document>...

        """.utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--decide" {
    guard arguments.count >= 2 else { usage() }
    let documents: [WindowDocument] = arguments.dropFirst(2).map {
        switch $0 {
        case "none": .none
        case "unreadable": .unreadable(-1)
        default: .url($0)
        }
    }
    print(describe(choose(URL(fileURLWithPath: arguments[1]), among: documents)))
    exit(0)
}

/// Which window to close: by its title, or by the file it holds.
enum Target {
    case title(String)
    case document(URL)
}
let target: Target
let bundleID: String
if arguments.first == "--document" {
    guard arguments.count == 3 else { usage() }
    target = .document(URL(fileURLWithPath: arguments[1]))
    bundleID = arguments[2]
} else {
    guard (1...2).contains(arguments.count) else { usage() }
    target = .title(arguments[0])
    bundleID = arguments.count == 2 ? arguments[1] : "com.xiaolaidict"
}

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

let window: AXUIElement
let name: String
switch target {
case .title(let title):
    guard let found = zip(windows, titles).first(where: { $0.1 == title })?.0 else {
        print("no window titled '\(title)'; saw: \(titles)"); exit(1)
    }
    window = found
    name = title
case .document(let file):
    let documents: [WindowDocument] = windows.map { window in
        let (value, status) = read(window, kAXDocumentAttribute)
        if status == .success { return (value as? String).map(WindowDocument.url) ?? .none }
        return status == .noValue || status == .attributeUnsupported ? .none : .unreadable(status.rawValue)
    }
    let choice = choose(file, among: documents)
    guard case .window(let index) = choice else {
        print("no one window of \(bundleID) can be shown to hold \(file.path) — \(describe(choice)); saw: \(titles)")
        exit(1)
    }
    window = windows[index]
    name = titles[index]
}
let (button, found) = read(window, kAXCloseButtonAttribute)
guard found == .success, let button else {
    print("'\(name)' has no close button Accessibility can reach (AXError \(found.rawValue))"); exit(1)
}
let pressed = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
guard pressed == .success else {
    print("pressing the close button of '\(name)' failed (AXError \(pressed.rawValue))"); exit(1)
}
print("pressed the close button of '\(name)'")
