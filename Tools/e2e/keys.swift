// keys <key-code> [control] [option] [shift] [command] [--hold SECONDS]: press and release one key with
// those modifiers, posted as the keyboard would — hot keys see it. Key codes are virtual key codes
// (kVK_ANSI_D is 2, kVK_Escape is 53).
//
// **`--hold SECONDS` is a held key**: down, then the autorepeat a keyboard sends while it stays down —
// after the initial delay, at the repeat interval, each keyDown flagged as a repeat — then up. The
// window server does not invent repeats for posted events, so a held key has to be posted as the
// stream it is. It prints one JSON line: how many repeats were posted, how many a listen-only event
// tap in this process saw arrive *flagged as repeats* (or null where no tap could be made), and
// `downAt`, the wall-clock instant the key went down.
//
// **The second number is the positive control.** A hold whose repeats never arrived as repeats would
// make any "a held key does it once" check pass by never testing it, and from outside that pass looks
// exactly like the app being right.
//
// **`--plan` with `--hold` posts nothing**: it prints when each event of that hold would be posted, in
// seconds after the key goes down — the schedule the posting path follows — and exits. It is how
// `Tools/tests/test_keys.py` checks the timing on a Mac that must not be sent keys.
import CoreGraphics
import Foundation

func refuse(_ message: String, status: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8)); exit(status)
}
let usage = "usage: keys <key-code> [control] [option] [shift] [command] [--hold SECONDS [--plan]]"

var arguments = Array(CommandLine.arguments.dropFirst())
let planOnly = arguments.contains("--plan")
arguments.removeAll { $0 == "--plan" }
var hold: Double?
if let at = arguments.firstIndex(of: "--hold") {
    guard at + 1 < arguments.count, let seconds = Double(arguments[at + 1]), seconds > 0, seconds <= 10
    else { refuse("keys: --hold needs a number of seconds, more than 0 and at most 10\n\(usage)") }
    hold = seconds
    arguments.removeSubrange(at...at + 1)
}
guard let first = arguments.first, let code = CGKeyCode(first) else { refuse(usage) }
let names: [String: CGEventFlags] = ["control": .maskControl, "option": .maskAlternate, "shift": .maskShift, "command": .maskCommand]
var flags = CGEventFlags()
for name in arguments.dropFirst() {
    guard let flag = names[name] else { refuse("keys: unknown modifier \(name)") }
    flags.insert(flag)
}

/// Marks this process's own events, so the tap below counts them and nothing a person typed.
let marker = Int64(getpid()) << 20 | 0x6b6579

func key(down: Bool, repeating: Bool = false) -> CGEvent {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
        refuse("keys: could not make the event", status: 1)
    }
    event.flags = flags
    event.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
    event.setIntegerValueField(.eventSourceUserData, value: marker)
    return event
}

guard let hold else {
    if planOnly { refuse("keys: --plan needs --hold: a press has no schedule to print\n\(usage)") }
    for down in [true, false] {
        key(down: down).post(tap: .cghidEventTap)
        usleep(30_000)
    }
    exit(0)
}

/// A fast keyboard's repeat: a short initial delay, then about thirty a second. The fastest a reader
/// can set in System Settings is the case where a repeat lands soonest after the grade it follows.
let initialDelay = 0.3
let interval = 0.033

/// **When each event of a hold is posted**, in seconds after the key goes down: a repeat from the
/// initial delay on, at the interval, while one more interval still fits; the release at the hold's own
/// end. A hold shorter than the initial delay is a down and an up with nothing between, as a keyboard
/// sends it — released when it was asked to be, not at the initial delay (it once slept the whole
/// delay first, so a 0.1 s hold was held 0.3 s and reported as 0.1).
func schedule(hold: Double) -> (repeats: [Double], up: Double) {
    var repeats: [Double] = []
    while initialDelay + Double(repeats.count) * interval + interval < hold {
        repeats.append(initialDelay + Double(repeats.count) * interval)
    }
    return (repeats, hold)
}

let planned = schedule(hold: hold)
if planOnly {
    let repeatsAt = planned.repeats.map { String($0) }.joined(separator: ",")
    print("{\"repeatsAt\":[\(repeatsAt)],\"upAt\":\(planned.up)}")
    exit(0)
}

/// Seen by the tap: this process's keyDowns that arrived flagged as repeats. Touched only on the main
/// run loop, where the tap's callback runs and where the result is read once it has stopped.
nonisolated(unsafe) var seenRepeats = 0
let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
    eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
    callback: { _, type, event, _ in
        if type == .keyDown, event.getIntegerValueField(.eventSourceUserData) == marker,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 1 {
            seenRepeats += 1
        }
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil)
if let tap {
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
}

nonisolated(unsafe) var posted = 0
/// How long the key was down, measured from its down to its up — what is reported, not what was asked.
nonisolated(unsafe) var heldFor = 0.0
/// **When the key went down, on the wall clock** — seconds since 1970, as the ledger stamps a grade. The
/// review stage counts a grade's lateness from this and the event's own instant, so nothing about when
/// its own process got round to watching can move the figure (audit-fix round 1, #31).
nonisolated(unsafe) var downAt = 0.0
DispatchQueue.global().async {
    let started = Date()
    downAt = started.timeIntervalSince1970
    func wait(until offset: Double) {
        let left = offset - Date().timeIntervalSince(started)
        if left > 0 { usleep(useconds_t(left * 1_000_000)) }
    }
    key(down: true).post(tap: .cghidEventTap)
    for offset in planned.repeats {
        wait(until: offset)
        key(down: true, repeating: true).post(tap: .cghidEventTap)
        posted += 1
    }
    wait(until: planned.up)
    key(down: false).post(tap: .cghidEventTap)
    heldFor = Date().timeIntervalSince(started)
    // Long enough for the last of them to pass the tap before the run loop is stopped.
    usleep(300_000)
    CFRunLoopStop(CFRunLoopGetMain())
}
CFRunLoopRun()
let seen = tap == nil ? "null" : String(seenRepeats)
print("{\"down\":1,\"downAt\":\(downAt),\"heldSeconds\":\(heldFor),\"repeats\":\(posted),\"seenRepeats\":\(seen),\"up\":1}")
