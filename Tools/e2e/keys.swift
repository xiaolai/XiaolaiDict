// keys <key-code> [control] [option] [shift] [command]: press and release one key with those
// modifiers, posted as the keyboard would — hot keys see it. Key codes are virtual key codes
// (kVK_ANSI_D is 2, kVK_Escape is 53).
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard let first = arguments.first, let code = CGKeyCode(first) else {
    FileHandle.standardError.write(Data("usage: keys <key-code> [control] [option] [shift] [command]\n".utf8)); exit(64)
}
let names: [String: CGEventFlags] = ["control": .maskControl, "option": .maskAlternate, "shift": .maskShift, "command": .maskCommand]
var flags = CGEventFlags()
for name in arguments.dropFirst() {
    guard let flag = names[name] else { FileHandle.standardError.write(Data("keys: unknown modifier \(name)\n".utf8)); exit(64) }
    flags.insert(flag)
}
for down in [true, false] {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
        FileHandle.standardError.write(Data("keys: could not make the event\n".utf8)); exit(1)
    }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(30_000)
}
