// session-access [bundle-id...]: what macOS lets **this session** do, as one JSON object — asked of APIs that
// never prompt.
//
//   {"accessibility": true, "screenRecording": false, "automation": {"com.apple.systemevents": "granted"}}
//
// **Why it exists** (2026-10-08). The stages run from an SSH session, and TCC judges a command started there as
// that session — the process responsible for it, `sshd-keygen-wrapper` — and not as XiaolaiDict. So every helper
// here, `screencapture`, and `XiaolaiDict --read-point` run directly each need grants of their own, in lists the
// app's setup board cannot see: the board was all green while the learning stage's `screencapture` was refused and
// hover's direct read could not fall back to the pixels. The harness's preflight asks this first, and names the
// grant and the list, rather than letting four stages fail with four other sentences.
//
// - `accessibility`: `AXIsProcessTrusted()`, which takes no options and so never prompts.
// - `screenRecording`: `CGPreflightScreenCaptureAccess()`, the one Screen Recording question that never prompts.
//   The app must not decide its own grant this way — it can disagree with ScreenCaptureKit, the API its capture
//   uses (ADR-0017) — and the preflight does not either: once this says yes, it runs `screencapture` itself and
//   requires a picture. A probe through ScreenCaptureKit could raise the first-run dialog on that Mac.
// - `automation`: for each bundle identifier given, `AEDeterminePermissionToAutomateTarget` with
//   `askUserIfNeeded: false` — `granted`, `denied`, `notAsked` (sending an event would raise the prompt),
//   `notRunning` (the answer needs the target running), or `error <status>`.
//
// Exits 0 whenever it could ask: a missing grant is an answer the caller decides on, not an error.
import AppKit
import ApplicationServices
import CoreGraphics

/// The answer for one target, in the words the harness matches on.
func automation(of bundleID: String) -> String {
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
    guard let address = target.aeDesc else { return "error no address" }
    let status = AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, false)
    switch Int(status) {
    case Int(noErr): return "granted"
    case errAEEventNotPermitted: return "denied"
    case errAEEventWouldRequireUserConsent: return "notAsked"
    case procNotFound: return "notRunning"
    default: return "error \(status)"
    }
}

var asked: [String: String] = [:]
for bundleID in CommandLine.arguments.dropFirst() { asked[bundleID] = automation(of: bundleID) }
let report: [String: Any] = [
    "accessibility": AXIsProcessTrusted(),
    "screenRecording": CGPreflightScreenCaptureAccess(),
    "automation": asked,
]
guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else {
    FileHandle.standardError.write(Data("session-access: the report could not be written\n".utf8)); exit(1)
}
print(String(decoding: data, as: UTF8.self))
