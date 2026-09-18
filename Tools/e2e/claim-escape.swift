// claim-escape: try to claim Escape exclusively as a hot key, then give it straight back. Prints
// "free" (and exits 0) if the claim succeeded, "held" (exit 1) if another process holds it.
import Carbon.HIToolbox
import Foundation

var reference: EventHotKeyRef?
let status = RegisterEventHotKey(
    UInt32(kVK_Escape), 0, EventHotKeyID(signature: 0x4532_4520, id: 1), GetApplicationEventTarget(),
    OptionBits(kEventHotKeyExclusive), &reference)
if status == noErr, let reference {
    UnregisterEventHotKey(reference)
    print("free")
    exit(0)
}
print(status == eventHotKeyExistsErr ? "held" : "error \(status)")
exit(1)
