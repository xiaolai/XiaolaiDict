// Compiled beside every helper in `Tools/e2e` (`e2e.sh`'s install step builds each one as `main.swift` with this
// file), so the one way a helper finds an app's process is written once. Declarations only: a file compiled beside
// a `main.swift` may hold no top-level code.
import AppKit
import CoreGraphics
import Darwin

/// A running app found by bundle identifier, with the process ID Accessibility needs.
struct RunningApp {
    let app: NSRunningApplication
    let pid: pid_t
}

/// **The app with this bundle identifier, and its real process ID — never the `-1` macOS 27 reports for some.**
///
/// `NSRunningApplication.processIdentifier` answered `-1` for TextEdit on the development Mac on 2026-10-08 while
/// its process (29272) ran and LaunchServices itself listed that pid; Safari launched from its cryptex did the same
/// earlier, which is why the app resolves every reader's process (`ProcessResolver`). `AXUIElementCreateApplication(-1)`
/// answers every request with an error, so a helper that trusted the reported value said "no focused element" about
/// an app that was fine — the shape of the TextEdit failures that took four stages on the E2E Mac.
///
/// Resolved first the way `find_pids` in `e2e.sh` finds the bundle under test — the processes whose executable is
/// the app's, by path, never by name, the one owning an on-screen window first — and then the way the app's own
/// `ProcessResolver` does: the owner of an on-screen window whose process answers to this bundle identifier, which
/// covers an executable whose path the process table spells another way (a cryptex). Nil when the app is not
/// running, or when neither finds its process.
func runningApp(_ bundleID: String) -> RunningApp? {
    let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    guard let app = candidates.first else { return nil }
    if app.processIdentifier > 0 { return RunningApp(app: app, pid: app.processIdentifier) }
    let owners = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
        .compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }
    let matching = app.executableURL.map { processes(runningExactly: $0.resolvingSymlinksInPath().path) } ?? []
    let byWindow = owners.first { $0 > 0 && NSRunningApplication(processIdentifier: $0)?.bundleIdentifier == bundleID }
    guard let pid = matching.first(where: owners.contains) ?? matching.first ?? byWindow else { return nil }
    return RunningApp(app: app, pid: pid)
}

/// Every process of this user whose executable is exactly `path`, lowest pid first.
func processes(runningExactly path: String) -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) * 2)
    let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard filled > 0 else { return [] }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    return pids.prefix(Int(filled)).filter { pid in
        guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path == path
    }.sorted()
}

/// Whether the app in front is this one — asked by bundle identifier, because the front app's reported pid can be
/// the same `-1` and a comparison of pids would then say no about the right app, or yes about two wrong ones.
func isFrontmost(_ bundleID: String) -> Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
}
