import Carbon.HIToolbox
import Foundation

/// A key combination: a virtual key code and Carbon modifier flags.
struct Shortcut: Equatable, Codable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// ⌃⌥D — "Dictionary". Not a macOS default. VoiceOver users know ⌃⌥ as the VoiceOver keys,
    /// which is one reason the reader can change it.
    static let defaultLookUp = Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))

    /// ⌘, ⌃ or ⌥ is required: a shortcut of a bare key, or of ⇧ and a key, would fire while typing.
    var isUsable: Bool { modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 }

    /// As macOS writes it: modifiers in the system's order, ⌃⌥⇧⌘, then the key as `keyName` labels
    /// it — by default the current keyboard layout, so the label is right on AZERTY and Dvorak too.
    func label(keyName: (UInt32) -> String? = Shortcut.currentLayoutName) -> String {
        let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        let prefix = symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
        return prefix + (Self.specialKeys[Int(keyCode)] ?? keyName(keyCode)?.uppercased() ?? "key \(keyCode)")
    }

    /// Keys whose label is not a character the layout types.
    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// The character the current keyboard layout types for `keyCode` with no modifiers.
    static func currentLayoutName(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

/// The reader's chosen shortcut, kept in user defaults.
struct ShortcutStore {
    static let key = "lookUpShortcut"
    let defaults: UserDefaults

    /// The saved shortcut, or the default when none is saved — or what is saved is unusable.
    func load() -> Shortcut {
        guard let data = defaults.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode(Shortcut.self, from: data), saved.isUsable
        else { return .defaultLookUp }
        return saved
    }

    func save(_ shortcut: Shortcut) throws {
        defaults.set(try JSONEncoder().encode(shortcut), forKey: Self.key)
    }
}
