import CoreGraphics
import Foundation

// screen-state — prints "locked" or "unlocked" for the console session's screen, and exits 1 when
// it is locked — or "unknown" and exits 2 when there is no session to ask.
//
// Why this exists: a locked screen does not stop windows from being drawn — CGWindowList still
// lists XiaolaiDict's, and every "is it on screen" check still passes — but it covers them. Measured on
// 2026-09-21: a capture of the drawer came back as the lock screen's aerial image, and keystrokes
// meant for the shortcut recorder went to the lock screen's password field, with `loginwindow`
// reported in front both times. Every stage that looks at the screen or types into it is void
// while this says "locked", and the harness asks before it runs any of them.
//
// **Fails closed.** `CGSessionCopyCurrentDictionary` answers nil outside a Quartz GUI session or
// when WindowServer is unavailable, and that nil used to become an empty dictionary — which has no
// lock key, and so read as "unlocked": the gate waved through exactly the machine it cannot see.
guard let raw = CGSessionCopyCurrentDictionary(), let session = raw as? [String: Any] else {
    print("unknown — there is no console session to ask (not in a GUI session, or WindowServer is unavailable)")
    exit(2)
}
// `NSNumber.boolValue`, so a CFBoolean and a CFNumber 1 both read as locked. Observed locked, the key
// printed as `1`. Absent from a session that *was* retrieved, it is an unlocked screen.
let locked = (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
print(locked ? "locked" : "unlocked")
exit(locked ? 1 : 0)
